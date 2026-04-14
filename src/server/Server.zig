const std = @import("std");
const log = std.log.scoped(.server);
const net = std.net;
const config_mod = @import("../config.zig");
const AclManager = @import("AclManager.zig");
const CniManager = @import("../cni/CniManager.zig");
const DhcpManager = @import("../cni/DhcpManager.zig");
const json = std.json;
const allocator = std.heap.page_allocator;
const Responser = @import("../plugin/Responser.zig");
const Handler = @import("Handler.zig");
const ArenaAllocator = @import("../utils/ArenaAllocator.zig");
const Server = @This();

config: config_mod.Config,
acl_manager: AclManager,
cni_manager: CniManager,
dhcp_manager: DhcpManager,
server: net.Server,

managed_config: config_mod.ManagedConfig,

pub const Opts = struct {
    config_path: ?[]const u8 = null,
};

pub fn new(opts: Opts) !Server {
    var managed_config = config_mod.ManagedConfig.load(
        allocator,
        opts.config_path,
    ) catch |e| {
        log.err(
            "Failed to read config file: {s}, error: {s}",
            .{ opts.config_path orelse "", @errorName(e) },
        );
        return e;
    };

    const conf = managed_config.config;
    errdefer managed_config.deinit();

    var logger = @import("root").logger;
    logger.log_settings = conf.log;

    var server = try conf.domain_socket.listen();
    errdefer server.deinit();

    return Server{
        .config = conf,
        .acl_manager = try AclManager.init(allocator, conf),
        .cni_manager = try CniManager.init(allocator, conf),
        .dhcp_manager = DhcpManager.init(allocator, conf.cni_plugin_dir),
        .server = server,
        .managed_config = managed_config,
    };
}

pub fn deinit(self: *Server) void {
    log.info("Server shutting down...", .{});
    // Abstract sockets are automatically cleaned up when the socket fd is closed,
    // no filesystem cleanup needed.

    self.server.deinit();

    self.acl_manager.deinit();
    self.cni_manager.deinit();
    self.dhcp_manager.deinit();

    self.managed_config.deinit();
}

pub fn run(self: *Server) !void {
    log.info("Server listening on {s}", .{self.config.domain_socket.path});
    const log_response = self.config.log.logEnabled(.debug, .traffic);

    while (true) {
        // Accept a client connection
        var connection = try self.server.accept();

        var handler = Handler{
            .arena = try ArenaAllocator.init(allocator),
            .acl_manager = &self.acl_manager,
            .cni_manager = &self.cni_manager,
            .dhcp_manager = &self.dhcp_manager,
            .config = &self.config,
            .connection = connection,
            .responser = Responser{
                .stream = &connection.stream,
                .log_response = log_response,
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
