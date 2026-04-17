const std = @import("std");
const log = std.log.scoped(.socket_manager);
const DomainSocket = @import("../config.zig").DomainSocket;
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const SocketManager = @This();

const run_user_dir = "/run/user";

// inotify event mask bits (from linux/inotify.h)
const IN_CREATE: u32 = 0x00000100;
const IN_DELETE: u32 = 0x00000200;
const IN_MOVED_FROM: u32 = 0x00000040;
const IN_MOVED_TO: u32 = 0x00000080;

// inotify_init1 flags (same as O_NONBLOCK | O_CLOEXEC on all common archs)
const IN_NONBLOCK: u32 = 0x800;
const IN_CLOEXEC: u32 = 0x80000;

/// A single managed listening socket for a specific uid.
const SocketEntry = struct {
    uid: std.posix.uid_t,
    server: std.Io.net.Server,
    path: [:0]const u8,
};

pub const Connection = struct {
    stream: std.Io.net.Stream,
};

allocator: Allocator,
io: std.Io,
/// Set of uids that are allowed by ACL (owned externally).
allowed_uids: std.ArrayList(u32),
/// Active listening sockets.
entries: std.ArrayList(SocketEntry),
/// poll file descriptors: [0..num_special_fds) = special fds, [num_special_fds..] = server sockets.
poll_fds: std.ArrayList(std.posix.pollfd),
/// inotify file descriptor for /run/user/.
inotify_fd: std.posix.fd_t,
/// Number of special (non-server-socket) fds at the start of poll_fds.
/// Index 0 = /run/user/ inotify. Index 1+ may be added by Server for ACL inotify etc.
/// Server socket entries start at poll_fds[num_special_fds].
num_special_fds: usize = 1,

pub fn init(io: std.Io, allocator: Allocator, allowed_uids: std.ArrayList(u32)) !SocketManager {
    const init_rc = linux.inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (std.posix.errno(init_rc) != .SUCCESS) {
        log.err("Failed to create inotify fd: {s}", .{@tagName(std.posix.errno(init_rc))});
        return error.InotifyInitFailed;
    }
    const ifd: std.posix.fd_t = @intCast(init_rc);
    errdefer _ = linux.close(ifd);

    // Watch /run/user for directory create/delete
    const wd_rc = linux.inotify_add_watch(ifd, run_user_dir, IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO);
    if (std.posix.errno(wd_rc) != .SUCCESS) {
        log.err("Failed to add inotify watch on {s}: {s}", .{ run_user_dir, @tagName(std.posix.errno(wd_rc)) });
        return error.InotifyWatchFailed;
    }

    var manager = SocketManager{
        .allocator = allocator,
        .io = io,
        .allowed_uids = allowed_uids,
        .entries = std.ArrayList(SocketEntry).empty,
        .poll_fds = std.ArrayList(std.posix.pollfd).empty,
        .inotify_fd = ifd,
    };

    // poll_fds[0] is always the inotify fd
    try manager.poll_fds.append(manager.allocator, .{
        .fd = ifd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    });

    return manager;
}

pub fn deinit(self: *SocketManager) void {
    // Close all server sockets
    for (self.entries.items) |*entry| {
        entry.server.deinit(self.io);
        std.Io.Dir.cwd().deleteFile(self.io, entry.path) catch {};
        self.allocator.free(entry.path);
    }
    self.entries.deinit(self.allocator);
    self.poll_fds.deinit(self.allocator);

    // Close inotify fd
    _ = linux.close(self.inotify_fd);
}

/// Initial scan: create sockets for existing /run/user/<uid>/ directories
/// that match allowed uids.
pub fn scanExisting(self: *SocketManager, io: std.Io) void {
    var dir = std.Io.Dir.cwd().openDir(io, run_user_dir, .{ .iterate = true }) catch |err| {
        log.warn("Failed to open {s}: {s}, skipping initial scan", .{ run_user_dir, @errorName(err) });
        return;
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const uid = std.fmt.parseUnsigned(std.posix.uid_t, entry.name, 10) catch continue;
        if (self.isUidAllowed(uid)) {
            self.addSocket(uid) catch |err| {
                log.warn("Failed to create socket for uid={d}: {s}", .{ uid, @errorName(err) });
            };
        }
    }
}

/// Check if a uid is in the allowed list.
pub fn isUidAllowed(self: SocketManager, uid: std.posix.uid_t) bool {
    for (self.allowed_uids.items) |allowed| {
        if (allowed == uid) return true;
    }
    return false;
}

/// Create a listening socket for the given uid.
pub fn addSocket(self: *SocketManager, uid: std.posix.uid_t) !void {
    // Skip if already listening for this uid
    for (self.entries.items) |entry| {
        if (entry.uid == uid) return;
    }

    const path = try DomainSocket.pathForUid(self.allocator, uid);
    errdefer self.allocator.free(path);

    const server = DomainSocket.listen(self.io, path, uid) catch |err| {
        log.warn("Failed to listen on {s}: {s}", .{ path, @errorName(err) });
        self.allocator.free(path);
        return err;
    };

    const entry = SocketEntry{
        .uid = uid,
        .server = server,
        .path = path,
    };

    try self.entries.append(self.allocator, entry);
    try self.poll_fds.append(self.allocator, .{
        .fd = server.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    });

    log.info("Listening on {s} for uid={d}", .{ path, uid });
}

