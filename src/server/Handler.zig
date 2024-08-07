const std = @import("std");
const config = @import("../config.zig");
const net = std.net;
const json = std.json;
const log = std.log.scoped(.server);
const plugin = @import("../plugin.zig");
const AclManager = @import("AclManager.zig");
const CniManager = @import("CniManager.zig");
const Handler = @This();

const ClientInfo = extern struct {
    pid: std.posix.pid_t,
    uid: std.posix.uid_t,
    gid: std.posix.gid_t,
};

arena: *std.heap.ArenaAllocator,
config: *config.Config,
acl_manager: *AclManager,
cni_manager: *CniManager,
connection: std.net.Server.Connection,

pub fn deinit(self: *Handler) void {
    self.connection.stream.close();

    const allocator = self.arena.child_allocator;
    self.arena.deinit();
    allocator.destroy(self.arena);
}

pub fn handle(self: *Handler) !void {
    var stream = self.connection.stream;
    const allocator = self.arena.allocator();

    const client_info = try getClientInfo(&stream);
    log.debug(
        "Client connected with PID {d}, UID {d}, GID {d}",
        .{ client_info.pid, client_info.uid, client_info.gid },
    );

    const buf = stream.reader().readAllAlloc(
        allocator,
        plugin.max_request_size,
    ) catch |err| {
        writeError(&stream, "Failed to read request: {s}", .{@errorName(err)});
        return;
    };

    const parsed_request = json.parseFromSlice(
        plugin.Request,
        allocator,
        buf,
        .{},
    ) catch |err| {
        writeError(&stream, "Failed to parse request: {s}", .{@errorName(err)});
        return;
    };
    defer parsed_request.deinit();
    const request = parsed_request.value;

    try self.authClient(client_info, &request);

    switch (request.action) {
        .create => try self.handleCreate(request),
        // TODO: implement other actions
        else => {},
    }
}

fn handleCreate(self: *Handler, request: plugin.Request) !void {
    // TODO
    // load cni by resource name, return error if the file does not exist
    //
    const cni = self.cni_manager.loadCni(request.resource) catch |err| {
        writeError(&self.connection.stream, "Failed to load CNI: {s}", .{@errorName(err)});
        return;
    };

    // TODO: save cni and send back the request
    _ = cni;

    self.connection.stream.writeAll(request.request) catch |err| {
        writeError(
            &self.connection.stream,
            "Failed to send response of create action: {s}",
            .{
                @errorName(err),
            },
        );
    };
}

fn writeResponse(stream: *net.Stream, response: anytype) void {
    json.stringify(
        response,
        .{ .whitespace = .indent_2 },
        stream.writer(),
    ) catch |err| {
        writeError(stream, "Failed to format response: {s}", .{@errorName(err)});
        return;
    };
}

fn writeError(stream: *net.Stream, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;

    const error_msg = std.fmt.bufPrint(&buf, fmt, args) catch |err| {
        log.warn("Failed to format error message: {s}", .{@errorName(err)});
        return;
    };

    log.warn("{s}", .{error_msg});

    json.stringify(
        .{ .@"error" = error_msg },
        .{ .whitespace = .indent_2 },
        stream.writer(),
    ) catch |err| {
        log.warn("Failed to send error message: {s}", .{@errorName(err)});
    };
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
    if (!self.acl_manager.isAllowed(request.resource, client_info.uid, client_info.gid)) {
        const err = error.AccessDenied;
        writeError(
            &self.connection.stream,
            "Failed to access resource '{s}', error: {s}",
            .{
                request.resource,
                @errorName(err),
            },
        );
        return err;
    }
}
