//! Server-side ACL scanner.
//!
//! Scans acl.d/ for <username>.json files and resolves to UIDs.
//! Used by Server to determine which UIDs need workers.
//!
//! File naming convention:
//!   User:           acl.d/<username>.json   — scanned for UID resolution
//!   Rule collection: acl.d/@<name>.json     — ignored by scanner (not a user)
//!
//! The server does NOT parse ACL grants or watch for changes.
//! Workers handle their own ACL loading and hot-reloading.

const std = @import("std");
const log = std.log.scoped(.acl_manager);
const Allocator = std.mem.Allocator;
const user_mod = @import("../user.zig");
const AclManager = @This();

allocator: Allocator,
acl_dir: []const u8,

pub fn init(allocator: Allocator, acl_dir: []const u8) AclManager {
    return .{
        .allocator = allocator,
        .acl_dir = acl_dir,
    };
}

pub fn deinit(self: *AclManager) void {
    _ = self;
}

/// Scan acl.d/ for <username>.json files and resolve to UIDs.
/// Skips files starting with '@' (rule collection files, not users).
/// Returns a list of deduplicated UIDs.
pub fn scanUids(self: AclManager, io: std.Io) std.ArrayList(u32) {
    var uid_set = std.AutoHashMap(u32, void).init(self.allocator);
    defer uid_set.deinit();

    var dir = std.Io.Dir.cwd().openDir(io, self.acl_dir, .{ .iterate = true }) catch |err| {
        log.warn("Failed to open ACL directory '{s}': {s}", .{ self.acl_dir, @errorName(err) });
        return .empty;
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        // Skip rule collection files (@<name>.json)
        if (entry.name.len > 0 and entry.name[0] == '@') continue;

        // Extract username: <name>.json → <name>
        const name = entry.name[0 .. entry.name.len - ".json".len];

        // Resolve username to UID
        const name_z = self.allocator.dupeZ(u8, name) catch continue;
        defer self.allocator.free(name_z);

        if (user_mod.getUid(name_z)) |uid| {
            uid_set.put(uid, {}) catch {};
        } else {
            log.warn("Failed to resolve username '{s}' to UID, skipping", .{name});
        }
    }

    var result = std.ArrayList(u32).initCapacity(self.allocator, uid_set.count()) catch return .empty;
    var it = uid_set.keyIterator();
    while (it.next()) |uid| {
        result.appendAssumeCapacity(uid.*);
    }
    return result;
}

// ============================================================
// Tests
// ============================================================

test "AclManager: scanUids with no directory returns empty" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var manager = init(allocator, "/nonexistent/acl/directory");
    defer manager.deinit();

    var uids = manager.scanUids(io);
    defer uids.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), uids.items.len);
}

/// Helper to create a temporary directory for ACL testing.
const TestAclDir = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    dir_path: []const u8,

    fn create(io: std.Io, allocator: std.mem.Allocator) !TestAclDir {
        var prng = std.Random.DefaultPrng.init(@intCast(std.os.linux.getpid()));
        const rand = prng.random().int(u64);
        const dir_path = try std.fmt.allocPrint(allocator, "/tmp/acl-scan-test-{x:0>16}", .{rand});
        try std.Io.Dir.cwd().createDirPath(io, dir_path);
        return TestAclDir{ .io = io, .allocator = allocator, .dir_path = dir_path };
    }

    fn deinit(self: TestAclDir) void {
        var dir = std.Io.Dir.cwd().openDir(self.io, self.dir_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var iter = dir.iterate();
        while (iter.next(self.io) catch null) |entry| {
            dir.deleteFile(self.io, entry.name) catch {};
        }
        std.Io.Dir.cwd().deleteDir(self.io, self.dir_path) catch {};
        self.allocator.free(self.dir_path);
    }

    fn writeFile(self: TestAclDir, filename: []const u8, content: []const u8) !void {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const file_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.dir_path, filename }) catch return;
        const file = try std.Io.Dir.cwd().createFile(self.io, file_path, .{});
        defer file.close(self.io);
        var write_buffer: [4096]u8 = undefined;
        var writer = file.writer(self.io, &write_buffer);
        writer.interface.writeAll(content) catch return;
        writer.end() catch return;
    }
};

test "AclManager: scanUids skips group files and non-json files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_dir = try TestAclDir.create(io, allocator);
    defer test_dir.deinit();

    // Create files — only root.json should resolve (uid 0)
    try test_dir.writeFile("root.json", "{}");
    try test_dir.writeFile("@group.json", "{}");
    try test_dir.writeFile("readme.txt", "ignored");

    var manager = init(allocator, test_dir.dir_path);
    defer manager.deinit();

    var uids = manager.scanUids(io);
    defer uids.deinit(allocator);

    // root should resolve to uid 0
    try std.testing.expectEqual(@as(usize, 1), uids.items.len);
    try std.testing.expect(uids.items[0] == 0);
}

test "AclManager: scanUids with empty directory returns empty" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_dir = try TestAclDir.create(io, allocator);
    defer test_dir.deinit();

    var manager = init(allocator, test_dir.dir_path);
    defer manager.deinit();

    var uids = manager.scanUids(io);
    defer uids.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), uids.items.len);
}
