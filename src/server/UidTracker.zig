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
pub const UidEntry = struct {
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
    if (@as(i64, @bitCast(init_rc)) < 0) {
        log.err("Failed to create inotify fd: {s}", .{@tagName(std.posix.errno(init_rc))});
        return error.InotifyInitFailed;
    }
    const ifd: std.posix.fd_t = @intCast(init_rc);
    errdefer _ = linux.close(ifd);

    // Watch /run/user for directory create/delete
    const wd_rc = linux.inotify_add_watch(ifd, run_user_dir, inotify.IN_CREATE | inotify.IN_DELETE | inotify.IN_MOVED_FROM | inotify.IN_MOVED_TO);
    if (@as(i64, @bitCast(wd_rc)) < 0) {
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

pub const UidDelta = struct {
    added: std.ArrayList(u32),
    removed: std.ArrayList(u32),

    pub fn deinit(self: *UidDelta, allocator: Allocator) void {
        self.added.deinit(allocator);
        self.removed.deinit(allocator);
    }
};

/// Replace the allowed UID list with a new one (caller transfers ownership).
/// Returns the delta of added and removed UIDs.
/// The caller must deinit the returned delta lists.
pub fn updateAllowedUids(self: *UidTracker, new_uids: std.ArrayList(u32)) UidDelta {
    // Zig function params are const; local mutable copy for ownership transfer
    var new_uids_owned = new_uids;
    // Upper bounds: added <= new_uids.len, removed <= old_uids.len
    var added = std.ArrayList(u32).initCapacity(self.allocator, new_uids_owned.items.len) catch {
        new_uids_owned.deinit(self.allocator);
        return .{ .added = .empty, .removed = .empty };
    };
    var removed = std.ArrayList(u32).initCapacity(self.allocator, self.allowed_uids.items.len) catch {
        added.deinit(self.allocator);
        new_uids_owned.deinit(self.allocator);
        return .{ .added = .empty, .removed = .empty };
    };

    var old_uids = self.allowed_uids;

    // Find UIDs in new list that are not in old list (added)
    for (new_uids_owned.items) |uid| {
        var found = false;
        for (old_uids.items) |old| {
            if (old == uid) {
                found = true;
                break;
            }
        }
        if (!found) {
            added.appendAssumeCapacity(uid);
        }
    }

    // Find UIDs in old list that are not in new list (removed)
    for (old_uids.items) |uid| {
        var found = false;
        for (new_uids_owned.items) |new_uid| {
            if (new_uid == uid) {
                found = true;
                break;
            }
        }
        if (!found) {
            removed.appendAssumeCapacity(uid);
        }
    }

    // Swap: deinit old, store new
    old_uids.deinit(self.allocator);
    self.allowed_uids = new_uids_owned;

    if (added.items.len > 0 or removed.items.len > 0) {
        log.info("ACL update: {} added, {} removed, {} total allowed", .{ added.items.len, removed.items.len, new_uids_owned.items.len });
    }

    return .{ .added = added, .removed = removed };
}

/// Check if a UID is currently in the active entries list.
pub fn isUidActive(self: UidTracker, uid: u32) bool {
    for (self.entries.items) |entry| {
        if (entry.uid == uid) return true;
    }
    return false;
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
            var event: std.os.linux.inotify_event = undefined;
            @memcpy(std.mem.asBytes(&event), event_buf[offset..][0..@sizeOf(std.os.linux.inotify_event)]);
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

test "updateAllowedUids detects added and removed UIDs" {
    const allocator = std.testing.allocator;

    var old_uids = std.ArrayList(u32).initCapacity(allocator, 3) catch return error.Unexpected;
    old_uids.appendAssumeCapacity(@as(u32, 1000));
    old_uids.appendAssumeCapacity(@as(u32, 2000));
    old_uids.appendAssumeCapacity(@as(u32, 3000));

    // Use a dummy inotify fd (will be closed in deinit, so use -1 to skip close)
    // We can't call init() in a test without /run/user, so construct manually
    var tracker = UidTracker{
        .allocator = allocator,
        .io = std.testing.io,
        .allowed_uids = old_uids,
        .entries = std.ArrayList(UidEntry).empty,
        .inotify_fd = -1,
    };
    // Override close for -1 fd in deinit
    defer {
        tracker.entries.deinit(allocator);
        tracker.allowed_uids.deinit(allocator);
    }

    // New list: keep 1000, remove 2000 and 3000, add 4000
    var new_uids = std.ArrayList(u32).initCapacity(allocator, 2) catch return error.Unexpected;
    new_uids.appendAssumeCapacity(@as(u32, 1000));
    new_uids.appendAssumeCapacity(@as(u32, 4000));

    var delta = tracker.updateAllowedUids(new_uids);
    defer delta.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), delta.added.items.len);
    try std.testing.expectEqual(@as(u32, 4000), delta.added.items[0]);

    try std.testing.expectEqual(@as(usize, 2), delta.removed.items.len);

    // Verify allowed_uids was replaced
    try std.testing.expectEqual(@as(usize, 2), tracker.allowed_uids.items.len);
    try std.testing.expect(tracker.isUidAllowed(1000));
    try std.testing.expect(!tracker.isUidAllowed(2000));
    try std.testing.expect(tracker.isUidAllowed(4000));
}

test "isUidActive returns false when no entries" {
    var tracker = UidTracker{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .allowed_uids = .empty,
        .entries = std.ArrayList(UidEntry).empty,
        .inotify_fd = -1,
    };
    defer {
        tracker.entries.deinit(std.testing.allocator);
    }

    try std.testing.expect(!tracker.isUidActive(1000));
}

test "updateAllowedUids with no change returns empty deltas" {
    const allocator = std.testing.allocator;

    var old_uids = std.ArrayList(u32).initCapacity(allocator, 2) catch return error.Unexpected;
    old_uids.appendAssumeCapacity(1000);
    old_uids.appendAssumeCapacity(2000);

    var tracker = UidTracker{
        .allocator = allocator,
        .io = std.testing.io,
        .allowed_uids = old_uids,
        .entries = std.ArrayList(UidEntry).empty,
        .inotify_fd = -1,
    };
    defer {
        tracker.entries.deinit(allocator);
        tracker.allowed_uids.deinit(allocator);
    }

    var new_uids = std.ArrayList(u32).initCapacity(allocator, 2) catch return error.Unexpected;
    new_uids.appendAssumeCapacity(1000);
    new_uids.appendAssumeCapacity(2000);

    var delta = tracker.updateAllowedUids(new_uids);
    defer delta.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), delta.added.items.len);
    try std.testing.expectEqual(@as(usize, 0), delta.removed.items.len);
    try std.testing.expectEqual(@as(usize, 2), tracker.allowed_uids.items.len);
}

