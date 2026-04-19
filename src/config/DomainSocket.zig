const std = @import("std");
const log = std.log.scoped(.domain_socket);
const linux = std.os.linux;
const DomainSocket = @This();

/// Socket file name used under /run/user/<uid>/
pub const socket_name = "net-porter.sock";

/// Build the socket path for a given uid.
/// Returns a caller-owned slice allocated with `allocator`.
pub fn pathForUid(allocator: std.mem.Allocator, uid: std.posix.uid_t) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(allocator, "/run/user/{d}/{s}", .{ uid, socket_name }, 0);
}

/// Connect to a filesystem unix socket.
pub fn connect(io: std.Io, path: [:0]const u8) !std.Io.net.Stream {
    const address = try std.Io.net.UnixAddress.init(path);
    return address.connect(io);
}

/// Listen on a filesystem unix socket.
/// Creates the socket file, sets ownership to `uid`, and mode to 0600.
/// Security: rejects pre-existing symlinks at the path, verifies socket
/// integrity after bind, and uses path-based fchownat/fchmodat (not fd-based,
/// which operates on the sockfs inode invisible from the filesystem).
pub fn listen(io: std.Io, path: [:0]const u8, uid: std.posix.uid_t) !std.Io.net.Server {
    const address = try std.Io.net.UnixAddress.init(path);

    // Security: reject if path is a symlink (unexpected for socket path)
    if (isSymlink(path)) {
        log.warn("Refusing to create socket at symlink path: {s}", .{path});
        return error.SymlinkDetected;
    }

    // Remove stale socket file if it exists.
    if (std.Io.Dir.cwd().deleteFile(io, path)) {} else |err| switch (err) {
        error.FileNotFound => {},
        else => log.warn("Failed to remove stale socket {s}: {s}", .{ path, @errorName(err) }),
    }

    var server = address.listen(io, .{}) catch |e| {
        log.err("Failed to listen on {s}: {s}", .{ path, @errorName(e) });
        return e;
    };
    errdefer {
        server.deinit(io);
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }

    // Verify the created file is a socket (not a symlink replaced by attacker)
    if (isSymlink(path)) {
        log.err("Socket path replaced with symlink after bind: {s}", .{path});
        return error.SymlinkDetected;
    }

    // Set mode first (path-based, after verifying not a symlink)
    setModePath(path, 0o600) catch |err| {
        return err;
    };

    // Set ownership via path (after verifying not a symlink above).
    //
    // IMPORTANT: Do NOT use fd-based fchown on socket fds!
    // Unix domain sockets have two separate inodes:
    //   1. sockfs inode (kernel-internal, pointed to by socket fd)
    //   2. filesystem inode (visible via ls/stat, pointed to by path)
    // fchown(fd) operates on the sockfs inode — invisible from ls -l.
    // fchownat(path) operates on the filesystem inode — the one that matters.
    // This is the same reason setModePath uses path-based fchmodat.
    setOwnerPath(path, uid) catch |err| {
        return err;
    };

    return server;
}

/// Check if the given path is a symlink.
/// Returns false if the file does not exist or on error.
fn isSymlink(path: [:0]const u8) bool {
    var statx_buf: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, path, linux.AT.SYMLINK_NOFOLLOW, .{ .MODE = true }, &statx_buf);
    if (rc != 0) return false;
    return (statx_buf.mode & 0o170000) == 0o120000; // S_IFLNK
}

/// Set socket ownership via path (after verifying it is not a symlink).
///
/// IMPORTANT: Must use path-based fchownat, NOT fd-based fchown.
/// On Linux, a Unix domain socket bound to a path has TWO inodes:
///   - sockfs inode (kernel-internal, associated with the socket fd)
///   - filesystem inode (associated with the dentry, visible via ls/stat)
/// fchown(fd) changes the sockfs inode's ownership — invisible from the
/// filesystem perspective, so the socket file remains owned by root.
/// fchownat(path) changes the filesystem inode's ownership — the one that
/// actually controls access permissions and is visible via ls -l.
/// Symlink TOCTOU is prevented by isSymlink() checks before and after bind.
fn setOwnerPath(path: [:0]const u8, uid: std.posix.uid_t) !void {
    const rc = linux.fchownat(
        std.posix.AT.FDCWD,
        path,
        uid,
        @as(std.posix.gid_t, @bitCast(@as(i32, -1))), // gid unchanged (-1)
        0,
    );
    if (std.posix.errno(rc) != .SUCCESS) {
        log.warn("Failed to set socket owner for {s}", .{path});
        return error.PermissionFailed;
    }
}

