const std = @import("std");
const log = std.log.scoped(.server);
const net = std.net;
const fs = std.fs;
const config = @import("../config.zig");
const Runtime = @import("Runtime.zig");
const json = std.json;
const allocator = std.heap.page_allocator;
const Handler = @import("Handler.zig");
const Server = @This();

config: config.Config,
runtime: Runtime,
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

    var runtime = Runtime.newRuntime(allocator, conf);
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

        const arena = allocator.create(std.heap.ArenaAllocator) catch unreachable;
        arena.* = std.heap.ArenaAllocator.init(allocator);
        var handler = Handler{
            .arena = arena,
            .runtime = &self.runtime,
            .config = &self.config,
            .connection = connection,
        };

        // TODO: manage thread lifetime
        _ = std.Thread.spawn(.{}, handleRequests, .{&handler}) catch |e| {
            log.warn(
                "Failed to spawn thread: {s}",
                .{@errorName(e)},
            );
        };
    }
}

fn handleRequests(handler: *Handler) !void {
    defer handler.deinit();
    try handler.handle();
}
