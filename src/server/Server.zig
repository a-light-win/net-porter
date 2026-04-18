const std = @import("std");
const log = std.log.scoped(.server);
const config_mod = @import("../config.zig");
const version = @import("build_options").version;
const AclManager = @import("AclManager.zig");
const WorkerManager = @import("../worker/WorkerManager.zig");
const SocketManager = @import("SocketManager.zig");
const Server = @This();

config: config_mod.Config,
io: std.Io,
acl_manager: AclManager,
worker_manager: WorkerManager,
socket_manager: SocketManager,
managed_config: config_mod.ManagedConfig,

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

    // Scan ACL directory for allowed UIDs (username → UID resolution)
    var acl_manager = AclManager.init(allocator, conf.acl_dir);
    errdefer acl_manager.deinit();

    const allowed_uids = acl_manager.scanUids(io);
    log.info("ACL scan: {} allowed UIDs", .{allowed_uids.items.len});

    var socket_manager = try SocketManager.init(io, allocator, allowed_uids);

    socket_manager.scanExisting(io);

    // Initialize worker manager for per-UID worker processes
    const worker_manager = WorkerManager.init(io, allocator, opts.config_path);

    return Server{
        .config = conf,
        .io = io,
        .acl_manager = acl_manager,
        .worker_manager = worker_manager,
        .socket_manager = socket_manager,
        .managed_config = managed_config,
    };
}

pub fn deinit(self: *Server) void {
    log.info("Server shutting down...", .{});
    self.worker_manager.deinit();
    self.socket_manager.deinit();
    self.acl_manager.deinit();
    self.managed_config.deinit();
}

pub fn run(self: *Server) !void {
    log.info("net-porter {s} started, monitoring /run/user/", .{version});

    // Start workers for UIDs that already exist at startup
    self.syncWorkers();

    var event_buf: [4096]u8 = undefined;

    while (true) {
        const poll_index = self.socket_manager.poll(-1) catch |err| {
            log.err("poll failed: {s}", .{@errorName(err)});
            return err;
        };

        const idx = poll_index orelse continue;

        if (idx == 0) {
            // inotify event on /run/user/
            var uid_events = self.socket_manager.processInotifyEvents(&event_buf);
            // Start workers for newly appeared UIDs
            for (uid_events.created.items) |uid| {
                self.worker_manager.ensureWorker(uid) catch |err| {
                    log.warn("Failed to start worker for uid={d}: {s}", .{ uid, @errorName(err) });
                };
            }
            // Stop workers for disappeared UIDs
            for (uid_events.removed.items) |uid| {
                self.worker_manager.stopWorker(uid);
            }
            uid_events.created.deinit(self.socket_manager.allocator);
            uid_events.removed.deinit(self.socket_manager.allocator);
            continue;
        }

        // No other special fds expected (ACL watching is done by workers)
        log.warn("Unexpected poll event at index {d}", .{idx});
    }
}

/// Synchronize workers with current /run/user/ state.
/// Starts workers for UIDs that are allowed and have a directory.
fn syncWorkers(self: *Server) void {
    var active_uids = self.socket_manager.getActiveUids();
    defer active_uids.deinit(self.socket_manager.allocator);

    log.info("syncWorkers: {} active UIDs", .{active_uids.items.len});

    for (active_uids.items) |uid| {
        self.worker_manager.ensureWorker(uid) catch |err| {
            log.warn("Failed to sync worker for uid={d}: {s}", .{ uid, @errorName(err) });
        };
    }
}