/// Set socket mode via path (after verifying it is not a symlink).
fn setModePath(path: [:0]const u8, mode: std.posix.mode_t) !void {
    const rc = linux.fchmodat(std.posix.AT.FDCWD, path, mode);
    if (std.posix.errno(rc) != .SUCCESS) {
        log.warn("Failed to set socket mode for {s}", .{path});
        return error.PermissionFailed;
    }
}

// -- Tests --

test "pathForUid formats correctly" {
    const gpa = std.testing.allocator;
    const path = try pathForUid(gpa, 1000);
    defer gpa.free(path);
    try std.testing.expectEqualSlices(u8, "/run/user/1000/net-porter.sock", path);
}

test "listen creates socket and sets permissions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const uid = std.os.linux.getuid();
    const path_raw = try std.fmt.allocPrint(gpa, "/tmp/net-porter-test-perm-{}.sock", .{uid});
    defer gpa.free(path_raw);
    const path = try gpa.dupeZ(u8, path_raw);
    defer gpa.free(path);

    var server = try listen(io, path, uid);
    defer server.deinit(io);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var statx_buf: std.os.linux.Statx = undefined;
    const rc = std.os.linux.statx(std.os.linux.AT.FDCWD, path, 0, .{ .MODE = true, .UID = true }, &statx_buf);
    if (rc != 0) return error.Unexpected;
    const mode = statx_buf.mode & 0o777;
    try std.testing.expectEqual(@as(u16, 0o600), mode);
    // Verify ownership: fchown(fd) on socket fd would leave uid as 0 (root).
    // fchownat(path) correctly changes the filesystem inode's uid.
    try std.testing.expectEqual(uid, statx_buf.uid);
}

test "listen and connect round-trip" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const uid = std.os.linux.getuid();
    const path_raw = try std.fmt.allocPrint(gpa, "/tmp/net-porter-test-roundtrip-{}.sock", .{uid});
    defer gpa.free(path_raw);
    const path = try gpa.dupeZ(u8, path_raw);
    defer gpa.free(path);

    var server = try listen(io, path, uid);
    defer server.deinit(io);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const stream = try connect(io, path);
    stream.close(io);
}

test "isSymlink returns false for regular file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const uid = std.os.linux.getuid();
    const path_raw = try std.fmt.allocPrint(gpa, "/tmp/net-porter-test-symlink-{}.txt", .{uid});
    defer gpa.free(path_raw);
    const path = try gpa.dupeZ(u8, path_raw);
    defer gpa.free(path);

    // Create a regular file
    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return;
    file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try std.testing.expect(!isSymlink(path));
}

test "isSymlink returns false for non-existent path" {
    try std.testing.expect(!isSymlink("/tmp/nonexistent-net-porter-test-path-xyz"));
}

test "isSymlink returns true for symlink" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const uid = std.os.linux.getuid();

    // Create a regular file and a symlink to it
    const target_raw = try std.fmt.allocPrint(gpa, "/tmp/net-porter-test-symlink-target-{}.txt", .{uid});
    defer gpa.free(target_raw);
    const target = try gpa.dupeZ(u8, target_raw);
    defer gpa.free(target);

    const link_raw = try std.fmt.allocPrint(gpa, "/tmp/net-porter-test-symlink-link-{}.txt", .{uid});
    defer gpa.free(link_raw);
    const link = try gpa.dupeZ(u8, link_raw);
    defer gpa.free(link);

    const file = std.Io.Dir.cwd().createFile(io, target, .{}) catch return;
    file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, target) catch {};

    // Create symlink
    const link_rc = std.os.linux.symlink(target, link);
    if (link_rc != 0) return error.Unexpected;
    defer std.Io.Dir.cwd().deleteFile(io, link) catch {};

    try std.testing.expect(isSymlink(link));
}

test "listen rejects symlink path" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const uid = std.os.linux.getuid();

    // Create a regular file and a symlink to it
    const target_raw = try std.fmt.allocPrint(gpa, "/tmp/net-porter-test-reject-target-{}.sock", .{uid});
    defer gpa.free(target_raw);
    const target = try gpa.dupeZ(u8, target_raw);
    defer gpa.free(target);

    const link_raw = try std.fmt.allocPrint(gpa, "/tmp/net-porter-test-reject-link-{}.sock", .{uid});
    defer gpa.free(link_raw);
    const link = try gpa.dupeZ(u8, link_raw);
    defer gpa.free(link);

    const file = std.Io.Dir.cwd().createFile(io, target, .{}) catch return;
    file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, target) catch {};

    const link_rc = std.os.linux.symlink(target, link);
    if (link_rc != 0) return error.Unexpected;
    defer std.Io.Dir.cwd().deleteFile(io, link) catch {};

    const result = listen(io, link, uid);
    try std.testing.expectError(error.SymlinkDetected, result);
}


