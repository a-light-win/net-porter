const std = @import("std");
const user = @import("../user.zig");
const c = @cImport({
    @cInclude("unistd.h");
});

const DomainSocket = @This();

path: [:0]const u8 = "",
owner: ?[:0]const u8 = null,
group: ?[:0]const u8 = null,
uid: ?std.posix.uid_t = null,
gid: ?std.posix.gid_t = null,
mode: std.posix.mode_t = 0o660,

pub fn postInit(self: *DomainSocket, allocator: std.mem.Allocator, accepted_uid: std.posix.uid_t) !void {
    if (std.mem.eql(u8, self.path, "")) {
        self.path = try std.fmt.allocPrintZ(
            allocator,
            "/run/user/{d}/net-porter.sock",
            .{accepted_uid},
        );
    }
    if (self.owner == null and self.uid == null) {
        self.uid = accepted_uid;
    }
}

pub fn connect(self: DomainSocket) !std.net.Stream {
    return try std.net.connectUnixSocket(self.path);
}

pub fn listen(self: DomainSocket) !std.net.Server {
    const address = std.net.Address.initUnix(self.path) catch |e| {
        std.log.err(
            "Failed to create address: {s}, error: {s}",
            .{ self.path, @errorName(e) },
        );
        return e;
    };

    // Bind the socket to a file path
    std.fs.cwd().deleteFile(self.path) catch {};
    const server = address.listen(.{ .reuse_address = true }) catch |e| {
        std.log.err(
            "Failed to bind address: {s}, error: {s}",
            .{ self.path, @errorName(e) },
        );
        return e;
    };

    self.setSocketPermissions();

    return server;
}

test "listen() should change the mode of socket to 660" {
    const socket = DomainSocket{
        .path = "/tmp/test-listen.sock",
    };

    var server = try socket.listen();
    defer server.deinit();
    defer std.fs.cwd().deleteFile(socket.path) catch {};

    var stat: std.os.linux.Statx = undefined;

    // Call the statx function to get file metadata
    _ = std.os.linux.statx(std.posix.AT.FDCWD, // dirfd (use current directory)
        socket.path, // path to the socket
        0, // flags (0 for default)
        std.os.linux.STATX_BASIC_STATS, // what (basic stats)
        &stat // where to store the result
    );
    const mode = stat.mode & 0o777;
    std.debug.print("path: {s}, mode: {o}, stat.mode: {o}\n", .{ socket.path, mode, stat.mode });
    try std.testing.expectEqual(socket.mode, mode);
}

fn setSocketPermissions(self: DomainSocket) void {
    const uid = self.getUid();
    const gid = self.getGid();
    if (uid != null or gid != null) {
        setOwner(self.path, uid, gid);
    }

    std.posix.fchmodat(std.posix.AT.FDCWD, self.path, self.mode, 0) catch |e| {
        std.log.warn(
            "Failed to set socket permissions: file: {s}, error: {s}",
            .{ self.path, @errorName(e) },
        );
    };
}

fn setOwner(path: [:0]const u8, uid: ?std.posix.uid_t, gid: ?std.posix.gid_t) void {
    const stat = std.posix.fstatat(std.posix.AT.FDCWD, path, 0) catch |e| {
        std.log.warn(
            "Failed to get socket owner: file: {s}, error: {s}",
            .{ path, @errorName(e) },
        );
        return;
    };

    const ret_chown = c.fchownat(
        std.posix.AT.FDCWD,
        path,
        uid orelse stat.uid,
        gid orelse stat.gid,
        0,
    );

    if (ret_chown != 0) {
        const err = std.posix.errno(ret_chown);
        std.log.warn(
            "Failed to set socket owner: file: {s}, error: {d}",
            .{ path, @tagName(err) },
        );
    }
}

test "setSocketPermissions()" {
    const socket = DomainSocket{
        .path = "/tmp/test-setSocketPermissions.sock",
        .uid = std.os.linux.getuid(),
        .gid = std.os.linux.getgid(),
    };

    const address = try std.net.Address.initUnix(socket.path);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();
    defer std.fs.cwd().deleteFile(socket.path) catch {};

    socket.setSocketPermissions();
    const stat = try std.posix.fstatat(std.posix.AT.FDCWD, socket.path, 0);
    const mode = stat.mode & 0o777;
    try std.testing.expectEqual(socket.mode, mode);
}

test "setSocketPermissions() will failed if the user can not change the owner" {
    const socket = DomainSocket{
        .path = "/tmp/test-setSocketPermissions.sock",
        .owner = "root",
        .group = "root",
    };

    if (std.os.linux.getuid() == 0) {
        return error.SkipZigTest;
    }

    const address = try std.net.Address.initUnix(socket.path);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();
    defer std.fs.cwd().deleteFile(socket.path) catch {};

    socket.setSocketPermissions();
}

fn getUid(self: DomainSocket) ?std.posix.uid_t {
    return self.uid orelse {
        if (self.owner) |value| {
            return user.getUid(value);
        }
        return null;
    };
}

test "getUid() will return null if both owner and uid are not set" {
    const socket = DomainSocket{};
    try std.testing.expectEqual(null, socket.getUid());
}

test "getUid() will return the uid of the owner if only the owner is set" {
    const socket = DomainSocket{ .owner = "root" };
    try std.testing.expectEqual(0, socket.getUid().?);
}

test "getUid() will return uid if it is set" {
    const socket = DomainSocket{ .uid = 1000 };
    try std.testing.expectEqual(1000, socket.getUid().?);
}

test "getUid() will prefer uid over owner" {
    const socket = DomainSocket{ .owner = "root", .uid = 1000 };
    try std.testing.expectEqual(1000, socket.getUid().?);
}

fn getGid(self: DomainSocket) ?std.posix.gid_t {
    return self.gid orelse {
        if (self.group) |value| {
            return user.getGid(value);
        }
        return null;
    };
}

test "getGid() will return null if both group and gid are not set" {
    const socket = DomainSocket{};
    try std.testing.expectEqual(null, socket.getGid());
}

test "getGid() will return the gid of the group if only the group is set" {
    const socket = DomainSocket{ .group = "root" };
    try std.testing.expectEqual(0, socket.getGid().?);
}

test "getGid() will return gid if it is set" {
    const socket = DomainSocket{ .gid = 1000 };
    try std.testing.expectEqual(1000, socket.getGid().?);
}

test "getGid() will prefer gid over group" {
    const socket = DomainSocket{ .group = "root", .gid = 1000 };
    try std.testing.expectEqual(1000, socket.getGid().?);
}

test {
    _ = @import("domain_socket_test.zig");
}
