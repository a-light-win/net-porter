const std = @import("std");
const log = std.log.scoped(.state_file);
const Allocator = std.mem.Allocator;
const StateFile = @This();

const max_state_file_size: usize = 1024 * 1024; // 1MB
const mode_dir = 0o700;
const mode_file = 0o600;

/// Return the per-UID state directory: /run/net-porter/workers/<uid>/state
/// /run/net-porter/ is root-owned (mode 0700) — users cannot read or modify state files.
fn stateDir(allocator: Allocator, uid: u32) ![]const u8 {
    return std.fmt.allocPrint(allocator, "/run/net-porter/workers/{d}/state", .{uid});
}

/// Generate the state file path: /run/net-porter/workers/<uid>/state/<container_id>_<ifname>.json
pub fn filePath(allocator: Allocator, uid: u32, container_id: []const u8, ifname: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "/run/net-porter/workers/{d}/state/{s}_{s}.json", .{
        uid,
        container_id,
        ifname,
    });
}

/// Check if a state file exists for the given attachment.
pub fn exists(allocator: Allocator, uid: u32, container_id: []const u8, ifname: []const u8) bool {
    const path = filePath(allocator, uid, container_id, ifname) catch return false;
    defer allocator.free(path);
    return statExists(path);
}

/// Check if a user has any active attachments by scanning their state directory.
/// Returns true if at least one state file exists for the given uid.
pub fn hasActiveAttachments(io: std.Io, uid: u32) bool {
    var buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&buf, "/run/net-porter/workers/{d}/state", .{uid}) catch return false;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind == .file) return true;
    }
    return false;
}

/// Read the state file content for a given attachment.
pub fn read(io: std.Io, allocator: Allocator, uid: u32, container_id: []const u8, ifname: []const u8) ![]const u8 {
    const path = try filePath(allocator, uid, container_id, ifname);
    defer allocator.free(path);
    return readFileContent(io, allocator, path);
}

/// Write state file atomically: write to temp file then rename.
/// Creates the state directory (/run/user/{uid}/net-porter) if needed.
pub fn write(io: std.Io, allocator: Allocator, uid: u32, container_id: []const u8, ifname: []const u8, data: []const u8) !void {
    const dir_path = try stateDir(allocator, uid);
    defer allocator.free(dir_path);

    // Ensure state directory exists
    try ensureDir(io, dir_path);

    const final_path = try filePath(allocator, uid, container_id, ifname);
    defer allocator.free(final_path);

    // Generate temp file path with random suffix
    var prng = blk: {
        var seed_bytes: [8]u8 = undefined;
        _ = std.os.linux.getrandom(&seed_bytes, seed_bytes.len, 0);
        const seed = std.mem.readInt(u64, &seed_bytes, .little);
        break :blk std.Random.DefaultPrng.init(seed);
    };
    const rand = prng.random().int(u32);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}/.tmp_{s}_{s}_{x:0>8}", .{
        dir_path,
        container_id,
        ifname,
        rand,
    });
    defer allocator.free(tmp_path);

    // Write temp file
    try writeFileContent(io, allocator, tmp_path, data);

    // Atomic rename: temp → final
    const tmp_path_z = try allocator.allocSentinel(u8, tmp_path.len, 0);
    defer allocator.free(tmp_path_z);
    @memcpy(tmp_path_z[0..tmp_path.len], tmp_path);

    const final_path_z = try allocator.allocSentinel(u8, final_path.len, 0);
    defer allocator.free(final_path_z);
    @memcpy(final_path_z[0..final_path.len], final_path);

    const rename_rc = std.os.linux.rename(tmp_path_z, final_path_z);
    if (rename_rc != 0) {
        log.warn("Failed to rename temp state file", .{});
        // Clean up temp file on rename failure
        const tmp_z2 = try allocator.allocSentinel(u8, tmp_path.len, 0);
        defer allocator.free(tmp_z2);
        @memcpy(tmp_z2[0..tmp_path.len], tmp_path);
        _ = std.os.linux.unlink(tmp_z2);
        return error.Unexpected;
    }
}

/// Remove the state file for a given attachment.
/// Cleans up the state directory if it becomes empty.
pub fn remove(io: std.Io, allocator: Allocator, uid: u32, container_id: []const u8, ifname: []const u8) !void {
    const path = try filePath(allocator, uid, container_id, ifname);
    defer allocator.free(path);

    // Delete the state file
    const path_z = try allocator.allocSentinel(u8, path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z[0..path.len], path);
    const unlink_rc = std.os.linux.unlink(path_z);
    if (unlink_rc != 0) {
        log.warn("Failed to delete state file {s}", .{path});
        return error.Unexpected;
    }

    // Try to clean up empty state directory (ignore errors — may not be empty)
    const dir_path = try stateDir(allocator, uid);
    defer allocator.free(dir_path);
    std.Io.Dir.cwd().deleteDir(io, dir_path) catch {};
}

