const std = @import("std");
const log = std.log.scoped(.domain_socket);
const DomainSocket = @This();

/// Maximum length of a unix socket path (Linux UNIX_PATH_MAX).
/// Abstract socket names can use at most `unix_path_max - 1` bytes
/// (one byte is consumed by the leading null byte).
const unix_path_max = 108;

/// Abstract unix socket path (with '@' prefix).
/// The '@' prefix is the conventional human-readable representation of the null byte
/// that distinguishes abstract sockets from filesystem sockets in Linux.
/// At runtime, the '@' is replaced with '\0' before passing to the kernel.
path: [:0]const u8 = "",

pub fn postInit(self: *DomainSocket, allocator: std.mem.Allocator) !void {
    if (self.path.len == 0) {
        self.path = try allocator.dupeZ(u8, "@net-porter");
    }

    if (!self.isAbstract()) {
        log.warn(
            \\Socket path '{s}' does not use abstract socket ('@' prefix).
            \\Filesystem unix sockets are not supported because rootless podman
            \\runs in an isolated mount namespace where the socket file is invisible.
            \\Please use an abstract socket path like '@net-porter'.
        , .{self.path});
        return error.UnsupportedSocketType;
    }
}

pub fn isAbstract(self: DomainSocket) bool {
    return self.path.len > 0 and self.path[0] == '@';
}

/// Build the kernel-level abstract socket address.
/// Replaces the '@' prefix with '\0' and constructs a `sockaddr.un` struct.
fn initAddress(self: DomainSocket) !std.net.Address {
    const path = self.path;
    // +1 to ensure a terminating 0 is present for maximum portability
    if (path.len + 1 > unix_path_max) return error.NameTooLong;

    var sock_addr: std.posix.sockaddr.un = .{
        .family = std.posix.AF.UNIX,
        .path = undefined,
    };
    @memset(&sock_addr.path, 0);
    @memcpy(sock_addr.path[0..path.len], path);
    // Replace '@' with '\0' to form an abstract socket address
    sock_addr.path[0] = 0;

    return .{ .un = sock_addr };
}

pub fn connect(self: DomainSocket) !std.net.Stream {
    const addr = try self.initAddress();

    const sockfd = try std.posix.socket(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        0,
    );
    errdefer std.net.Stream.close(.{ .handle = sockfd });

    try std.posix.connect(sockfd, &addr.any, addr.getOsSockLen());

    return .{ .handle = sockfd };
}

pub fn listen(self: DomainSocket) !std.net.Server {
    const addr = try self.initAddress();

    const server = addr.listen(.{}) catch |e| {
        log.err(
            "Failed to listen on abstract socket {s}: {s}",
            .{ self.path, @errorName(e) },
        );
        return e;
    };

    return server;
}

test "postInit sets default path to @net-porter" {
    const gpa = std.testing.allocator;
    var ds = DomainSocket{ .path = "" };
    try ds.postInit(gpa);
    defer gpa.free(ds.path);

    try std.testing.expect(std.mem.eql(u8, ds.path, "@net-porter"));
    try std.testing.expect(ds.isAbstract());
}

test "postInit does not change path if already set" {
    const gpa = std.testing.allocator;
    var ds = DomainSocket{ .path = "@custom" };
    try ds.postInit(gpa);

    try std.testing.expect(std.mem.eql(u8, ds.path, "@custom"));
}

test "postInit rejects filesystem socket path" {
    const gpa = std.testing.allocator;
    var ds = DomainSocket{ .path = "/run/test.sock" };
    const result = ds.postInit(gpa);
    try std.testing.expectError(error.UnsupportedSocketType, result);
}

test "isAbstract returns true for '@' prefix" {
    const ds = DomainSocket{ .path = "@net-porter" };
    try std.testing.expect(ds.isAbstract());
}

test "isAbstract returns false for filesystem path" {
    const ds = DomainSocket{ .path = "/run/net-porter.sock" };
    try std.testing.expect(!ds.isAbstract());
}

test "isAbstract returns false for empty path" {
    const ds = DomainSocket{ .path = "" };
    try std.testing.expect(!ds.isAbstract());
}

test "listen and connect with abstract socket" {
    const socket = DomainSocket{ .path = "@test-net-porter-listen-connect" };

    var server = try socket.listen();
    defer server.deinit();
    // No file cleanup needed for abstract sockets

    const stream = try socket.connect();
    stream.close();
}

test "connect() will fail if the abstract socket does not exist" {
    const socket = DomainSocket{ .path = "@this-socket-not-exists" };
    _ = socket.connect() catch |err| {
        // Abstract socket returns ConnectionRefused or similar when not listening
        try std.testing.expect(err == error.ConnectionRefused or err == error.FileNotFound);
    };
}

test {
    _ = @import("domain_socket_test.zig");
}
