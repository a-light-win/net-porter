//! Tracks active user sessions by monitoring /run/user/ via inotify.
//!
//! Watches for directory creation/deletion under /run/user/ and reports
//! UID appearances/disappearances to WorkerManager, which spawns/stops
//! per-UID worker processes.
//!
//! Only UIDs present in the ACL allowed list are tracked.

const std = @import("std");
const log = std.log.scoped(.uid_tracker);
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const inotify = @import("../utils/Inotify.zig");
const UidTracker = @This();

const run_user_dir = "/run/user";

/// Result of processing inotify events: UIDs that appeared/disappeared.
pub const UidEvents = struct {
    created: std.ArrayList(u32),
    removed: std.ArrayList(u32),

    pub fn deinit(self: *UidEvents, allocator: Allocator) void {
        self.created.deinit(allocator);
        self.removed.deinit(allocator);
    }
};

/// Tracked UID entry — a UID with an active /run/user/<uid>/ directory.
const UidEntry = struct {
    uid: std.posix.uid_t,
};

allocator: Allocator,
io: std.Io,
/// Set of uids that are allowed by ACL (owned externally).
allowed_uids: std.ArrayList(u32),
/// Active UID entries (directories that currently exist in /run/user/).
entries: std.ArrayList(UidEntry),
/// inotify file descriptor for /run/user/.
inotify_fd: std.posix.fd_t,

pub fn init(io: std.Io, allocator: Allocator, allowed_uids: std.ArrayList(u32)) !UidTracker {
    const init_rc = linux.inotify_init1(inotify.IN_NONBLOCK | inotify.IN_CLOEXEC);
    if (std.posix.errno(init_rc) != .SUCCESS) {
        log.err("Failed to create inotify fd: {s}", .{@tagName(std.posix.errno(init_rc))});
        return error.InotifyInitFailed;
    }
    const ifd: std.posix.fd_t = @intCast(init_rc);
    errdefer _ = linux.close(ifd);

    // Watch /run/user for directory create/delete
    const wd_rc = linux.inotify_add_watch(ifd, run_user_dir, inotify.IN_CREATE | inotify.IN_DELETE | inotify.IN_MOVED_FROM | inotify.IN_MOVED_TO);
    if (std.posix.errno(wd_rc) != .SUCCESS) {
        log.err("Failed to add inotify watch on {s}: {s}", .{ run_user_dir, @tagName(std.posix.errno(wd_rc)) });
        return error.InotifyWatchFailed;
    }

    return UidTracker{
        .allocator = allocator,
        .io = io,
        .allowed_uids = allowed_uids,
        .entries = std.ArrayList(UidEntry).empty,
        .inotify_fd = ifd,
    };
}

pub fn deinit(self: *UidTracker) void {
    self.entries.deinit(self.allocator);
    self.allowed_uids.deinit(self.allocator);

    _ = linux.close(self.inotify_fd);
}

/// Initial scan: track existing /run/user/<uid>/ directories
/// that match allowed uids.
pub fn scanExisting(self: *UidTracker, io: std.Io) void {
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
            self.addUid(uid) catch |err| {
                log.warn("Failed to track uid={d}: {s}", .{ uid, @errorName(err) });
            };
        }
    }
}

/// Check if a uid is in the allowed list.
pub fn isUidAllowed(self: UidTracker, uid: std.posix.uid_t) bool {
    for (self.allowed_uids.items) |allowed| {
        if (allowed == uid) return true;
    }
    return false;
}

/// Track a UID entry.
fn addUid(self: *UidTracker, uid: std.posix.uid_t) !void {
    // Skip if already tracked
    for (self.entries.items) |entry| {
        if (entry.uid == uid) return;
    }

    try self.entries.append(self.allocator, .{ .uid = uid });
    log.info("Tracking uid={d}", .{uid});
}

/// Remove a UID entry.
fn removeUid(self: *UidTracker, uid: std.posix.uid_t) void {
    for (self.entries.items, 0..) |*entry, i| {
        if (entry.uid == uid) {
            _ = self.entries.orderedRemove(i);
            log.info("Stopped tracking uid={d}", .{uid});
            return;
        }
    }
}

/// Get list of currently active (tracked) UIDs.
pub fn getActiveUids(self: *UidTracker) std.ArrayList(u32) {
    var uids = std.ArrayList(u32).initCapacity(self.allocator, self.entries.items.len) catch return .empty;
    for (self.entries.items) |entry| {
        uids.appendAssumeCapacity(entry.uid);
    }
    return uids;
}

/// Process pending inotify events.
/// Returns UIDs that appeared/disappeared.
pub fn processInotifyEvents(self: *UidTracker, event_buf: []u8) UidEvents {
    var created = std.ArrayList(u32).initCapacity(self.allocator, 8) catch return .{ .created = .empty, .removed = .empty };
    var removed = std.ArrayList(u32).initCapacity(self.allocator, 8) catch return .{ .created = .empty, .removed = .empty };

    while (true) {
        const n = std.posix.read(self.inotify_fd, event_buf) catch |err| switch (err) {
            error.WouldBlock => return .{ .created = created, .removed = removed },
            else => {
                log.warn("Failed to read inotify events: {s}", .{@errorName(err)});
                return .{ .created = created, .removed = removed };
            },
        };
        if (n == 0) return .{ .created = created, .removed = removed };

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

            if (event.mask & (inotify.IN_CREATE | inotify.IN_MOVED_TO) != 0) {
                if (self.isUidAllowed(uid)) {
                    log.info("Detected new /run/user/{d} directory", .{uid});
                    self.addUid(uid) catch continue;
                    created.appendAssumeCapacity(uid);
                }
            } else if (event.mask & (inotify.IN_DELETE | inotify.IN_MOVED_FROM) != 0) {
                log.info("Detected removal of /run/user/{d} directory", .{uid});
                self.removeUid(uid);
                removed.appendAssumeCapacity(uid);
            }
        }
    }
}