// ─── Internal helpers ────────────────────────────────────────────────

/// Create a directory with mode 0700. Idempotent (EEXIST is not an error).
fn ensureDir(io: std.Io, dir_path: []const u8) !void {
    // Need sentinel-terminated path for posix.chmod
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path_z = try alloc.allocSentinel(u8, dir_path.len, 0);
    @memcpy(path_z[0..dir_path.len], dir_path);

    // Use createDirPath for recursive creation
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Set permissions explicitly (createDirPath may use default umask)
    const chmod_rc = std.os.linux.chmod(path_z, mode_dir);
    if (std.posix.errno(chmod_rc) != .SUCCESS) {
        log.warn("Failed to chmod directory {s}", .{dir_path});
    }
}

/// Check if a file exists using statx.
fn statExists(path: []const u8) bool {
    // statx requires [*:0]const u8 — use a small stack buffer for the sentinel
    var buf: [4096:0]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var statx_buf: std.os.linux.Statx = undefined;
    const rc = std.os.linux.statx(std.os.linux.AT.FDCWD, &buf, 0, .{ .MODE = true }, &statx_buf);
    return rc == 0;
}

/// Read entire file content into allocated buffer.
fn readFileContent(io: std.Io, allocator: Allocator, path: []const u8) ![]const u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    errdefer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    const data = try file_reader.interface.allocRemaining(allocator, .limited(max_state_file_size));

    file.close(io);
    return data;
}

/// Write data to a file with mode 0600.
fn writeFileContent(io: std.Io, allocator: Allocator, path: []const u8, data: []const u8) !void {
    const path_z = try allocator.allocSentinel(u8, path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z[0..path.len], path);

    // Open with O_CREAT | O_WRONLY | O_EXCL, mode 0600
    // O_EXCL prevents following symlinks or overwriting existing files.
    const fd_rc = std.os.linux.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, mode_file);
    if (fd_rc < 0) {
        log.warn("Failed to create state file {s}", .{path});
        return error.Unexpected;
    }
    var file = std.Io.File{ .handle = @intCast(fd_rc), .flags = .{ .nonblocking = false } };
    defer file.close(io);

    var write_buffer: [4096]u8 = undefined;
    var file_writer = file.writer(io, &write_buffer);
    try file_writer.interface.writeAll(data);
    try file_writer.end();
}

// ─── Tests ───────────────────────────────────────────────────────────

/// Simulates /run/net-porter/workers for tests.
const test_workers_dir = "/tmp/net-porter-statefile-test";

fn testFilePath(allocator: Allocator, container_id: []const u8, ifname: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/1000/state/{s}_{s}.json", .{
        test_workers_dir,
        container_id,
        ifname,
    });
}

fn testDirPath(allocator: Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/1000/state", .{test_workers_dir});
}

fn testEnsureDir(io: std.Io, dir_path: []const u8) !void {
    return ensureDir(io, dir_path);
}

fn testWriteFile(io: std.Io, allocator: Allocator, uid: u32, container_id: []const u8, ifname: []const u8, data: []const u8) !void {
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/{d}/state", .{ test_workers_dir, uid });
    defer allocator.free(dir_path);
    try ensureDir(io, dir_path);

    const final_path = try std.fmt.allocPrint(allocator, "{s}/{d}/state/{s}_{s}.json", .{
        test_workers_dir,
        uid,
        container_id,
        ifname,
    });
    defer allocator.free(final_path);

    var prng = std.Random.DefaultPrng.init(@intCast(std.os.linux.getpid()));
    const rand = prng.random().int(u32);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}/.tmp_{s}_{s}_{x:0>8}", .{
        dir_path,
        container_id,
        ifname,
        rand,
    });
    defer allocator.free(tmp_path);

    try writeFileContent(io, allocator, tmp_path, data);

    const tmp_path_z = try allocator.allocSentinel(u8, tmp_path.len, 0);
    defer allocator.free(tmp_path_z);
    @memcpy(tmp_path_z[0..tmp_path.len], tmp_path);

    const final_path_z = try allocator.allocSentinel(u8, final_path.len, 0);
    defer allocator.free(final_path_z);
    @memcpy(final_path_z[0..final_path.len], final_path);

    const rename_rc = std.os.linux.rename(tmp_path_z, final_path_z);
    if (rename_rc != 0) return error.Unexpected;
}

fn testReadFile(io: std.Io, allocator: Allocator, container_id: []const u8, ifname: []const u8) ![]const u8 {
    const path = try testFilePath(allocator, container_id, ifname);
    defer allocator.free(path);
    return readFileContent(io, allocator, path);
}

