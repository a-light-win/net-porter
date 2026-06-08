const std = @import("std");
const log = std.log.scoped(.server);
const config_mod = @import("../config.zig");
const version = @import("build_options").version;
const AclScanner = @import("AclScanner.zig");
const AclWatcher = @import("AclWatcher.zig");
const WorkerManager = @import("../worker/WorkerManager.zig");
const UidTracker = @import("UidTracker.zig");
const user_mod = @import("../user.zig");

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
    /// Root allocator for all server-owned allocations. When null, falls back
    /// to std.heap.page_allocator (no leak detection). Callers should pass a
    /// DebugAllocator in Debug/ReleaseSafe builds for memory safety checks.
    allocator: ?std.mem.Allocator = null,
};

pub fn new(opts: Opts) !Server {
    const io = opts.io orelse return error.IoNotInitialized;
    // Use caller-provided allocator (typically DebugAllocator for leak detection),
    // falling back to page_allocator when unset (e.g., legacy callers).
    const allocator = opts.allocator orelse std.heap.page_allocator;

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
    @import("root").logger.log_settings = conf.log;
    errdefer managed_config.deinit();

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

/// Optional controls for `run()`. All fields default to "disabled".
pub const RunOpts = struct {
    /// Atomic flag set by an external signal handler to request graceful
    /// shutdown. When set, the event loop exits after the current iteration
    /// and `run()` returns normally so that `defer server.deinit()` runs.
    /// Null disables graceful shutdown (loop runs forever, matching prior
    /// behavior).
    shutdown_flag: ?*const std.atomic.Value(bool) = null,
    /// Read end of a self-pipe included in the poll set. When the external
    /// signal handler writes to the pipe, poll() returns immediately instead
    /// of blocking until the next event. Negative value disables wake-up.
    wake_fd: std.posix.fd_t = -1,
};

pub fn run(self: *Server, opts: RunOpts) !void {
    log.info("net-porter {s} started, monitoring /run/user/", .{version});
    self.syncWorkers();

    var event_buf: [4096]u8 = undefined;
    const has_wake = opts.wake_fd >= 0;

    while (true) {
        // Check for shutdown at the top of each iteration so we exit promptly
        // when the signal handler flips the flag (whether before entering poll
        // or after being woken up via the self-pipe).
        if (opts.shutdown_flag) |f| {
            if (f.load(.acquire)) break;
        }

        // Build poll set:
        //   [0]          : wake_fd (optional, for signal-driven wake-up)
        //   [next]       : uid tracker inotify (always)
        //   [next]       : acl watcher inotify (optional)
        //   [rest]       : worker manager pidfds
        const wm_fds = self.worker_manager.pollFdSlice();
        const has_acl_watch = self.acl_watcher.getInotifyFd() != null;
        const fixed_fds: usize = 1 + @as(usize, @intFromBool(has_acl_watch)) + @as(usize, @intFromBool(has_wake));
        const total_fds = fixed_fds + wm_fds.len;

        var poll_buf: [256]std.posix.pollfd = undefined;
        if (total_fds > poll_buf.len) {
            log.err("Too many poll fds: {d} (max {d})", .{ total_fds, poll_buf.len });
            return error.TooManyFds;
        }

        var slot: usize = 0;

        // Wake fd at index 0 (if provided) so the drain check below is cheap.
        if (has_wake) {
            poll_buf[slot] = .{
                .fd = opts.wake_fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            };
            slot += 1;
        }

        poll_buf[slot] = .{
            .fd = self.uid_tracker.inotify_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        };
        const uid_fd_index: usize = slot;
        slot += 1;

        const acl_fd_index: ?usize = blk: {
            if (has_acl_watch) {
                poll_buf[slot] = .{
                    .fd = self.acl_watcher.getInotifyFd().?,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                };
                const idx = slot;
                slot += 1;
                break :blk idx;
            }
            break :blk null;
        };

        // `slot` now equals `fixed_fds`. Append worker pidfds.
        const wm_start: usize = slot;
        for (wm_fds, 0..) |pfd, i| {
            poll_buf[slot + i] = pfd;
        }

        const timeout = self.worker_manager.nextRetryTimeoutMs() orelse -1;

        const n = std.posix.poll(poll_buf[0..total_fds], timeout) catch |err| {
            log.err("poll failed: {s}", .{@errorName(err)});
            return err;
        };

        // Drain wake fd if it fired. We don't act on the data — its sole
        // purpose is to wake poll() so the loop iterates and re-checks the
        // shutdown flag above.
        if (has_wake and (poll_buf[0].revents & std.posix.POLL.IN != 0)) {
            var drain_buf: [64]u8 = undefined;
            while (true) {
                const rc = std.os.linux.read(opts.wake_fd, &drain_buf, drain_buf.len);
                // Negative return means EAGAIN (non-blocking pipe drained) or error.
                if (@as(isize, @bitCast(rc)) <= 0) break;
            }
        }

        if (wm_fds.len > 0) {
            self.worker_manager.processPollEvents(poll_buf[wm_start .. wm_start + wm_fds.len]);
        }

        if (acl_fd_index) |idx| {
            if (poll_buf[idx].revents & std.posix.POLL.IN != 0) {
                if (self.acl_watcher.processInotifyEvents(&event_buf)) {
                    self.handleAclChange();
                }
            }
        }

        if (poll_buf[uid_fd_index].revents & std.posix.POLL.IN != 0) {
            var uid_events = self.uid_tracker.processInotifyEvents(&event_buf);
            if (uid_events.created.items.len > 0) {
                self.worker_manager.ensureWorkers(uid_events.created.items);
            }
            for (uid_events.removed.items) |uid| {
                self.worker_manager.stopWorker(uid);
            }
            uid_events.deinit(self.uid_tracker.allocator);
        }

        if (n == 0) {
            self.worker_manager.retryPending();
        }
    }

    log.info("Shutdown requested, exiting event loop", .{});
}

/// Synchronize workers with current /run/user/ state.
fn syncWorkers(self: *Server) void {
    var active_uids = self.uid_tracker.getActiveUids() catch |err| {
        log.warn("Failed to get active UIDs: {s}, skipping worker sync", .{@errorName(err)});
        return;
    };
    defer active_uids.deinit(self.uid_tracker.allocator);

    log.info("syncWorkers: {} active UIDs", .{active_uids.items.len});

    self.worker_manager.ensureWorkers(active_uids.items);
}

/// Handle a detected change in the ACL directory.
/// Re-scans UIDs, updates the allowed list, and starts/stops workers as needed.
/// Detects UID reuse: if a username-to-UID mapping changed, stops the old worker
/// so it gets respawned with the correct username and ACL.
fn handleAclChange(self: *Server) void {
    var new_uids = self.acl_manager.scanUids(self.io);

    // Guard: if scan returns empty but old list was non-empty, assume
    // transient failure (e.g. ACL directory temporarily unavailable).
    // This prevents wiping all workers due to a fleeting I/O error.
    if (new_uids.items.len == 0 and self.uid_tracker.allowed_uids.items.len > 0) {
        log.warn("ACL scan returned empty but {} UIDs were allowed, skipping update (possible transient failure)", .{self.uid_tracker.allowed_uids.items.len});
        new_uids.deinit(self.uid_tracker.allocator);
        return;
    }

    var delta = self.uid_tracker.updateAllowedUids(new_uids);
    defer delta.deinit(self.uid_tracker.allocator);

    // Stop workers for removed UIDs
    for (delta.removed.items) |uid| {
        self.worker_manager.stopWorker(uid);
    }

    // Detect username changes for unchanged UIDs (UID reuse attack prevention).
    // If a user was deleted and a new user assigned the same UID, the existing
    // worker still runs with the old username's ACL. Stop it so it respawns
    // with the correct username.
    var mismatched_uids = std.ArrayList(u32).initCapacity(self.uid_tracker.allocator, self.uid_tracker.allowed_uids.items.len) catch return;
    defer mismatched_uids.deinit(self.uid_tracker.allocator);

    for (self.uid_tracker.allowed_uids.items) |uid| {
        // Skip newly added UIDs — they'll get fresh workers with correct usernames
        var is_added = false;
        for (delta.added.items) |added_uid| {
            if (added_uid == uid) {
                is_added = true;
                break;
            }
        }
        if (is_added) continue;

        const stored_username = self.worker_manager.getWorkerUsername(uid) orelse continue;
        const current_username = user_mod.getUsername(self.uid_tracker.allocator, uid) catch continue orelse continue;

        if (!user_mod.isValidUsername(current_username)) {
            log.warn("Username '{s}' for uid={d} failed validation, skipping", .{ current_username, uid });
            self.uid_tracker.allocator.free(current_username);
            continue;
        }

        if (!std.mem.eql(u8, stored_username, current_username)) {
            log.warn("Username changed for uid={d}: '{s}' -> '{s}', restarting worker", .{ uid, stored_username, current_username });
            self.uid_tracker.allocator.free(current_username);
            self.worker_manager.stopWorker(uid);
            mismatched_uids.appendAssumeCapacity(uid);
        } else {
            self.uid_tracker.allocator.free(current_username);
        }
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

    // Re-spawn workers for mismatched UIDs that are still active
    if (mismatched_uids.items.len > 0) {
        var active_mismatched = std.ArrayList(u32).initCapacity(self.uid_tracker.allocator, mismatched_uids.items.len) catch return;
        defer active_mismatched.deinit(self.uid_tracker.allocator);

        for (mismatched_uids.items) |uid| {
            if (self.uid_tracker.isUidActive(uid)) {
                active_mismatched.appendAssumeCapacity(uid);
            }
        }
        if (active_mismatched.items.len > 0) {
            self.worker_manager.ensureWorkers(active_mismatched.items);
        }
    }
}

test "handleAclChange updates allowed UIDs from ACL scan" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_dir = try AclScanner.TestAclDir.create(io, allocator);
    defer test_dir.deinit();

    // Create root.json which resolves to uid 0
    try test_dir.writeFile("root.json", "{}");

    // Start with a different allowed UID
    var allowed_uids = std.ArrayList(u32).initCapacity(allocator, 1) catch return error.Unexpected;
    allowed_uids.appendAssumeCapacity(9999);

    // Add an active entry for root (uid 0)
    var entries = std.ArrayList(UidTracker.UidEntry).initCapacity(allocator, 1) catch return error.Unexpected;
    entries.appendAssumeCapacity(.{ .uid = 0 });

    var server = Server{
        .config = config_mod.Config{ .acl_dir = test_dir.dir_path },
        .io = io,
        .acl_manager = AclScanner.init(allocator, test_dir.dir_path),
        .acl_watcher = AclWatcher{
            .allocator = allocator,
            .io = io,
            .acl_dir = test_dir.dir_path,
            .inotify_fd = null,
        },
        .worker_manager = WorkerManager.init(io, allocator, null),
        .uid_tracker = UidTracker{
            .allocator = allocator,
            .io = io,
            .allowed_uids = allowed_uids,
            .entries = entries,
            .inotify_fd = -1,
        },
        .managed_config = config_mod.ManagedConfig{ .config = config_mod.Config{} },
    };
    defer server.deinit();

    // Before: 9999 is allowed, 0 is active but not allowed
    try std.testing.expect(server.uid_tracker.isUidAllowed(9999));
    try std.testing.expect(!server.uid_tracker.isUidAllowed(0));
    try std.testing.expect(server.uid_tracker.isUidActive(0));

    // Re-scan ACLs
    server.handleAclChange();

    // After: 0 should be allowed, 9999 removed
    try std.testing.expect(!server.uid_tracker.isUidAllowed(9999));
    try std.testing.expect(server.uid_tracker.isUidAllowed(0));
    try std.testing.expect(server.uid_tracker.isUidActive(0));
}

test "handleAclChange preserves UIDs on empty scan result" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_dir = try AclScanner.TestAclDir.create(io, allocator);
    defer test_dir.deinit();

    // No ACL files - directory is empty

    var allowed_uids = std.ArrayList(u32).initCapacity(allocator, 2) catch return error.Unexpected;
    allowed_uids.appendAssumeCapacity(1000);
    allowed_uids.appendAssumeCapacity(2000);

    var server = Server{
        .config = config_mod.Config{ .acl_dir = test_dir.dir_path },
        .io = io,
        .acl_manager = AclScanner.init(allocator, test_dir.dir_path),
        .acl_watcher = AclWatcher{
            .allocator = allocator,
            .io = io,
            .acl_dir = test_dir.dir_path,
            .inotify_fd = null,
        },
        .worker_manager = WorkerManager.init(io, allocator, null),
        .uid_tracker = UidTracker{
            .allocator = allocator,
            .io = io,
            .allowed_uids = allowed_uids,
            .entries = std.ArrayList(UidTracker.UidEntry).empty,
            .inotify_fd = -1,
        },
        .managed_config = config_mod.ManagedConfig{ .config = config_mod.Config{} },
    };
    defer server.deinit();

    try std.testing.expect(server.uid_tracker.isUidAllowed(1000));
    try std.testing.expect(server.uid_tracker.isUidAllowed(2000));

    server.handleAclChange();

    // Empty scan with existing UIDs: guard kicks in, UIDs preserved
    try std.testing.expect(server.uid_tracker.isUidAllowed(1000));
    try std.testing.expect(server.uid_tracker.isUidAllowed(2000));
}

