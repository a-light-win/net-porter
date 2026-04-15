const std = @import("std");
const log = std.log.scoped(.domain_socket);
const c = @cImport({
    @cInclude("unistd.h");
});
const DomainSocket = @This();

/// Socket file name used under /run/user/<uid>/
pub const socket_name = "net-porter.sock";

/// Build the socket path for a given uid.
/// Returns a caller-owned slice allocated with `allocator`.
pub fn pathForUid(allocator: std.mem.Allocator, uid: std.posix.uid_t) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(allocator, "/run/user/{d}/{s}", .{ uid, socket_name }, 0);
}

/// Connect to a filesystem unix socket.
pub fn connect(path: [:0]const u8) !std.net.Stream {
    return try std.net.connectUnixSocket(path);
}

/// Listen on a filesystem unix socket.
/// Creates the socket file, sets ownership to `uid`, and mode to 0600.
pub fn listen(path: [:0]const u8, uid: std.posix.uid_t) !std.net.Server {
    const address = try std.net.Address.initUnix(path);

    // Remove stale socket file if it exists
    std.fs.cwd().deleteFile(path) catch {};

    const server = address.listen(.{}) catch |e| {
        log.err("Failed to listen on {s}: {s}", .{ path, @errorName(e) });
        return e;
    };

    setOwner(path, uid);
    setMode(path, 0o600);

    return server;
}

fn setOwner(path: [:0]const u8, uid: std.posix.uid_t) void {
    const ret = c.fchownat(
        std.posix.AT.FDCWD,
        path,
        uid,
        @as(std.posix.gid_t, @bitCast(@as(i32, -1))), // gid unchanged (-1)
        0,
    );
    if (ret != 0) {
        const err = std.posix.errno(ret);
        log.warn("Failed to set socket owner for {s}: {s}", .{ path, @tagName(err) });
    }
}

fn setMode(path: [:0]const u8, mode: std.posix.mode_t) void {
    std.posix.fchmodat(std.posix.AT.FDCWD, path, mode, 0) catch |e| {
        log.warn("Failed to set socket mode for {s}: {s}", .{ path, @errorName(e) });
    };
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
    const uid = std.os.linux.getuid();
    const path_raw = try std.fmt.allocPrint(gpa, "/tmp/net-porter-test-perm-{}.sock", .{uid});
    defer gpa.free(path_raw);
    const path = try gpa.dupeZ(u8, path_raw);
    defer gpa.free(path);

    var server = try listen(path, uid);
    defer server.deinit();
    defer std.fs.cwd().deleteFile(path) catch {};

    const stat = try std.posix.fstatat(std.posix.AT.FDCWD, path, 0);
    const mode = stat.mode & 0o777;
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), mode);
}

test "listen and connect round-trip" {
    const gpa = std.testing.allocator;
    const uid = std.os.linux.getuid();
    const path_raw = try std.fmt.allocPrint(gpa, "/tmp/net-porter-test-roundtrip-{}.sock", .{uid});
    defer gpa.free(path_raw);
    const path = try gpa.dupeZ(u8, path_raw);
    defer gpa.free(path);

    var server = try listen(path, uid);
    defer server.deinit();
    defer std.fs.cwd().deleteFile(path) catch {};

    const stream = try connect(path);
    stream.close();
}

test {
    _ = @import("domain_socket_test.zig");
}
