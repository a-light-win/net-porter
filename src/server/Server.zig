const std = @import("std");
const log = std.log.scoped(.server);
const config_mod = @import("../config.zig");
const version = @import("build_options").version;
const AclScanner = @import("AclScanner.zig");
const AclWatcher = @import("AclWatcher.zig");
const WorkerManager = @import("../worker/WorkerManager.zig");
const UidTracker = @import("UidTracker.zig");
const Server = @This();

config: config_mod.Config,
io: std.Io,
acl_manager: AclScanner,
acl_watcher: AclWatcher,
worker_manager: WorkerManager,
uid_tracker: UidTracker,
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
    var acl_manager = AclScanner.init(allocator, conf.acl_dir);

    const allowed_uids = acl_manager.scanUids(io);
    log.info("ACL scan: {} allowed UIDs", .{allowed_uids.items.len});

    var uid_tracker = try UidTracker.init(io, allocator, allowed_uids);

    uid_tracker.scanExisting(io);

    // Watch acl.d/ for dynamic ACL changes (graceful: null if setup fails)
    const acl_watcher = AclWatcher.init(allocator, io, conf.acl_dir) orelse acl_watcher: {
        log.warn("ACL directory watcher not available, dynamic ACL updates disabled", .{});
        break :acl_watcher AclWatcher{
            .allocator = allocator,
            .io = io,
            .acl_dir = conf.acl_dir,
            .inotify_fd = null,
        };
    };

    // Initialize worker manager for per-UID worker processes
    const worker_manager = WorkerManager.init(io, allocator, opts.config_path);

    return Server{
        .config = conf,
        .io = io,
        .acl_manager = acl_manager,
        .acl_watcher = acl_watcher,
        .worker_manager = worker_manager,
        .uid_tracker = uid_tracker,
        .managed_config = managed_config,
    };
}

pub fn deinit(self: *Server) void {
    log.info("Server shutting down...", .{});
    self.acl_watcher.deinit();
    self.worker_manager.deinit();
    self.uid_tracker.deinit();
    self.managed_config.deinit();
}

pub fn run(self: *Server) !void {
    log.info("net-porter {s} started, monitoring /run/user/", .{version});

    // Start workers for UIDs that already exist at startup
    self.syncWorkers();

    var event_buf: [4096]u8 = undefined;

    while (true) {
        // Build combined poll set:
        //   [0] = uid_tracker inotify (/run/user/)
        //   [1] = acl_watcher inotify (acl.d/)
        //   [2..N] = worker/catatonit pidfds
        const wm_fds = self.worker_manager.pollFdSlice();
        const has_acl_watch = self.acl_watcher.getInotifyFd() != null;
        const fixed_fds: usize = 1 + @intFromBool(has_acl_watch);
        const total_fds = fixed_fds + wm_fds.len;

        // Stack buffer: 256 entries = 2 inotify + worker pidfds
        var poll_buf: [256]std.posix.pollfd = undefined;
        if (total_fds > poll_buf.len) {
            log.err("Too many poll fds: {d} (max {d})", .{ total_fds, poll_buf.len });
            return error.TooManyFds;
        }

        // [0] uid_tracker inotify
        poll_buf[0] = .{
            .fd = self.uid_tracker.inotify_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        };

        // [1] acl_watcher inotify (if available)
        const acl_fd_index: usize = if (has_acl_watch) 1 else 0;
        if (has_acl_watch) {
            poll_buf[1] = .{
                .fd = self.acl_watcher.getInotifyFd().?,
                .events = std.posix.POLL.IN,
                .revents = 0,
            };
        }

        // [fixed_fds..N] worker/catatonit pidfds
        for (wm_fds, 0..) |pfd, i| {
            poll_buf[fixed_fds + i] = pfd;
        }

        const timeout = self.worker_manager.nextRetryTimeoutMs() orelse -1;
        const n = std.posix.poll(poll_buf[0..total_fds], timeout) catch |err| {
            log.err("poll failed: {s}", .{@errorName(err)});
            return err;
        };

        // Process worker/catatonit pidfd events (index fixed_fds+)
        if (wm_fds.len > 0) {
            self.worker_manager.processPollEvents(poll_buf[fixed_fds .. fixed_fds + wm_fds.len]);
        }

        // Process uid_tracker inotify events (index 0)
        if (poll_buf[0].revents & std.posix.POLL.IN != 0) {
            var uid_events = self.uid_tracker.processInotifyEvents(&event_buf);
            // Start workers for newly appeared UIDs (batch — also scans pending UIDs)
            if (uid_events.created.items.len > 0) {
                self.worker_manager.ensureWorkers(uid_events.created.items);
            }
            // Stop workers for disappeared UIDs
            for (uid_events.removed.items) |uid| {
                self.worker_manager.stopWorker(uid);
            }
            uid_events.deinit(self.uid_tracker.allocator);
        }

        // Process acl_watcher inotify events (index 1)
        if (has_acl_watch and poll_buf[acl_fd_index].revents & std.posix.POLL.IN != 0) {
            if (self.acl_watcher.processInotifyEvents(&event_buf)) {
                self.handleAclChange();
            }
        }

        // Process retry timeout
        if (n == 0) {
            self.worker_manager.retryPending();
        }
    }
}

/// Synchronize workers with current /run/user/ state.
fn syncWorkers(self: *Server) void {
    var active_uids = self.uid_tracker.getActiveUids();
    defer active_uids.deinit(self.uid_tracker.allocator);

    log.info("syncWorkers: {} active UIDs", .{active_uids.items.len});

    self.worker_manager.ensureWorkers(active_uids.items);
}

/// Handle a detected change in the ACL directory.
/// Re-scans UIDs, updates the allowed list, and starts/stops workers as needed.
fn handleAclChange(self: *Server) void {
    const new_uids = self.acl_manager.scanUids(self.io);
    var delta = self.uid_tracker.updateAllowedUids(new_uids);
    defer delta.deinit(self.uid_tracker.allocator);

    // Stop workers for removed UIDs
    for (delta.removed.items) |uid| {
        self.worker_manager.stopWorker(uid);
    }

    // Start workers for added UIDs that are currently active
    if (delta.added.items.len > 0) {
        var active_added = std.ArrayList(u32).initCapacity(self.uid_tracker.allocator, delta.added.items.len) catch return;
        defer active_added.deinit(self.uid_tracker.allocator);

        for (delta.added.items) |uid| {
            if (self.uid_tracker.isUidActive(uid)) {
                active_added.appendAssumeCapacity(uid);
            }
        }
        if (active_added.items.len > 0) {
            self.worker_manager.ensureWorkers(active_added.items);
        }
    }
}
