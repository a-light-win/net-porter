const std = @import("std");
const DomainSocket = @import("DomainSocket.zig");

test "postInit sets path and uid correctly" {
    const gpa = std.testing.allocator;
    var ds = DomainSocket{
        .path = "",
        .owner = null,
        .uid = null,
    };

    try ds.postInit(gpa, 1000);
    defer gpa.free(ds.path);

    try std.testing.expect(std.mem.eql(u8, ds.path, "/run/user/1000/net-porter.sock"));
    try std.testing.expect(ds.uid == 1000);
}

test "postInit does not change path if already set" {
    const gpa = std.testing.allocator;

    var ds = DomainSocket{
        .path = "/custom/path.sock",
        .owner = null,
        .uid = null,
    };

    try ds.postInit(gpa, 1000);

    try std.testing.expect(std.mem.eql(u8, ds.path, "/custom/path.sock"));
    try std.testing.expect(ds.uid == 1000);
}

test "postInit does not change uid if already set" {
    const gpa = std.testing.allocator;
    var ds = DomainSocket{
        .path = "/custom/path.sock",
        .owner = null,
        .uid = 2000,
    };

    try ds.postInit(gpa, 1000);

    try std.testing.expect(ds.uid == 2000);
}

test "postInit does not change uid if owner is already set" {
    const gpa = std.testing.allocator;
    var ds = DomainSocket{
        .path = "/custom/path.sock",
        .owner = "root",
        .uid = null,
    };
    try ds.postInit(gpa, 1000);
    try std.testing.expect(ds.uid == null);
}

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
