const std = @import("std");
const log = std.log.scoped(.server);
const config_mod = @import("../config.zig");
const version = @import("build_options").version;
const AclManager = @import("AclManager.zig");
const WorkerManager = @import("WorkerManager.zig");
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
    const io = self.io;
    log.info("net-porter {s} started, monitoring /run/user/ and ACL directory", .{version});

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
            const uid_events = self.socket_manager.processInotifyEvents(&event_buf);
            // Start workers for newly appeared UIDs
            for (uid_events.created.items) |uid| {
                if (self.acl_manager.hasAnyPermission(io, uid, 0)) {
                    self.worker_manager.ensureWorker(uid) catch |err| {
                        log.warn("Failed to start worker for uid={d}: {s}", .{ uid, @errorName(err) });
                    };
                }
            }
            // Stop workers for disappeared UIDs
            for (uid_events.removed.items) |uid| {
                self.worker_manager.stopWorker(uid);
            }
            continue;
        }

        if (idx == 1 and self.acl_manager.acl_inotify_fd != null) {
            // inotify event on acl_dir
            const changed = self.acl_manager.processInotifyEvents(&event_buf);
            if (changed) {
                self.acl_manager.reload(io);
                const new_uids = self.acl_manager.getAllowedUids(io, std.heap.page_allocator);
                self.socket_manager.updateAllowedUids(new_uids);
                // Restart workers for added/removed UIDs
                self.syncWorkers();
            }
            continue;
        }

        // No server socket events in the main process — workers handle connections.
        // Any poll event at index >= num_special_fds is unexpected.
        log.warn("Unexpected poll event at index {d}", .{idx});
    }
}

/// Synchronize workers with current ACL and /run/user/ state.
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
