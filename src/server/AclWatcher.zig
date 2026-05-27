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
const AclScanner = @import("AclScanner.zig");
const AclWatcher = @This();

allocator: Allocator,
io: std.Io,
acl_dir: []const u8,
inotify_fd: ?std.posix.fd_t,

pub fn init(allocator: Allocator, io: std.Io, acl_dir: []const u8) ?AclWatcher {
    const init_rc = linux.inotify_init1(inotify.IN_NONBLOCK | inotify.IN_CLOEXEC);
    if (@as(i64, @bitCast(init_rc)) < 0) {
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
    defer allocator.free(acl_dir_z);
    @memcpy(acl_dir_z[0..acl_dir.len], acl_dir);

    const wd_rc = linux.inotify_add_watch(ifd, acl_dir_z, inotify.IN_CREATE | inotify.IN_DELETE | inotify.IN_MODIFY | inotify.IN_MOVED_FROM | inotify.IN_MOVED_TO | inotify.IN_CLOSE_WRITE);
    if (@as(i64, @bitCast(wd_rc)) < 0) {
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
            if (offset + @sizeOf(std.os.linux.inotify_event) > n) break;

            var event: std.os.linux.inotify_event = undefined;
            @memcpy(std.mem.asBytes(&event), event_buf[offset..][0..@sizeOf(std.os.linux.inotify_event)]);
            offset += @sizeOf(std.os.linux.inotify_event) + event.len;

            if (event.len == 0) continue;
            if (offset > n) break;

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
    if (filename[0] == '@' or filename[0] == '.') return false;
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
    try std.testing.expect(!isRelevantFile("@group.json"));
    try std.testing.expect(!isRelevantFile("readme.txt"));
    try std.testing.expect(!isRelevantFile("alice.json.bak"));
    try std.testing.expect(!isRelevantFile(""));
    try std.testing.expect(!isRelevantFile("alice"));
    try std.testing.expect(!isRelevantFile("my.json.txt"));
    try std.testing.expect(!isRelevantFile("json"));
    try std.testing.expect(!isRelevantFile(".json"));
    try std.testing.expect(!isRelevantFile(".hidden.json"));
    try std.testing.expect(!isRelevantFile("@rule.json"));
}

test "init returns null when directory does not exist" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const watcher = AclWatcher.init(allocator, io, "/nonexistent/acl/dir/12345");
    try std.testing.expect(watcher == null);
}

test "init succeeds with existing temp directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_dir = try AclScanner.TestAclDir.create(io, allocator);
    defer test_dir.deinit();

    var watcher = AclWatcher.init(allocator, io, test_dir.dir_path) orelse return error.Unexpected;
    defer watcher.deinit();

    try std.testing.expect(watcher.getInotifyFd() != null);
    const fd = watcher.getInotifyFd().?;
    try std.testing.expect(fd >= 0);
}

test "getInotifyFd returns null after deinit" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_dir = try AclScanner.TestAclDir.create(io, allocator);
    defer test_dir.deinit();

    var watcher = AclWatcher.init(allocator, io, test_dir.dir_path) orelse return error.Unexpected;
    try std.testing.expect(watcher.getInotifyFd() != null);
    watcher.deinit();
    try std.testing.expect(watcher.getInotifyFd() == null);
}

test "processInotifyEvents detects .json file creation in watched directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_dir = try AclScanner.TestAclDir.create(io, allocator);
    defer test_dir.deinit();

    var watcher = AclWatcher.init(allocator, io, test_dir.dir_path) orelse return error.Unexpected;
    defer watcher.deinit();

    // Create a .json file to trigger an inotify event
    try test_dir.writeFile("test.json", "{}");

    var event_buf: [4096]u8 = undefined;
    const changed = watcher.processInotifyEvents(&event_buf);
    try std.testing.expect(changed);
}

test "processInotifyEvents ignores non-json file creation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_dir = try AclScanner.TestAclDir.create(io, allocator);
    defer test_dir.deinit();

    var watcher = AclWatcher.init(allocator, io, test_dir.dir_path) orelse return error.Unexpected;
    defer watcher.deinit();

    // Create a non-.json file
    try test_dir.writeFile("readme.txt", "hello");

    var event_buf: [4096]u8 = undefined;
    const changed = watcher.processInotifyEvents(&event_buf);
    try std.testing.expect(!changed);
}

test "processInotifyEvents ignores @group and dotfiles" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_dir = try AclScanner.TestAclDir.create(io, allocator);
    defer test_dir.deinit();

    var watcher = AclWatcher.init(allocator, io, test_dir.dir_path) orelse return error.Unexpected;
    defer watcher.deinit();

    // Create rule collection and hidden files — should NOT trigger re-scan
    try test_dir.writeFile("@group.json", "{}");
    try test_dir.writeFile(".hidden.json", "{}");

    var event_buf: [4096]u8 = undefined;
    const changed = watcher.processInotifyEvents(&event_buf);
    try std.testing.expect(!changed);
}
