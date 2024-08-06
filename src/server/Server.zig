const std = @import("std");
const log = std.log.scoped(.server);
const net = std.net;
const fs = std.fs;
const config = @import("../config.zig");
const json = @import("../json.zig");
const network = @import("../network.zig");
const allocator = std.heap.page_allocator;
const Server = @This();

config: config.Config,
runtime: config.Runtime,
server: net.Server,

managed_config: config.ManagedConfig,

pub fn new(config_path: ?[]const u8) !Server {
    var managed_config = config.ManagedConfig.load(
        allocator,
        config_path,
    ) catch |e| {
        log.err(
            "Failed to read config file: {s}, error: {s}",
            .{ config_path orelse "", @errorName(e) },
        );
        return e;
    };

    const conf = managed_config.config;
    errdefer managed_config.deinit();

    var runtime = config.Runtime{};
    runtime.init(allocator, conf);
    errdefer runtime.deinit();

    const server = try conf.domain_socket.listen();
    errdefer server.deinit();

    return Server{
        .config = conf,
        .runtime = runtime,
        .server = server,
        .managed_config = managed_config,
    };
}

pub fn deinit(self: *Server) void {
    log.info("Server shutting down...", .{});
    // Clean up the socket file
    fs.cwd().deleteFile(self.config.domain_socket.path) catch |e| {
        if (e == error.FileNotFound) {
            return;
        }
        log.warn(
            "Failed to delete socket file: {s}, error: {s}",
            .{ self.config.domain_socket.path, @errorName(e) },
        );
    };

    self.server.deinit();

    self.runtime.deinit();

    self.managed_config.deinit();
}

pub fn run(self: *Server) !void {
    log.info("Server listening on {s}", .{self.config.domain_socket.path});
    while (true) {
        // Accept a client connection
        const connection = try self.server.accept();
        _ = std.Thread.spawn(.{}, handleRequests, .{connection}) catch |e| {
            log.warn(
                "Failed to spawn thread: {s}",
                .{@errorName(e)},
            );
        };
    }
}

const ClientInfo = extern struct {
    pid: std.posix.pid_t,
    uid: std.posix.uid_t,
    gid: std.posix.gid_t,
};

fn handleRequests(connection: net.Server.Connection) !void {
    defer connection.stream.close();
    const stream = connection.stream;

    const client_info = try getClientInfo(stream);

    log.debug(
        "Client connected with PID {d}, UID {d}, GID {d}",
        .{ client_info.pid, client_info.uid, client_info.gid },
    );
    try authClient(stream, client_info);

    const buf = try stream.reader().readAllAlloc(allocator, json.max_json_size);
    defer allocator.free(buf);

    const value = try json.parse(allocator, buf);

    // TODO: Handle the client in a separate function
    const result = value;
    json.stringify(result, stream.writer()) catch |e| {
        log.warn("Failed to send response: {s}", .{@errorName(e)});
    };
}

fn getClientInfo(stream: net.Stream) std.posix.UnexpectedError!ClientInfo {
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
        const error_msg = network.formatErrorMessage("Failed to get connection info: {d}", .{res});
        json.stringify(error_msg, stream.writer()) catch {};

        const json_err = std.posix.errno(res);
        log.warn("Failed to send error message: {s}", .{@tagName(json_err)});
        return std.posix.unexpectedErrno(json_err);
    }
    return client_info;
}

fn authClient(stream: net.Stream, client_info: ClientInfo) !void {
    // TODO: Implement authentication
    _ = stream;
    _ = client_info;
}