test "updateAllowedUids with only additions" {
    const allocator = std.testing.allocator;

    var old_uids = std.ArrayList(u32).initCapacity(allocator, 1) catch return error.Unexpected;
    old_uids.appendAssumeCapacity(1000);

    var tracker = UidTracker{
        .allocator = allocator,
        .io = std.testing.io,
        .allowed_uids = old_uids,
        .entries = std.ArrayList(UidEntry).empty,
        .inotify_fd = -1,
    };
    defer {
        tracker.entries.deinit(allocator);
        tracker.allowed_uids.deinit(allocator);
    }

    var new_uids = std.ArrayList(u32).initCapacity(allocator, 3) catch return error.Unexpected;
    new_uids.appendAssumeCapacity(1000);
    new_uids.appendAssumeCapacity(2000);
    new_uids.appendAssumeCapacity(3000);

    var delta = tracker.updateAllowedUids(new_uids);
    defer delta.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), delta.added.items.len);
    try std.testing.expectEqual(@as(u32, 2000), delta.added.items[0]);
    try std.testing.expectEqual(@as(u32, 3000), delta.added.items[1]);
    try std.testing.expectEqual(@as(usize, 0), delta.removed.items.len);
}

test "updateAllowedUids with only removals" {
    const allocator = std.testing.allocator;

    var old_uids = std.ArrayList(u32).initCapacity(allocator, 3) catch return error.Unexpected;
    old_uids.appendAssumeCapacity(1000);
    old_uids.appendAssumeCapacity(2000);
    old_uids.appendAssumeCapacity(3000);

    var tracker = UidTracker{
        .allocator = allocator,
        .io = std.testing.io,
        .allowed_uids = old_uids,
        .entries = std.ArrayList(UidEntry).empty,
        .inotify_fd = -1,
    };
    defer {
        tracker.entries.deinit(allocator);
        tracker.allowed_uids.deinit(allocator);
    }

    var new_uids = std.ArrayList(u32).initCapacity(allocator, 1) catch return error.Unexpected;
    new_uids.appendAssumeCapacity(1000);

    var delta = tracker.updateAllowedUids(new_uids);
    defer delta.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), delta.added.items.len);
    try std.testing.expectEqual(@as(usize, 2), delta.removed.items.len);
    try std.testing.expectEqual(@as(u32, 2000), delta.removed.items[0]);
    try std.testing.expectEqual(@as(u32, 3000), delta.removed.items[1]);
}

