const std = @import("std");
const DomainSocket = @import("DomainSocket.zig");

test "pathForUid returns correct path" {
    const gpa = std.testing.allocator;
    const path = try DomainSocket.pathForUid(gpa, 1000);
    defer gpa.free(path);
    try std.testing.expect(std.mem.eql(u8, path, "/run/user/1000/net-porter.sock"));
}

test "pathForUid with different uid" {
    const gpa = std.testing.allocator;
    const path = try DomainSocket.pathForUid(gpa, 0);
    defer gpa.free(path);
    try std.testing.expect(std.mem.eql(u8, path, "/run/user/0/net-porter.sock"));
}

test "connect fails for non-existent socket" {
    const result = DomainSocket.connect("/tmp/net-porter-test-not-exists.sock");
    try std.testing.expectError(error.FileNotFound, result);
}