test "handleAclChange detects username mismatch and stops worker" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_dir = try AclScanner.TestAclDir.create(io, allocator);
    defer test_dir.deinit();

    // Create root.json which resolves to uid 0
    try test_dir.writeFile("root.json", "{}");

    var allowed_uids = std.ArrayList(u32).initCapacity(allocator, 1) catch return error.Unexpected;
    allowed_uids.appendAssumeCapacity(0);

    var entries = std.ArrayList(UidTracker.UidEntry).initCapacity(allocator, 1) catch return error.Unexpected;
    entries.appendAssumeCapacity(.{ .uid = 0 });

    var worker_manager = WorkerManager.init(io, allocator, null);
    const hacker_username = try allocator.dupe(u8, "hacker");
    try worker_manager.injectTestWorker(0, hacker_username);

    try std.testing.expect(worker_manager.getWorkerUsername(0) != null);
    try std.testing.expectEqualStrings("hacker", worker_manager.getWorkerUsername(0).?);

    var server = Server{
        .config = config_mod.Config{ .acl_dir = test_dir.dir_path },
        .io = io,
        .acl_manager = AclScanner.init(allocator, test_dir.dir_path),
        .acl_watcher = AclWatcher{
            .allocator = allocator,
            .io = io,
            .acl_dir = test_dir.dir_path,
            .inotify_fd = null,
        },
        .worker_manager = worker_manager,
        .uid_tracker = UidTracker{
            .allocator = allocator,
            .io = io,
            .allowed_uids = allowed_uids,
            .entries = entries,
            .inotify_fd = -1,
        },
        .managed_config = config_mod.ManagedConfig{ .config = config_mod.Config{} },
    };
    defer server.deinit();

    // Re-scan ACLs — should detect that uid 0's username changed from "hacker" to "root"
    server.handleAclChange();

    // Worker should have been stopped due to username mismatch
    try std.testing.expect(server.worker_manager.getWorkerUsername(0) == null);
}