/// Remove the listening socket for the given uid.
pub fn removeSocket(self: *SocketManager, uid: std.posix.uid_t) void {
    for (self.entries.items, 0..) |*entry, i| {
        if (entry.uid == uid) {
            entry.server.deinit(self.io);
            std.Io.Dir.cwd().deleteFile(self.io, entry.path) catch {};
            log.info("Stopped listening on {s} for uid={d}", .{ entry.path, uid });
            self.allocator.free(entry.path);
            _ = self.entries.orderedRemove(i);
            // +num_special_fds because poll_fds[0..num_special_fds] are inotify fds
            _ = self.poll_fds.orderedRemove(i + self.num_special_fds);
            return;
        }
    }
}

/// Update the allowed uid list (e.g. after config reload).
/// Adds sockets for new uids, removes sockets for removed uids.
pub fn updateAllowedUids(self: *SocketManager, new_uids: std.ArrayList(u32)) void {
    // Remove sockets for uids no longer in the list
    var i: usize = self.entries.items.len;
    while (i > 0) {
        i -= 1;
        const uid = self.entries.items[i].uid;
        var found = false;
        for (new_uids.items) |new_uid| {
            if (new_uid == uid) {
                found = true;
                break;
            }
        }
        if (!found) {
            self.removeSocket(uid);
        }
    }

    // Add sockets for new uids
    for (new_uids.items) |uid| {
        var exists = false;
        for (self.entries.items) |entry| {
            if (entry.uid == uid) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            // Check if /run/user/<uid>/ directory exists
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const dir_path = std.fmt.bufPrint(&buf, "{s}/{d}", .{ run_user_dir, uid }) catch continue;
            _ = std.Io.Dir.cwd().openDir(self.io, dir_path, .{}) catch continue;
            // Directory exists, create socket
            self.addSocket(uid) catch |err| {
                log.warn("Failed to create socket for uid={d} after config reload: {s}", .{ uid, @errorName(err) });
            };
        }
    }

    self.allowed_uids = new_uids;
}

/// Process pending inotify events.
/// Caller provides a buffer for reading events.
pub fn processInotifyEvents(self: *SocketManager, event_buf: []u8) void {
    while (true) {
        const n = std.posix.read(self.inotify_fd, event_buf) catch |err| switch (err) {
            error.WouldBlock => return,
            else => {
                log.warn("Failed to read inotify events: {s}", .{@errorName(err)});
                return;
            },
        };
        if (n == 0) return;

        var offset: usize = 0;
        while (offset < n) {
            const event_ptr: *align(4) std.os.linux.inotify_event = @ptrCast(@alignCast(event_buf[offset..].ptr));
            const event = event_ptr.*;
            offset += @sizeOf(std.os.linux.inotify_event) + event.len;

            if (event.len == 0) continue;

            // Get the filename
            const name_start = offset - event.len;
            const name = std.mem.sliceTo(event_buf[name_start..], 0);

            // Parse uid from directory name
            const uid = std.fmt.parseUnsigned(std.posix.uid_t, name, 10) catch continue;

            if (event.mask & (IN_CREATE | IN_MOVED_TO) != 0) {
                if (self.isUidAllowed(uid)) {
                    log.info("Detected new /run/user/{d} directory, creating socket", .{uid});
                    self.addSocket(uid) catch |err| {
                        log.warn("Failed to create socket for uid={d}: {s}", .{ uid, @errorName(err) });
                    };
                }
            } else if (event.mask & (IN_DELETE | IN_MOVED_FROM) != 0) {
                log.info("Detected removal of /run/user/{d} directory", .{uid});
                self.removeSocket(uid);
            }
        }
    }
}

/// Poll for events. Returns the index into poll_fds that has activity,
/// or null if timed out.
/// `timeout_ms` = -1 for infinite, 0 for non-blocking.
pub fn poll(self: *SocketManager, timeout_ms: i32) !?usize {
    const n = try std.posix.poll(self.poll_fds.items, timeout_ms);
    if (n == 0) return null;

    for (self.poll_fds.items, 0..) |*pfd, i| {
        if (pfd.revents & std.posix.POLL.IN != 0) {
            return i;
        }
    }

    return null;
}

/// Accept a connection on the server socket at the given poll_fds index.
/// poll_fds[num_special_fds] corresponds to entries[0].
pub fn accept(self: *SocketManager, io: std.Io, poll_index: usize) ?Connection {
    if (poll_index < self.num_special_fds) return null; // special fd, not a server socket
    const entry_index = poll_index - self.num_special_fds;
    if (entry_index >= self.entries.items.len) return null;
    const stream = self.entries.items[entry_index].server.accept(io) catch |err| {
        log.warn("Failed to accept connection: {s}", .{@errorName(err)});
        return null;
    };
    return Connection{ .stream = stream };
}
