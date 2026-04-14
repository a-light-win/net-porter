const std = @import("std");
const DomainSocket = @import("DomainSocket.zig");

test "postInit sets path correctly" {
    const gpa = std.testing.allocator;
    var ds = DomainSocket{
        .path = "",
    };

    try ds.postInit(gpa);
    defer gpa.free(ds.path);

    try std.testing.expect(std.mem.eql(u8, ds.path, "@net-porter"));
}

test "postInit does not change path if already set" {
    const gpa = std.testing.allocator;

    var ds = DomainSocket{
        .path = "@custom",
    };

    try ds.postInit(gpa);

    try std.testing.expect(std.mem.eql(u8, ds.path, "@custom"));
}

test "postInit rejects filesystem path" {
    const gpa = std.testing.allocator;
    var ds = DomainSocket{
        .path = "/run/test.sock",
    };

    const result = ds.postInit(gpa);
    try std.testing.expectError(error.UnsupportedSocketType, result);
}

test "connect() will fail if the socket does not exist" {
    const socket = DomainSocket{ .path = "@this-socket-not-exists" };
    _ = socket.connect() catch |err| {
        try std.testing.expect(err == error.ConnectionRefused or err == error.FileNotFound);
    };
}
