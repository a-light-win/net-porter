const std = @import("std");
const config = @import("../config.zig");
const net = std.net;
const json = std.json;
const log = std.log.scoped(.server);
const plugin = @import("../plugin.zig");
const Handler = @This();

const ClientInfo = extern struct {
    pid: std.posix.pid_t,
    uid: std.posix.uid_t,
    gid: std.posix.gid_t,
};

allocator: std.mem.Allocator,
config: *config.Config,
runtime: *config.Runtime,
connection: std.net.Server.Connection,

pub fn deinit(self: *Handler) void {
    self.connection.stream.close();
}

pub fn handle(self: *Handler) !void {
    var stream = self.connection.stream;

    const client_info = try getClientInfo(&stream);
    log.debug(
        "Client connected with PID {d}, UID {d}, GID {d}",
        .{ client_info.pid, client_info.uid, client_info.gid },
    );

    const buf = stream.reader().readAllAlloc(
        self.allocator,
        plugin.max_request_size,
    ) catch |err| {
        writeError(&stream, "Failed to read request: {s}", .{@errorName(err)});
        return;
    };
    defer self.allocator.free(buf);

    const parsed_request = json.parseFromSlice(
        plugin.Request,
        self.allocator,
        buf,
        .{},
    ) catch |err| {
        writeError(&stream, "Failed to parse request: {s}", .{@errorName(err)});
        return;
    };
    defer parsed_request.deinit();

    try self.authClient(client_info, &parsed_request.value);

    // TODO: Handle the client in a separate function
    //const value = try json.parse(self.allocator, buf);
    //const result = value;
    //json.stringify(result, stream.writer()) catch |e| {
    //    log.warn("Failed to send response: {s}", .{@errorName(e)});
    //};
}

fn writeError(stream: *net.Stream, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;

    const error_msg = std.fmt.bufPrint(&buf, fmt, args) catch |err| {
        log.warn("Failed to format error message: {s}", .{@errorName(err)});
        return;
    };

    json.stringify(
        .{ .@"error" = error_msg },
        .{ .whitespace = .indent_2 },
        stream.writer(),
    ) catch |err| {
        log.warn("Failed to send error message: {s}", .{@errorName(err)});
    };

    log.warn("{s}", .{error_msg});
}

fn getClientInfo(stream: *net.Stream) std.posix.UnexpectedError!ClientInfo {
    // Get peer credentials
    var client_info: ClientInfo = undefined;
    var info_len: std.posix.socklen_t = @sizeOf(ClientInfo);
    const fd = stream.handle;
    const res = std.posix.system.getsockopt(
        fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.PEERCRED,
        @ptrCast(&client_info),
        &info_len,
    );
    if (res != 0) {
        writeError(stream, "Failed to get connection info: {d}", .{res});

        const json_err = std.posix.errno(res);
        log.warn("Failed to send error message: {s}", .{@tagName(json_err)});
        return std.posix.unexpectedErrno(json_err);
    }
    return client_info;
}

fn authClient(self: *Handler, client_info: ClientInfo, request: *const plugin.Request) !void {
    // TODO: Implement authentication
    _ = self;
    _ = client_info;
    _ = request;
}