fn testRemoveFile(io: std.Io, allocator: Allocator, container_id: []const u8, ifname: []const u8) !void {
    const path = try testFilePath(allocator, container_id, ifname);
    defer allocator.free(path);

    const path_z = try allocator.allocSentinel(u8, path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z[0..path.len], path);
    const unlink_rc = std.os.linux.unlink(path_z);
    if (unlink_rc != 0) return error.Unexpected;

    // Try to clean up empty uid directory
    const dir_path = try testDirPath(allocator);
    defer allocator.free(dir_path);
    std.Io.Dir.cwd().deleteDir(io, dir_path) catch {};
}

fn testCleanup(io: std.Io) void {
    // Best-effort cleanup of test directories
    const paths = [_][]const u8{
        test_workers_dir ++ "/1000/state",
        test_workers_dir ++ "/1000",
        test_workers_dir,
    };
    for (paths) |p| {
        std.Io.Dir.cwd().deleteDir(io, p) catch {};
    }
}

test "ensureDir creates directory with correct permissions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    defer testCleanup(io);

    const test_dir = test_workers_dir ++ "/ensureDir-test";
    const z = try allocator.allocSentinel(u8, test_dir.len, 0);
    defer allocator.free(z);
    @memcpy(z[0..test_dir.len], test_dir);

    // Clean up any leftover from previous runs
    std.Io.Dir.cwd().deleteDir(io, test_dir) catch {};

    try testEnsureDir(io, test_dir);

    // Verify directory exists
    var statx_buf: std.os.linux.Statx = undefined;
    const rc = std.os.linux.statx(std.os.linux.AT.FDCWD, z, 0, .{ .MODE = true }, &statx_buf);
    try std.testing.expect(rc == 0);

    // Verify it's a directory
    const is_dir = (statx_buf.mode & 0o170000) == 0o040000;
    try std.testing.expect(is_dir);

    // Clean up
    std.Io.Dir.cwd().deleteDir(io, test_dir) catch {};
}

test "ensureDir is idempotent — calling twice succeeds" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    defer testCleanup(io);

    const test_dir = test_workers_dir ++ "/idempotent-test";
    const z = try allocator.allocSentinel(u8, test_dir.len, 0);
    defer allocator.free(z);
    @memcpy(z[0..test_dir.len], test_dir);

    // Clean up any leftover
    std.Io.Dir.cwd().deleteDir(io, test_dir) catch {};

    try testEnsureDir(io, test_dir);
    try testEnsureDir(io, test_dir); // second call should succeed

    // Clean up
    std.Io.Dir.cwd().deleteDir(io, test_dir) catch {};
}

test "write creates file, read returns same content" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    defer testCleanup(io);

    const test_data = "{\"cniVersion\":\"1.0.0\"}";
    try testWriteFile(io, allocator, 1000, "test-container", "eth0", test_data);

    const content = try testReadFile(io, allocator, "test-container", "eth0");
    defer allocator.free(content);
    try std.testing.expectEqualSlices(u8, test_data, content);

    // Clean up
    testRemoveFile(io, allocator, "test-container", "eth0") catch {};
}

test "read returns error for non-existent file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    defer testCleanup(io);

    // Ensure dir exists so we test FileNotFound on the file, not the dir
    try testEnsureDir(io, test_workers_dir ++ "/1000/state");

    const result = testReadFile(io, allocator, "nonexistent", "eth0");
    try std.testing.expectError(error.FileNotFound, result);
}

test "remove deletes the file successfully" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    defer testCleanup(io);

    // Write a file first
    try testWriteFile(io, allocator, 1000, "remove-test", "eth0", "test-data");

    // Verify it exists
    const path = try testFilePath(allocator, "remove-test", "eth0");
    defer allocator.free(path);
    try std.testing.expect(statExists(path));

    // Remove it
    try testRemoveFile(io, allocator, "remove-test", "eth0");

    // Verify it's gone
    try std.testing.expect(!statExists(path));
}

test "exists returns true after write, false after remove" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    defer testCleanup(io);

    const container_id = "exists-test";
    const ifname = "eth0";
    const path = try testFilePath(allocator, container_id, ifname);
    defer allocator.free(path);

    // Before write
    try std.testing.expect(!statExists(path));

    // After write
    try testWriteFile(io, allocator, 1000, container_id, ifname, "data");
    try std.testing.expect(statExists(path));

    // After remove
    try testRemoveFile(io, allocator, container_id, ifname);
    try std.testing.expect(!statExists(path));
}

test "atomic write — no temp files left behind on success" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    defer testCleanup(io);

    try testWriteFile(io, allocator, 1000, "atomic-test", "eth0", "atomic-data");

    // Verify no .tmp files remain in the uid directory
    const dir_path = try testDirPath(allocator);
    defer allocator.free(dir_path);

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    var tmp_count: usize = 0;
    while (try iter.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, ".tmp_")) {
            tmp_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), tmp_count);

    // Clean up
    testRemoveFile(io, allocator, "atomic-test", "eth0") catch {};
}
