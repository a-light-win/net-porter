const std = @import("std");
const log = std.log.scoped(.server);
const net = std.net;
const fs = std.fs;
const config = @import("../config.zig");
const AclManager = @import("AclManager.zig");
const CniManager = @import("CniManager.zig");
const json = std.json;
const allocator = std.heap.page_allocator;
const Responser = @import("Responser.zig");
const Handler = @import("Handler.zig");
const ArenaAllocator = @import("../ArenaAllocator.zig");
const Server = @This();

config: config.Config,
acl_manager: AclManager,
cni_manager: CniManager,
server: net.Server,

managed_config: config.ManagedConfig,

pub const Opts = struct {
    config_path: ?[]const u8 = null,
    uid: u32 = 0,
};

pub fn new(opts: Opts) !Server {
    var managed_config = config.ManagedConfig.load(
        allocator,
        opts.config_path,
        opts.uid,
    ) catch |e| {
        log.err(
            "Failed to read config file: {s}, error: {s}",
            .{ opts.config_path orelse "", @errorName(e) },
        );
        return e;
    };

    const conf = managed_config.config;
    errdefer managed_config.deinit();

    var server = try conf.domain_socket.listen();
    errdefer server.deinit();

    return Server{
        .config = conf,
        .acl_manager = try AclManager.init(allocator, conf, opts.uid),
        .cni_manager = try CniManager.init(allocator, conf),
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

    self.acl_manager.deinit();
    self.cni_manager.deinit();

    self.managed_config.deinit();
}

pub fn run(self: *Server) !void {
    log.info("Server listening on {s}", .{self.config.domain_socket.path});
    while (true) {
        // Accept a client connection
        var connection = try self.server.accept();

        var handler = Handler{
            .arena = try ArenaAllocator.init(allocator),
            .acl_manager = &self.acl_manager,
            .cni_manager = &self.cni_manager,
            .config = &self.config,
            .connection = connection,
            .responser = Responser{
                .stream = &connection.stream,
                .log_response = true,
            },
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
