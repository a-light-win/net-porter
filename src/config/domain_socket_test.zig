const std = @import("std");
const DomainSocket = @import("DomainSocket.zig");

test "connect() will failed if the socket path not exists" {
    const socket = DomainSocket{ .path = "/tmp/this-socket-not-exists" };
    _ = socket.connect() catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    };
}

const Server = struct {
    socket: DomainSocket = DomainSocket{
        .path = "/tmp/test-DomainSocket-connect.sock",
    },

    server: std.net.Server,

    fn serve(self: *Server) !void {
        defer self.deinit();

        const conn = try self.server.accept();
        defer conn.stream.close();
    }

    fn deinit(self: *Server) void {
        self.server.deinit();
        std.fs.cwd().deleteFile(self.socket.path) catch {};
    }
};

test "connect() will success if the socket path exists" {
    const socket = DomainSocket{
        .path = "/tmp/test-DomainSocket-connect.sock",
    };
    const s = try socket.listen();
    var server = Server{ .socket = socket, .server = s };

    const thread = try std.Thread.spawn(.{}, Server.serve, .{&server});

    const conn = try server.socket.connect();
    try std.testing.expectEqual(std.net.Stream, @TypeOf(conn));
    conn.close();

    thread.join();
}