test "updateAllowedUids with empty old list adds all as new" {
    const allocator = std.testing.allocator;

    const old_uids = std.ArrayList(u32).empty;

    var tracker = UidTracker{
        .allocator = allocator,
        .io = std.testing.io,
        .allowed_uids = old_uids,
        .entries = std.ArrayList(UidEntry).empty,
        .inotify_fd = -1,
    };
    defer {
        tracker.entries.deinit(allocator);
        tracker.allowed_uids.deinit(allocator);
    }

    var new_uids = std.ArrayList(u32).initCapacity(allocator, 2) catch return error.Unexpected;
    new_uids.appendAssumeCapacity(1000);
    new_uids.appendAssumeCapacity(2000);

    var delta = tracker.updateAllowedUids(new_uids);
    defer delta.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), delta.added.items.len);
    try std.testing.expectEqual(@as(usize, 0), delta.removed.items.len);
}

test "updateAllowedUids with empty new list removes all old" {
    const allocator = std.testing.allocator;

    var old_uids = std.ArrayList(u32).initCapacity(allocator, 2) catch return error.Unexpected;
    old_uids.appendAssumeCapacity(1000);
    old_uids.appendAssumeCapacity(2000);

    var tracker = UidTracker{
        .allocator = allocator,
        .io = std.testing.io,
        .allowed_uids = old_uids,
        .entries = std.ArrayList(UidEntry).empty,
        .inotify_fd = -1,
    };
    defer {
        tracker.entries.deinit(allocator);
        tracker.allowed_uids.deinit(allocator);
    }

    const new_uids = std.ArrayList(u32).empty;

    var delta = tracker.updateAllowedUids(new_uids);
    defer delta.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), delta.added.items.len);
    try std.testing.expectEqual(@as(usize, 2), delta.removed.items.len);
    try std.testing.expectEqual(@as(usize, 0), tracker.allowed_uids.items.len);
}

