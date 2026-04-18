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
        // Build combined poll set: [0] = inotify, [1..N] = worker/catatonit pidfds
        const wm_fds = self.worker_manager.pollFdSlice();
        const total_fds = 1 + wm_fds.len;

        // Stack buffer: 256 entries = 1 inotify + 127 workers × 2 pidfds
        var poll_buf: [256]std.posix.pollfd = undefined;
        if (total_fds > poll_buf.len) {
            log.err("Too many poll fds: {d} (max {d})", .{ total_fds, poll_buf.len });
            return error.TooManyFds;
        }

        poll_buf[0] = .{
            .fd = self.socket_manager.inotify_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        };
        for (wm_fds, 0..) |pfd, i| {
            poll_buf[1 + i] = pfd;
        }

        const timeout = self.worker_manager.nextRetryTimeoutMs() orelse -1;
        const n = std.posix.poll(poll_buf[0..total_fds], timeout) catch |err| {
            log.err("poll failed: {s}", .{@errorName(err)});
            return err;
        };

        // Process worker/catatonit pidfd events (index 1+)
        if (wm_fds.len > 0) {
            self.worker_manager.processPollEvents(poll_buf[1 .. 1 + wm_fds.len]);
        }

        // Process inotify events (index 0)
        if (poll_buf[0].revents & std.posix.POLL.IN != 0) {
            var uid_events = self.socket_manager.processInotifyEvents(&event_buf);
            // Start workers for newly appeared UIDs (batch — also scans pending UIDs)
            if (uid_events.created.items.len > 0) {
                self.worker_manager.ensureWorkers(uid_events.created.items);
            }
            // Stop workers for disappeared UIDs
            for (uid_events.removed.items) |uid| {
                self.worker_manager.stopWorker(uid);
            }
            uid_events.deinit(self.socket_manager.allocator);
        }

        // Process retry timeout
        if (n == 0) {
            self.worker_manager.retryPending();
        }
    }
}

/// Synchronize workers with current /run/user/ state.
fn syncWorkers(self: *Server) void {
    var active_uids = self.socket_manager.getActiveUids();
    defer active_uids.deinit(self.socket_manager.allocator);

    log.info("syncWorkers: {} active UIDs", .{active_uids.items.len});

    self.worker_manager.ensureWorkers(active_uids.items);
}
