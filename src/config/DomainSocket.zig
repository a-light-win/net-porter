const std = @import("std");
const user = @import("../user.zig");
const DomainSocket = @This();

path: []const u8 = "/run/net-porter.sock",
owner: ?[]const u8 = null,
group: ?[]const u8 = null,
uid: ?std.posix.uid_t = null,
gid: ?std.posix.gid_t = null,
mode: std.posix.mode_t = 0o660,

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

    self.setSocketPermissions(server.stream.handle) catch {};

    return server;
}

fn setSocketPermissions(self: DomainSocket, handle: std.posix.socket_t) !void {
    const uid = self.getUid();
    const gid = self.getGid();
    if (uid != null or gid != null) {
        std.posix.fchown(handle, uid, gid) catch |e| {
            std.log.warn(
                "Failed to set socket owner: file: {s}, error: {s}",
                .{ self.path, @errorName(e) },
            );
            return e;
        };
    }

    std.posix.fchmod(handle, self.mode) catch |e| {
        std.log.warn(
            "Failed to set socket permissions: file: {s}, error: {s}",
            .{ self.path, @errorName(e) },
        );
        return e;
    };
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

    try socket.setSocketPermissions(server.stream.handle);
    const stat = try std.posix.fstat(server.stream.handle);
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
        return error.skip;
    }

    const address = try std.net.Address.initUnix(socket.path);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();
    defer std.fs.cwd().deleteFile(socket.path) catch {};

    socket.setSocketPermissions(server.stream.handle) catch |e| {
        try std.testing.expectEqual(error.AccessDenied, e);
    };
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
