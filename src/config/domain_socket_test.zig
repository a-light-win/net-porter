const std = @import("std");
const DomainSocket = @import("DomainSocket.zig");

test "connect() will failed if the socket path not exists" {
    const socket = DomainSocket{ .path = "/tmp/this-socket-not-exists" };
    _ = socket.connect() catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    };
}

fn serve(socket: DomainSocket) !void {
    var server = try socket.listen();
    defer server.deinit();
    defer std.fs.cwd().deleteFile(socket.path) catch {};

    const conn = try server.accept();
    defer conn.stream.close();
}

test "connect() will success if the socket path exists" {
    const socket = DomainSocket{ .path = "/tmp/test-DomainSocket-connect.sock" };

    const thread = try std.Thread.spawn(.{}, serve, .{socket});
    thread.detach();

    const conn = try socket.connect();
    try std.testing.expectEqual(std.net.Stream, @TypeOf(conn));
    conn.close();
}
