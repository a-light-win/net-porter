const std = @import("std");
const log = std.log.scoped(.server);
const net = std.net;
const fs = std.fs;
const config_mod = @import("../config.zig");
const AclManager = @import("AclManager.zig");
const CniManager = @import("../cni/CniManager.zig");
const DhcpService = @import("../cni/DhcpService.zig");
const json = std.json;
const allocator = std.heap.page_allocator;
const Responser = @import("../plugin/Responser.zig");
const Handler = @import("Handler.zig");
const ArenaAllocator = @import("../utils/ArenaAllocator.zig");
const Server = @This();

config: config_mod.Config,
acl_manager: AclManager,
cni_manager: CniManager,
dhcp_service: DhcpService,
server: net.Server,

managed_config: config_mod.ManagedConfig,

pub const Opts = struct {
    config_path: ?[]const u8 = null,
    uid: u32 = 0,
};

pub fn new(opts: Opts) !Server {
    var managed_config = config_mod.ManagedConfig.load(
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

    var logger = @import("root").logger;
    logger.log_settings = conf.log;

    var server = try conf.domain_socket.listen();
    errdefer server.deinit();

    return Server{
        .config = conf,
        .acl_manager = try AclManager.init(allocator, conf, opts.uid),
        .cni_manager = try CniManager.init(allocator, conf),
        .dhcp_service = try DhcpService.init(allocator, opts.uid, conf.cni_plugin_dir),
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
    self.dhcp_service.deinit();

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
            .dhcp_service = &self.dhcp_service,
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
