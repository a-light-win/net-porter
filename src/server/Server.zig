const std = @import("std");
const log = std.log.scoped(.server);
const config_mod = @import("../config.zig");
const version = @import("build_options").version;
const AclManager = @import("AclManager.zig");
const CniManager = @import("../cni/CniManager.zig");
const DhcpManager = @import("../cni/DhcpManager.zig");
const StateFile = @import("../cni/StateFile.zig");
const Handler = @import("Handler.zig");
const ArenaAllocator = @import("../utils/ArenaAllocator.zig");
const SocketManager = @import("SocketManager.zig");
const Responser = @import("../plugin/Responser.zig");
const Server = @This();

const max_concurrent_handlers: usize = 64;

config: config_mod.Config,
io: std.Io,
acl_manager: AclManager,
cni_manager: CniManager,
dhcp_manager: DhcpManager,
socket_manager: SocketManager,
managed_config: config_mod.ManagedConfig,
active_handlers: std.atomic.Value(usize) = .init(0),

pub const Opts = struct {
    config_path: ?[]const u8 = null,
    io: ?std.Io = null,
};

pub fn new(opts: Opts) !Server {
    const io = opts.io orelse return error.IoNotInitialized;
    const allocator = std.heap.page_allocator;

    var managed_config = config_mod.ManagedConfig.load(
        io,
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

    // Ensure state directory exists with correct permissions
    StateFile.ensureBaseDir(io) catch |err| {
        log.err("Failed to create state directory: {s}", .{@errorName(err)});
        return err;
    };

    // Initialize AclManager and load ACL files from directory
    var acl_manager = AclManager.init(allocator, conf.acl_dir);
    errdefer acl_manager.deinit();
    acl_manager.startWatching(io);

    // Derive allowed UIDs from ACL data
    const allowed_uids = acl_manager.getAllowedUids(io, allocator);

    var socket_manager = try SocketManager.init(io, allocator, allowed_uids);

    // Insert ACL inotify fd into socket_manager's poll set (at index 1)
    if (acl_manager.acl_inotify_fd) |acl_fd| {
        try socket_manager.poll_fds.insert(socket_manager.allocator, 1, .{
            .fd = acl_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        });
        socket_manager.num_special_fds = 2;
    }

    socket_manager.scanExisting(io);

    return Server{
        .config = conf,
        .io = io,
        .acl_manager = acl_manager,
        .cni_manager = try CniManager.init(io, allocator, conf),
        .dhcp_manager = DhcpManager.init(io, allocator, conf.cni_plugin_dir),
        .socket_manager = socket_manager,
        .managed_config = managed_config,
    };
}

pub fn deinit(self: *Server) void {
    log.info("Server shutting down...", .{});
    self.socket_manager.deinit();
    self.acl_manager.deinit();
    self.cni_manager.deinit();
    self.dhcp_manager.deinit();
    self.managed_config.deinit();
}

pub fn run(self: *Server) !void {
    const io = self.io;
    log.info("net-porter {s} started, monitoring /run/user/ and ACL directory", .{version});
    const log_response = self.config.log.logEnabled(.debug, .traffic);

    var event_buf: [4096]u8 = undefined;

    while (true) {
        const poll_index = self.socket_manager.poll(-1) catch |err| {
            log.err("poll failed: {s}", .{@errorName(err)});
            return err;
        };

        const idx = poll_index orelse continue;

        if (idx == 0) {
            // inotify event on /run/user/
            self.socket_manager.processInotifyEvents(&event_buf);
            continue;
        }

        if (idx == 1 and self.acl_manager.acl_inotify_fd != null) {
            // inotify event on acl_dir
            const changed = self.acl_manager.processInotifyEvents(&event_buf);
            if (changed) {
                self.acl_manager.reload(io);
                const new_uids = self.acl_manager.getAllowedUids(io, std.heap.page_allocator);
                self.socket_manager.updateAllowedUids(new_uids);
            }
            continue;
        }

        // Server socket event — accept connection
        var conn = self.socket_manager.accept(io, idx) orelse continue;

        // Limit concurrent handlers to prevent resource exhaustion
        if (self.active_handlers.fetchAdd(1, .acquire) >= max_concurrent_handlers) {
            _ = self.active_handlers.fetchSub(1, .release);
            log.warn("Too many concurrent connections (max={d}), dropping", .{max_concurrent_handlers});
            conn.stream.close(io);
            continue;
        }

        var handler = Handler{
            .io = io,
            .arena = try ArenaAllocator.init(std.heap.page_allocator),
            .acl_manager = &self.acl_manager,
            .cni_manager = &self.cni_manager,
            .dhcp_manager = &self.dhcp_manager,
            .config = &self.config,
            .connection = conn,
            .responser = Responser{
                .io = io,
                .stream = &conn.stream,
                .log_response = log_response,
            },
        };

        _ = std.Thread.spawn(.{}, handleRequests, .{ &handler, &self.active_handlers }) catch |e| {
            _ = self.active_handlers.fetchSub(1, .release);
            log.warn("Failed to spawn thread: {s}", .{@errorName(e)});
        };
    }
}

fn handleRequests(handler: *Handler, active_handlers: *std.atomic.Value(usize)) !void {
    defer {
        handler.deinit();
        _ = active_handlers.fetchSub(1, .release);
    }
    try handler.handle();
}
