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
pub fn connect(io: std.Io, path: [:0]const u8) !std.Io.net.Stream {
    const address = try std.Io.net.UnixAddress.init(path);
    return address.connect(io);
}

/// Listen on a filesystem unix socket.
/// Creates the socket file, sets ownership to `uid`, and mode to 0600.
pub fn listen(io: std.Io, path: [:0]const u8, uid: std.posix.uid_t) !std.Io.net.Server {
    const address = try std.Io.net.UnixAddress.init(path);

    // Remove stale socket file if it exists.
    // Use direct syscall (not io-layer) to ensure unlink completes
    // synchronously before we call listen — the io layer may buffer
    // operations, causing listen to see the stale file (AddressInUse).
    _ = std.os.linux.unlink(path);

    const server = address.listen(io, .{}) catch |e| {
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
    const rc = std.os.linux.fchmodat(std.posix.AT.FDCWD, path, mode);
    if (rc != 0) {
        log.warn("Failed to set socket mode for {s}", .{path});
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
    const rc = std.os.linux.statx(std.os.linux.AT.FDCWD, path, 0, .{ .MODE = true }, &statx_buf);
    if (rc != 0) return error.Unexpected;
    const mode = statx_buf.mode & 0o777;
    try std.testing.expectEqual(@as(u16, 0o600), mode);
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

test {
    _ = @import("domain_socket_test.zig");
}
