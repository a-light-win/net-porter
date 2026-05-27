//! Server-side ACL directory watcher.
//!
//! Watches acl.d/ via inotify for file changes and triggers a full re-scan
//! when relevant files are created/deleted/modified.
//!
//! The re-scan rebuilds the allowed UID list from scratch:
//!   - Resolves <username>.json → UID via system user database
//!   - Skips @<name>.json (rule collections, not users)
//!   - Unresolvable usernames are logged and skipped

const std = @import("std");
const log = std.log.scoped(.acl_watcher);
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const inotify = @import("../utils/Inotify.zig");
const AclWatcher = @This();

allocator: Allocator,
io: std.Io,
acl_dir: []const u8,
inotify_fd: ?std.posix.fd_t,

pub fn init(allocator: Allocator, io: std.Io, acl_dir: []const u8) ?AclWatcher {
    const init_rc = linux.inotify_init1(inotify.IN_NONBLOCK | inotify.IN_CLOEXEC);
    if (std.posix.errno(init_rc) != .SUCCESS) {
        log.warn("Failed to create inotify fd for acl.d: {s}", .{@tagName(std.posix.errno(init_rc))});
        return null;
    }
    const ifd: std.posix.fd_t = @intCast(init_rc);
    var ifd_owned = true;
    defer {
        if (ifd_owned) _ = linux.close(ifd);
    }

    const acl_dir_z = allocator.allocSentinel(u8, acl_dir.len, 0) catch {
        log.warn("Failed to allocate path for acl.d watch: {s}", .{acl_dir});
        return null;
    };
    @memcpy(acl_dir_z[0..acl_dir.len], acl_dir);

    const wd_rc = linux.inotify_add_watch(ifd, acl_dir_z, inotify.IN_CREATE | inotify.IN_DELETE | inotify.IN_MODIFY | inotify.IN_MOVED_FROM | inotify.IN_MOVED_TO | inotify.IN_CLOSE_WRITE);
    if (std.posix.errno(wd_rc) != .SUCCESS) {
        log.warn("Failed to add inotify watch on acl.d '{s}': {s}", .{ acl_dir, @tagName(std.posix.errno(wd_rc)) });
        return null;
    }

    ifd_owned = false;
    log.info("Watching ACL directory: {s}", .{acl_dir});

    return AclWatcher{
        .allocator = allocator,
        .io = io,
        .acl_dir = acl_dir,
        .inotify_fd = ifd,
    };
}

pub fn deinit(self: *AclWatcher) void {
    if (self.inotify_fd) |fd| {
        _ = linux.close(fd);
        self.inotify_fd = null;
    }
}

pub fn processInotifyEvents(self: *AclWatcher, event_buf: []u8) bool {
    const fd = self.inotify_fd orelse return false;
    var changed = false;

    while (true) {
        const n = std.posix.read(fd, event_buf) catch |err| switch (err) {
            error.WouldBlock => return changed,
            else => {
                log.warn("Failed to read inotify events from acl.d: {s}", .{@errorName(err)});
                return changed;
            },
        };
        if (n == 0) return changed;

        var offset: usize = 0;
        while (offset < n) {
            const event_ptr: *align(4) std.os.linux.inotify_event = @ptrCast(@alignCast(event_buf[offset..].ptr));
            const event = event_ptr.*;
            offset += @sizeOf(std.os.linux.inotify_event) + event.len;

            if (event.len == 0) continue;

            const name_start = offset - event.len;
            const name = std.mem.sliceTo(event_buf[name_start..], 0);

            if (isRelevantFile(name)) {
                log.info("ACL file changed: {s}, triggering re-scan", .{name});
                changed = true;
            }
        }
    }
}

pub fn getInotifyFd(self: AclWatcher) ?std.posix.fd_t {
    return self.inotify_fd;
}

fn isRelevantFile(filename: []const u8) bool {
    if (filename.len == 0) return false;
    return std.mem.endsWith(u8, filename, ".json");
}

test "processInotifyEvents returns false when no fd" {
    var watcher = AclWatcher{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .acl_dir = "/tmp",
        .inotify_fd = null,
    };

    var event_buf: [4096]u8 = undefined;
    try std.testing.expect(!watcher.processInotifyEvents(&event_buf));
}

test "isRelevantFile correctly filters .json files" {
    try std.testing.expect(isRelevantFile("alice.json"));
    try std.testing.expect(isRelevantFile("bob.json"));
    try std.testing.expect(isRelevantFile("@group.json"));
    try std.testing.expect(!isRelevantFile("readme.txt"));
    try std.testing.expect(!isRelevantFile("alice.json.bak"));
    try std.testing.expect(!isRelevantFile(""));
    try std.testing.expect(!isRelevantFile("alice"));
}