test "updateAllowedUids mixed add and remove with overlap" {
    const allocator = std.testing.allocator;

    var old_uids = std.ArrayList(u32).initCapacity(allocator, 3) catch return error.Unexpected;
    old_uids.appendAssumeCapacity(1000);
    old_uids.appendAssumeCapacity(2000);
    old_uids.appendAssumeCapacity(3000);

    var tracker = UidTracker{
        .allocator = allocator,
        .io = std.testing.io,
        .allowed_uids = old_uids,
        .entries = std.ArrayList(UidEntry).empty,
        .inotify_fd = -1,
    };
    defer {
        tracker.entries.deinit(allocator);
        tracker.allowed_uids.deinit(allocator);
    }

    // Keep 2000, remove 1000 and 3000, add 4000 and 5000
    var new_uids = std.ArrayList(u32).initCapacity(allocator, 3) catch return error.Unexpected;
    new_uids.appendAssumeCapacity(2000);
    new_uids.appendAssumeCapacity(4000);
    new_uids.appendAssumeCapacity(5000);

    var delta = tracker.updateAllowedUids(new_uids);
    defer delta.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), delta.added.items.len);
    try std.testing.expectEqual(@as(u32, 4000), delta.added.items[0]);
    try std.testing.expectEqual(@as(u32, 5000), delta.added.items[1]);

    try std.testing.expectEqual(@as(usize, 2), delta.removed.items.len);
    try std.testing.expectEqual(@as(u32, 1000), delta.removed.items[0]);
    try std.testing.expectEqual(@as(u32, 3000), delta.removed.items[1]);

    try std.testing.expectEqual(@as(usize, 3), tracker.allowed_uids.items.len);
    try std.testing.expect(tracker.isUidAllowed(2000));
    try std.testing.expect(tracker.isUidAllowed(4000));
    try std.testing.expect(tracker.isUidAllowed(5000));
    try std.testing.expect(!tracker.isUidAllowed(1000));
    try std.testing.expect(!tracker.isUidAllowed(3000));
}

test "isUidActive returns true for tracked UIDs" {
    const allocator = std.testing.allocator;

    var entries = std.ArrayList(UidEntry).initCapacity(allocator, 2) catch return error.Unexpected;
    entries.appendAssumeCapacity(.{ .uid = 1000 });
    entries.appendAssumeCapacity(.{ .uid = 2000 });

    var tracker = UidTracker{
        .allocator = allocator,
        .io = std.testing.io,
        .allowed_uids = .empty,
        .entries = entries,
        .inotify_fd = -1,
    };
    defer tracker.entries.deinit(allocator);

    try std.testing.expect(tracker.isUidActive(1000));
    try std.testing.expect(tracker.isUidActive(2000));
}

test "isUidActive returns false for non-tracked UIDs" {
    const allocator = std.testing.allocator;

    var entries = std.ArrayList(UidEntry).initCapacity(allocator, 1) catch return error.Unexpected;
    entries.appendAssumeCapacity(.{ .uid = 1000 });

    var tracker = UidTracker{
        .allocator = allocator,
        .io = std.testing.io,
        .allowed_uids = .empty,
        .entries = entries,
        .inotify_fd = -1,
    };
    defer tracker.entries.deinit(allocator);

    try std.testing.expect(!tracker.isUidActive(2000));
    try std.testing.expect(!tracker.isUidActive(3000));
    try std.testing.expect(!tracker.isUidActive(0));
}

test "isUidAllowed returns true for allowed UIDs" {
    const allocator = std.testing.allocator;

    var allowed = std.ArrayList(u32).initCapacity(allocator, 2) catch return error.Unexpected;
    allowed.appendAssumeCapacity(1000);
    allowed.appendAssumeCapacity(2000);

    var tracker = UidTracker{
        .allocator = allocator,
        .io = std.testing.io,
        .allowed_uids = allowed,
        .entries = std.ArrayList(UidEntry).empty,
        .inotify_fd = -1,
    };
    defer {
        tracker.entries.deinit(allocator);
        tracker.allowed_uids.deinit(allocator);
    }

    try std.testing.expect(tracker.isUidAllowed(1000));
    try std.testing.expect(tracker.isUidAllowed(2000));
    try std.testing.expect(!tracker.isUidAllowed(3000));
    try std.testing.expect(!tracker.isUidAllowed(0));
}
