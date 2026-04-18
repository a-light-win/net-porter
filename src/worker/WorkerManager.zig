//! Worker lifecycle manager — runs in the main server process.
//!
//! Responsible for:
//!   - Spawning worker processes via `systemd-run --scope` for crash isolation
//!   - Monitoring worker health via pidfd (c)
//!   - Monitoring catatonit process via pidfd (a)
//!   - Restarting workers when catatonit PID changes or dies
//!   - Stopping workers when UID disappears or ACL removes access
//!   - Retrying worker startup with exponential backoff when catatonit is not yet running
//!
//! Workers run in independent systemd scopes, so they survive a server crash.
//! The server only manages their lifecycle (spawn/stop/restart) but does NOT
//! kill workers on its own shutdown — workers are independent daemons.
//!
//! Uses pidfd for efficient process monitoring (no polling).

const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const log = std.log.scoped(.worker);
const user_mod = @import("../user.zig");
const WorkerManager = @This();

const WorkerEntry = struct {
    uid: u32,
    pid: std.posix.pid_t,
    pidfd: std.posix.fd_t,
    catatonit_pid: std.posix.pid_t,
    catatonit_pidfd: std.posix.fd_t,
};

const WorkerMap = std.HashMap(u32, WorkerEntry, WorkerMapContext, 80);

const WorkerMapContext = struct {
    pub fn hash(self: WorkerMapContext, uid: u32) u64 {
        _ = self;
        return std.hash.int(uid);
    }
    pub fn eql(self: WorkerMapContext, a: u32, b: u32) bool {
        _ = self;
        return a == b;
    }
};

/// Result map from batch /proc scan: uid → catatonit_pid.
const PidMap = std.HashMap(u32, std.posix.pid_t, WorkerMapContext, 80);

/// Metadata for a monitored pidfd — used to dispatch poll events.
const FdMeta = struct {
    uid: u32,
    kind: enum { catatonit, worker },
};

const initial_backoff_ms: u32 = 1000;
const max_backoff_ms: u32 = 60000;

allocator: Allocator,
io: std.Io,
config_path: ?[]const u8,
workers: WorkerMap,
/// Metadata for monitored pidfds — kept in sync with monitored_pollfds.
monitored_metas: std.ArrayList(FdMeta),
/// Poll fds for worker + catatonit pidfds — kept in sync with monitored_metas.
monitored_pollfds: std.ArrayList(std.posix.pollfd),
mutex: std.Io.Mutex = .init,

// ── Retry state ──────────────────────────────────────────────────────
pending_uids: std.ArrayList(u32),
backoff_ms: u32 = initial_backoff_ms,
/// Absolute monotonic time (nanoseconds) for next retry. 0 = no retry scheduled.
next_retry_ns: i96 = 0,

pub fn init(io: std.Io, allocator: Allocator, config_path: ?[]const u8) WorkerManager {
    return .{
        .allocator = allocator,
        .io = io,
        .config_path = config_path,
        .workers = WorkerMap.init(allocator),
        .monitored_metas = std.ArrayList(FdMeta).empty,
        .monitored_pollfds = std.ArrayList(std.posix.pollfd).empty,
        .pending_uids = std.ArrayList(u32).empty,
    };
}

pub fn deinit(self: *WorkerManager) void {
    // Release monitoring resources — do NOT kill workers.
    // Workers run in independent systemd scopes and survive server shutdown.
    var it = self.workers.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.pidfd >= 0) {
            _ = linux.close(entry.value_ptr.pidfd);
        }
        if (entry.value_ptr.catatonit_pidfd >= 0) {
            _ = linux.close(entry.value_ptr.catatonit_pidfd);
        }
    }
    self.workers.deinit();
    self.monitored_metas.deinit(self.allocator);
    self.monitored_pollfds.deinit(self.allocator);
    self.pending_uids.deinit(self.allocator);
}

// ── Public API ───────────────────────────────────────────────────────

/// Ensure a worker is running for the given UID (single-uid convenience).
/// Errors are logged internally; this is a no-op on failure.
pub fn ensureWorker(self: *WorkerManager, uid: u32) void {
    self.ensureWorkers(&.{uid});
}

/// Batch version — scans /proc once for all requested UIDs plus any pending UIDs.
/// Errors are logged internally; individual failures do not affect other UIDs.
pub fn ensureWorkers(self: *WorkerManager, uids: []const u32) void {
    self.mutex.lock(self.io) catch return;
    defer self.mutex.unlock(self.io);
    self.ensureWorkersLocked(uids);
}

/// Stop the worker for the given UID (if running).
/// Also removes the UID from the pending retry list.
/// Sends SIGTERM via systemd scope to gracefully stop the worker.
pub fn stopWorker(self: *WorkerManager, uid: u32) void {
    self.mutex.lock(self.io) catch return;
    defer self.mutex.unlock(self.io);

    // Remove from pending if present (user disappeared — no retry wanted)
    for (self.pending_uids.items, 0..) |pending_uid, i| {
        if (pending_uid == uid) {
            _ = self.pending_uids.swapRemove(i);
            break;
        }
    }

    if (self.workers.fetchRemove(uid)) |removed| {
        if (removed.value.pidfd >= 0) {
            _ = linux.close(removed.value.pidfd);
        }
        if (removed.value.catatonit_pidfd >= 0) {
            _ = linux.close(removed.value.catatonit_pidfd);
        }
        self.stopScope(uid);
        self.rebuildMonitoredFds();
        log.info("Stopped worker for uid={d}", .{uid});
    }
}

/// Return monitored poll fds (worker + catatonit pidfds).
/// The caller merges this with the inotify fd into a combined poll set.
/// Valid until the next mutation (ensureWorkers, stopWorker, processPollEvents, retryPending).
pub fn pollFdSlice(self: *WorkerManager) []const std.posix.pollfd {
    return self.monitored_pollfds.items;
}

/// Process poll events on the monitored fds.
/// `poll_results` must be the same length as pollFdSlice() at call time, in the same order.
/// Handles at most one event per call, then rebuilds fd lists and returns.
pub fn processPollEvents(self: *WorkerManager, poll_results: []const std.posix.pollfd) void {
    if (poll_results.len == 0) return;

    for (poll_results, 0..) |pfd, i| {
        if (pfd.revents & std.posix.POLL.IN != 0) {
            const meta = self.monitored_metas.items[i];
            switch (meta.kind) {
                .catatonit => {
                    log.info("Catatonit process died for uid={d} (pidfd event)", .{meta.uid});
                    self.stopAndCleanup(meta.uid);
                    self.addPendingLocked(meta.uid);
                    self.rebuildMonitoredFds();
                },
                .worker => {
                    log.info("Worker process died for uid={d} (pidfd event)", .{meta.uid});
                    self.stopAndCleanup(meta.uid);
                    self.addPendingLocked(meta.uid);
                    self.rebuildMonitoredFds();
                },
            }
            return; // One event per iteration — fd indices are now stale
        }
    }
}

/// Process pending retries — scans /proc once for all pending UIDs.
/// Called when poll times out.
/// Manages global exponential backoff: found ≥1 → reset, found 0 → double (cap 60s).
pub fn retryPending(self: *WorkerManager) void {
    if (self.pending_uids.items.len == 0) return;

    self.mutex.lock(self.io) catch return;
    defer self.mutex.unlock(self.io);

    if (self.pending_uids.items.len == 0) return; // re-check under lock

    var pid_map = discoverAllCatatonitPids(self.io, self.pending_uids.items, self.allocator) catch |err| {
        log.warn("retryPending: scan failed: {s}, will retry later", .{@errorName(err)});
        self.scheduleRetry();
        return;
    };
    defer pid_map.deinit();

    var found_any = false;
    var i: usize = 0;
    while (i < self.pending_uids.items.len) {
        const uid = self.pending_uids.items[i];
        if (pid_map.get(uid)) |catatonit_pid| {
            if (self.ensureWorkerWithPidLocked(uid, catatonit_pid)) {
                _ = self.pending_uids.swapRemove(i);
                found_any = true;
            } else |err| {
                log.warn("retryPending: spawn failed for uid={d}: {s}", .{ uid, @errorName(err) });
                i += 1; // keep in pending, try again later
            }
        } else {
            i += 1;
        }
    }

    if (found_any) {
        self.backoff_ms = initial_backoff_ms;
    } else {
        self.backoff_ms = @min(self.backoff_ms * 2, max_backoff_ms);
    }

    if (self.pending_uids.items.len > 0) {
        self.scheduleRetry();
    } else {
        self.next_retry_ns = 0;
        self.backoff_ms = initial_backoff_ms;
    }
}

/// Compute poll timeout based on pending retry state.
/// Returns null if no retry is scheduled (block indefinitely).
pub fn nextRetryTimeoutMs(self: *WorkerManager) ?i32 {
    if (self.next_retry_ns == 0) return null;

    const now_ns = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
    const remaining_ns = self.next_retry_ns - now_ns;
    if (remaining_ns <= 0) return 0; // Already due

    const remaining_ms = @divTrunc(remaining_ns, std.time.ns_per_ms);
    if (remaining_ms > std.math.maxInt(i32)) return std.math.maxInt(i32);
    return @intCast(remaining_ms);
}

/// Get the list of UIDs with active workers.
pub fn activeUids(self: *WorkerManager, allocator: Allocator) ![]u32 {
    var uids = try std.ArrayList(u32).initCapacity(allocator, self.workers.count());
    errdefer uids.deinit(allocator);

    var it = self.workers.keyIterator();
    while (it.next()) |uid| {
        uids.appendAssumeCapacity(uid.*);
    }
    return uids.toOwnedSlice(allocator);
}

// ── Internal — mutex held by caller ──────────────────────────────────

/// Batch ensure: scan /proc once, handle all requested + pending UIDs.
fn ensureWorkersLocked(self: *WorkerManager, uids: []const u32) void {
    // Collect all UIDs to scan: requested + pending (maximize single /proc scan)
    const total = uids.len + self.pending_uids.items.len;
    if (total == 0) return;

    var all_uids = std.ArrayList(u32).initCapacity(self.allocator, total) catch return;
    defer all_uids.deinit(self.allocator);

    for (uids) |uid| all_uids.appendAssumeCapacity(uid);
    for (self.pending_uids.items) |uid| all_uids.appendAssumeCapacity(uid);

    // Single /proc scan
    var pid_map = discoverAllCatatonitPids(self.io, all_uids.items, self.allocator) catch |err| {
        log.warn("ensureWorkers: scan failed: {s}", .{@errorName(err)});
        for (uids) |uid| {
            if (self.workers.get(uid) == null) {
                self.addPendingLocked(uid);
            }
        }
        return;
    };
    defer pid_map.deinit();

    // Handle requested UIDs
    for (uids) |uid| {
        if (pid_map.get(uid)) |catatonit_pid| {
            self.ensureWorkerWithPidLocked(uid, catatonit_pid) catch |err| {
                log.warn("ensureWorkers: failed for uid={d}: {s}", .{ uid, @errorName(err) });
            };
        } else {
            // Only add to pending if not already tracked
            if (self.workers.get(uid) == null) {
                log.debug("ensureWorkers: no catatonit found for uid={d}, adding to pending", .{uid});
                self.addPendingLocked(uid);
            }
        }
    }

    // Handle pending UIDs found in this scan
    if (self.pending_uids.items.len > 0) {
        var i: usize = 0;
        while (i < self.pending_uids.items.len) {
            const uid = self.pending_uids.items[i];
            if (pid_map.get(uid)) |catatonit_pid| {
                if (self.ensureWorkerWithPidLocked(uid, catatonit_pid)) {
                    _ = self.pending_uids.swapRemove(i);
                } else |err| {
                    log.warn("ensureWorkers: retry failed for pending uid={d}: {s}", .{ uid, @errorName(err) });
                    i += 1; // keep in pending
                }
            } else {
                i += 1;
            }
        }

        // Schedule next retry if pending UIDs remain, clear if all resolved
        if (self.pending_uids.items.len > 0 and self.next_retry_ns == 0) {
            self.scheduleRetry();
        } else if (self.pending_uids.items.len == 0) {
            self.next_retry_ns = 0;
            self.backoff_ms = initial_backoff_ms;
        }
    }
}

/// Ensure a worker is running for the given UID with a pre-discovered catatonit PID.
/// Handles: already-running (no-op), catatonit changed (restart), adopt existing, spawn new.
fn ensureWorkerWithPidLocked(self: *WorkerManager, uid: u32, catatonit_pid: std.posix.pid_t) !void {
    // Check tracked entry first
    if (self.workers.get(uid)) |existing| {
        if (existing.catatonit_pid == catatonit_pid) {
            // Worker already running with correct catatonit PID
            log.debug("Worker already running for uid={d} (pid={d})", .{ uid, existing.pid });
            return;
        }
        // Catatonit PID changed — stop old worker and respawn
        log.info("Catatonit PID changed for uid={d}: {d} → {d}, restarting worker", .{ uid, existing.catatonit_pid, catatonit_pid });
        self.stopAndCleanup(uid);
    }

    // Check if a scope already exists from a previous server instance
    if (self.tryAdoptExistingScope(uid, catatonit_pid)) {
        return;
    }

    self.spawnWorker(uid, catatonit_pid) catch |err| {
        log.err("Failed to spawn worker for uid={d}: {s}", .{ uid, @errorName(err) });
        return err;
    };
}

/// Add a UID to the pending retry list. No-op if already pending.
fn addPendingLocked(self: *WorkerManager, uid: u32) void {
    for (self.pending_uids.items) |pending_uid| {
        if (pending_uid == uid) return;
    }
    self.pending_uids.append(self.allocator, uid) catch {
        log.warn("Failed to add uid={d} to pending list", .{uid});
        return;
    };
    log.debug("Added uid={d} to pending retry list (backoff={d}ms, pending={})", .{ uid, self.backoff_ms, self.pending_uids.items.len });

    // Schedule retry if not already scheduled
    if (self.next_retry_ns == 0) {
        self.scheduleRetry();
    }
}

/// Schedule the next retry based on current backoff.
fn scheduleRetry(self: *WorkerManager) void {
    const now_ns = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
    const delay_ns: i96 = @as(i96, self.backoff_ms) * std.time.ns_per_ms;
    self.next_retry_ns = now_ns + delay_ns;
}

/// Rebuild monitored fd lists from workers map.
fn rebuildMonitoredFds(self: *WorkerManager) void {
    self.monitored_pollfds.clearRetainingCapacity();
    self.monitored_metas.clearRetainingCapacity();

    var it = self.workers.iterator();
    while (it.next()) |entry| {
        const e = entry.value_ptr;

        // Catatonit pidfd
        if (e.catatonit_pidfd >= 0) {
            self.monitored_pollfds.append(self.allocator, .{
                .fd = e.catatonit_pidfd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }) catch {};
            self.monitored_metas.append(self.allocator, .{
                .uid = e.uid,
                .kind = .catatonit,
            }) catch {};
        }

        // Worker pidfd
        if (e.pidfd >= 0) {
            self.monitored_pollfds.append(self.allocator, .{
                .fd = e.pidfd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }) catch {};
            self.monitored_metas.append(self.allocator, .{
                .uid = e.uid,
                .kind = .worker,
            }) catch {};
        }
    }
}

// ── Internal — spawning / stopping ───────────────────────────────────

/// Holds the argv list and its temporary allocated strings for worker spawning.
/// Caller owns all memory and must call `deinit`.
const WorkerArgv = struct {
    argv: std.ArrayList([]const u8),
    uid_str: []const u8,
    pid_str: []const u8,
    scope_name: []const u8,

    fn deinit(self: *WorkerArgv, allocator: Allocator) void {
        self.argv.deinit(allocator);
        allocator.free(self.scope_name);
        allocator.free(self.pid_str);
        allocator.free(self.uid_str);
    }
};

/// Build the argv list for spawning a worker process via `systemd-run --scope`.
/// Returns a `WorkerArgv` containing the built argv and all temporary strings.
/// The caller must call `deinit` to free all memory.
fn buildWorkerArgv(
    allocator: Allocator,
    uid: u32,
    catatonit_pid: std.posix.pid_t,
    username: []const u8,
    config_path: ?[]const u8,
) !WorkerArgv {
    const uid_str = try std.fmt.allocPrint(allocator, "{d}", .{uid});
    errdefer allocator.free(uid_str);

    const pid_str = try std.fmt.allocPrint(allocator, "{d}", .{catatonit_pid});
    errdefer allocator.free(pid_str);

    const scope_name = try std.fmt.allocPrint(allocator, "net-porter-worker@{d}.scope", .{uid});
    errdefer allocator.free(scope_name);

    // 15 fixed args + 2 optional (--config + path) = 17 max
    var argv = std.ArrayList([]const u8).initCapacity(allocator, 18) catch return error.OutOfMemory;
    errdefer argv.deinit(allocator);

    argv.appendAssumeCapacity("systemd-run");
    argv.appendAssumeCapacity("--scope");
    argv.appendAssumeCapacity("--unit");
    argv.appendAssumeCapacity(scope_name);
    argv.appendAssumeCapacity("--property");
    argv.appendAssumeCapacity("CollectMode=inactive-or-failed");
    argv.appendAssumeCapacity("--");

    argv.appendAssumeCapacity("/proc/self/exe");
    argv.appendAssumeCapacity("worker");
    argv.appendAssumeCapacity("--uid");
    argv.appendAssumeCapacity(uid_str);
    argv.appendAssumeCapacity("--username");
    argv.appendAssumeCapacity(username);
    argv.appendAssumeCapacity("--catatonit-pid");
    argv.appendAssumeCapacity(pid_str);

    if (config_path) |cp| {
        argv.appendAssumeCapacity("--config");
        argv.appendAssumeCapacity(cp);
    }

    return .{
        .argv = argv,
        .uid_str = uid_str,
        .pid_str = pid_str,
        .scope_name = scope_name,
    };
}

fn spawnWorker(self: *WorkerManager, uid: u32, catatonit_pid: std.posix.pid_t) !void {
    // Resolve UID to username for worker ACL loading
    const username = user_mod.getUsername(self.allocator, uid) orelse {
        log.err("Failed to resolve uid={d} to username, cannot spawn worker", .{uid});
        return error.UserNotFound;
    };
    defer self.allocator.free(username);

    var worker_argv = try buildWorkerArgv(self.allocator, uid, catatonit_pid, username, self.config_path);
    defer worker_argv.deinit(self.allocator);

    const process = std.process.spawn(self.io, .{
        .argv = worker_argv.argv.items,
    }) catch |err| {
        log.err("Failed to spawn worker via systemd-run for uid={d}: {s}", .{ uid, @errorName(err) });
        return err;
    };

    // systemd-run in --scope mode: it creates the scope, forks the child,
    // and exits once the child is running. The returned PID is systemd-run's
    // PID, not the worker's. We need to find the actual worker PID.
    const systemd_run_pid: std.posix.pid_t = @intCast(process.id.?);
    // reap systemd-run zombie
    var run_status: u32 = 0;
    _ = linux.wait4(systemd_run_pid, &run_status, 0, null);

    // Find the actual worker PID inside the scope.
    const worker_pid = self.findScopeWorkerPid(uid) catch |err| blk: {
        log.warn("Failed to find worker PID for uid={d}: {s}, falling back to systemd-run pid", .{ uid, @errorName(err) });
        break :blk systemd_run_pid;
    };

    // Create pidfd for worker monitoring
    const worker_pidfd = blk: {
        const rc = linux.pidfd_open(worker_pid, 0);
        if (std.posix.errno(rc) == .SUCCESS) {
            break :blk @as(std.posix.fd_t, @intCast(rc));
        } else {
            log.warn("Failed to create pidfd for worker pid={d}", .{worker_pid});
            break :blk @as(std.posix.fd_t, -1);
        }
    };

    // Create pidfd for catatonit monitoring
    const catatonit_pidfd = blk: {
        const rc = linux.pidfd_open(catatonit_pid, 0);
        if (std.posix.errno(rc) == .SUCCESS) {
            break :blk @as(std.posix.fd_t, @intCast(rc));
        } else {
            log.warn("Failed to create pidfd for catatonit pid={d}", .{catatonit_pid});
            break :blk @as(std.posix.fd_t, -1);
        }
    };

    const entry = WorkerEntry{
        .uid = uid,
        .pid = worker_pid,
        .pidfd = worker_pidfd,
        .catatonit_pid = catatonit_pid,
        .catatonit_pidfd = catatonit_pidfd,
    };

    try self.workers.put(uid, entry);
    self.rebuildMonitoredFds();
    log.info("Spawned worker for uid={d} (username={s}, pid={d}, scope={s}, catatonit_pid={d})", .{ uid, username, worker_pid, worker_argv.scope_name, catatonit_pid });
}

/// Stop an existing worker and clean up tracking entry + both pidfds.
fn stopAndCleanup(self: *WorkerManager, uid: u32) void {
    if (self.workers.fetchRemove(uid)) |removed| {
        if (removed.value.pidfd >= 0) {
            _ = linux.close(removed.value.pidfd);
        }
        if (removed.value.catatonit_pidfd >= 0) {
            _ = linux.close(removed.value.catatonit_pidfd);
        }
    }
    self.stopScope(uid);
}

/// Stop a worker scope via systemctl.
fn stopScope(self: *WorkerManager, uid: u32) void {
    const scope_name = std.fmt.allocPrint(self.allocator, "net-porter-worker@{d}.scope", .{uid}) catch return;
    defer self.allocator.free(scope_name);

    const result = std.process.run(self.allocator, self.io, .{
        .argv = &[_][]const u8{ "systemctl", "stop", scope_name },
    }) catch |err| {
        log.warn("Failed to stop scope {s}: {s}", .{ scope_name, @errorName(err) });
        return;
    };
    defer self.allocator.free(result.stdout);
    defer self.allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        log.warn("systemctl stop {s} failed (term={any})", .{ scope_name, result.term });
    }
}

/// Try to adopt a worker that was spawned by a previous server instance.
fn tryAdoptExistingScope(self: *WorkerManager, uid: u32, catatonit_pid: std.posix.pid_t) bool {
    const scope_name = std.fmt.allocPrint(self.allocator, "net-porter-worker@{d}.scope", .{uid}) catch return false;
    defer self.allocator.free(scope_name);

    const worker_pid = self.findScopeWorkerPid(uid) catch return false;

    const worker_pidfd = blk: {
        const rc = linux.pidfd_open(worker_pid, 0);
        if (std.posix.errno(rc) == .SUCCESS) {
            break :blk @as(std.posix.fd_t, @intCast(rc));
        } else {
            break :blk @as(std.posix.fd_t, -1);
        }
    };
    if (worker_pidfd < 0) return false;

    const catatonit_pidfd = blk: {
        const rc = linux.pidfd_open(catatonit_pid, 0);
        if (std.posix.errno(rc) == .SUCCESS) {
            break :blk @as(std.posix.fd_t, @intCast(rc));
        } else {
            break :blk @as(std.posix.fd_t, -1);
        }
    };
    // catatonit_pidfd failure is non-fatal — we can still detect worker exit

    const entry = WorkerEntry{
        .uid = uid,
        .pid = worker_pid,
        .pidfd = worker_pidfd,
        .catatonit_pid = catatonit_pid,
        .catatonit_pidfd = catatonit_pidfd,
    };

    self.workers.put(uid, entry) catch {
        _ = linux.close(worker_pidfd);
        if (catatonit_pidfd >= 0) _ = linux.close(catatonit_pidfd);
        return false;
    };
    self.rebuildMonitoredFds();

    log.info("Adopted existing worker for uid={d} (pid={d}, scope={s})", .{ uid, worker_pid, scope_name });
    return true;
}

/// Find the worker PID by reading the scope's cgroup.procs file.
fn findScopeWorkerPid(self: *WorkerManager, uid: u32) !std.posix.pid_t {
    const path = try std.fmt.allocPrint(self.allocator, "/sys/fs/cgroup/system.slice/net-porter-worker@{d}.scope/cgroup.procs", .{uid});
    defer self.allocator.free(path);

    var attempts: u8 = 0;
    while (attempts < 20) : (attempts += 1) {
        if (self.readFirstPid(path)) |pid| {
            return pid;
        }
        const req: std.os.linux.timespec = .{ .sec = 0, .nsec = 50_000_000 };
        _ = linux.nanosleep(&req, null); // 50ms
    }
    return error.ScopeNotFound;
}

/// Read the first PID from a cgroup.procs file.
/// Uses readPositionalAll (pread) for consistency with isCatatonit — avoids
/// the sendFile path and eliminates a page_allocator heap allocation.
fn readFirstPid(self: *WorkerManager, path: []const u8) ?std.posix.pid_t {
    var file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch return null;
    defer file.close(self.io);

    var buf: [128]u8 = undefined;
    const n = file.readPositionalAll(self.io, &buf, 0) catch return null;
    if (n == 0) return null;

    const data = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (data.len == 0) return null;
    const first_line = if (std.mem.indexOf(u8, data, "\n")) |idx| data[0..idx] else data;
    return std.fmt.parseUnsigned(std.posix.pid_t, first_line, 10) catch null;
}

// ── /proc scanning ───────────────────────────────────────────────────

/// Discover catatonit PIDs for multiple UIDs in a single /proc scan.
/// Returns a HashMap mapping uid → catatonit_pid for all found UIDs.
fn discoverAllCatatonitPids(io: std.Io, target_uids: []const u32, allocator: Allocator) !PidMap {
    var result = PidMap.init(allocator);
    errdefer result.deinit();

    if (target_uids.len == 0) return result;

    // Build a set for O(1) lookup
    var uid_set = std.HashMap(u32, void, WorkerMapContext, 80).init(allocator);
    defer uid_set.deinit();
    for (target_uids) |uid| {
        uid_set.put(uid, {}) catch {};
    }

    var proc_dir = std.Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true }) catch {
        log.warn("discoverAllCatatonitPids: failed to open /proc", .{});
        return result;
    };
    defer proc_dir.close(io);

    var iter = proc_dir.iterate();

    while (iter.next(io) catch null) |entry| {
        // NOTE: Do NOT check entry.kind — /proc may report DT_UNKNOWN.
        if (!isAllDigits(entry.name)) continue;

        const pid = std.fmt.parseUnsigned(std.posix.pid_t, entry.name, 10) catch continue;

        // Check process UID via statx on /proc/<pid> directory
        var path_buf: [64:0]u8 = undefined;
        const path = std.fmt.bufPrint(path_buf[0..], "/proc/{d}", .{pid}) catch continue;
        path_buf[path.len] = 0;

        var statx_buf: linux.Statx = undefined;
        const rc = linux.statx(linux.AT.FDCWD, &path_buf, 0, .{ .UID = true }, &statx_buf);
        if (rc != 0) continue;

        const proc_uid = statx_buf.uid;
        if (!uid_set.contains(proc_uid)) continue;
        if (result.contains(proc_uid)) continue; // already found for this uid

        // Check process name from /proc/<pid>/comm
        if (isCatatonit(io, pid)) {
            result.put(proc_uid, pid) catch {};
            log.debug("discoverAllCatatonitPids: found catatonit pid={d} for uid={d}", .{ pid, proc_uid });

            // Early termination if all found
            if (result.count() == target_uids.len) break;
        }
    }

    return result;
}

/// Discover the catatonit PID for a single UID by scanning /proc directly.
/// Convenience wrapper for single-uid lookups (used in tests).
fn discoverCatatonitPid(io: std.Io, uid: u32) ?std.posix.pid_t {
    var proc_dir = std.Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true }) catch {
        log.warn("discoverCatatonitPid: failed to open /proc", .{});
        return null;
    };
    defer proc_dir.close(io);

    var iter = proc_dir.iterate();

    while (iter.next(io) catch null) |entry| {
        if (!isAllDigits(entry.name)) continue;

        const pid = std.fmt.parseUnsigned(std.posix.pid_t, entry.name, 10) catch continue;

        if (!checkProcessUidByStat(pid, uid)) continue;

        if (isCatatonit(io, pid)) {
            log.info("discoverCatatonitPid: found catatonit pid={d} for uid={d}", .{ pid, uid });
            return pid;
        }
    }

    log.debug("discoverCatatonitPid: no catatonit found for uid={d}", .{uid});
    return null;
}

/// Check if a string consists entirely of ASCII digits.
fn isAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        switch (c) {
            '0'...'9' => {},
            else => return false,
        }
    }
    return true;
}

/// Check process UID by statx()ing /proc/<pid> directory.
fn checkProcessUidByStat(pid: std.posix.pid_t, target_uid: u32) bool {
    var path_buf: [64:0]u8 = undefined;
    const path = std.fmt.bufPrint(path_buf[0..], "/proc/{d}", .{pid}) catch return false;
    path_buf[path.len] = 0;

    var statx_buf: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, &path_buf, 0, .{ .UID = true }, &statx_buf);
    if (rc != 0) return false;
    return statx_buf.uid == target_uid;
}

/// Read /proc/<pid>/comm and check if the process name is "catatonit".
/// Uses readPositionalAll (pread) instead of Reader.allocRemaining to avoid
/// the sendFile path which incorrectly returns EndOfStream for /proc files.
fn isCatatonit(io: std.Io, pid: std.posix.pid_t) bool {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch return false;

    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);

    var buf: [64]u8 = undefined;
    const n = file.readPositionalAll(io, &buf, 0) catch return false;
    if (n == 0) return false;

    const name = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return std.mem.eql(u8, name, "catatonit");
}

// ── Tests ────────────────────────────────────────────────────────────

test "isAllDigits validates numeric strings" {
    try std.testing.expect(isAllDigits("1234"));
    try std.testing.expect(isAllDigits("0"));
    try std.testing.expect(isAllDigits("999999"));
    try std.testing.expect(!isAllDigits(""));
    try std.testing.expect(!isAllDigits("12a34"));
    try std.testing.expect(!isAllDigits("abc"));
    try std.testing.expect(!isAllDigits("123 "));
    try std.testing.expect(!isAllDigits("-1"));
}

test "discoverCatatonitPid returns null for non-existent UID" {
    const result = discoverCatatonitPid(std.testing.io, 999999);
    try std.testing.expect(result == null);
}

test "discoverAllCatatonitPids returns empty for non-existent UIDs" {
    const allocator = std.testing.allocator;
    var result = try discoverAllCatatonitPids(std.testing.io, &.{ 999998, 999999 }, allocator);
    defer result.deinit();
    try std.testing.expect(result.count() == 0);
}

test "checkProcessUidByStat reads /proc/<pid> ownership" {
    const own_pid: std.posix.pid_t = @intCast(std.os.linux.getpid());
    _ = checkProcessUidByStat(own_pid, 0);
    _ = checkProcessUidByStat(own_pid, std.math.maxInt(u32));
}

test "isCatatonit returns false for current process" {
    const own_pid: std.posix.pid_t = @intCast(std.os.linux.getpid());
    try std.testing.expect(!isCatatonit(std.testing.io, own_pid));
}

test "isCatatonit reads /proc/<pid>/comm correctly (not empty)" {
    const test_io = std.testing.io;
    const own_pid: std.posix.pid_t = @intCast(std.os.linux.getpid());

    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{own_pid}) catch return error.Unexpected;

    var file = std.Io.Dir.cwd().openFile(test_io, path, .{}) catch return error.Unexpected;
    defer file.close(test_io);

    var buf: [64]u8 = undefined;
    const n = file.readPositionalAll(test_io, &buf, 0) catch return error.Unexpected;
    try std.testing.expect(n > 0);

    const comm = std.mem.trim(u8, buf[0..n], " \t\r\n");
    try std.testing.expect(comm.len > 0);
}

test "nextRetryTimeoutMs returns null when no retry scheduled" {
    var wm = WorkerManager.init(std.testing.io, std.testing.allocator, null);
    defer wm.deinit();
    try std.testing.expect(wm.nextRetryTimeoutMs() == null);
}

// ── Tests: buildWorkerArgv ───────────────────────────────────────────

test "buildWorkerArgv builds correct argv without config_path" {
    const allocator = std.testing.allocator;

    var wa = try buildWorkerArgv(allocator, 1000, 12345, "testuser", null);
    defer wa.deinit(allocator);

    // 15 fixed args, no --config
    try std.testing.expectEqual(@as(usize, 15), wa.argv.items.len);

    // Verify structure: systemd-run --scope --unit <scope> --property ... -- /proc/self/exe worker ...
    try std.testing.expectEqualStrings("systemd-run", wa.argv.items[0]);
    try std.testing.expectEqualStrings("--scope", wa.argv.items[1]);
    try std.testing.expectEqualStrings("--unit", wa.argv.items[2]);
    try std.testing.expectEqualStrings("net-porter-worker@1000.scope", wa.argv.items[3]);
    try std.testing.expectEqualStrings("--property", wa.argv.items[4]);
    try std.testing.expectEqualStrings("CollectMode=inactive-or-failed", wa.argv.items[5]);
    try std.testing.expectEqualStrings("--", wa.argv.items[6]);
    try std.testing.expectEqualStrings("/proc/self/exe", wa.argv.items[7]);
    try std.testing.expectEqualStrings("worker", wa.argv.items[8]);
    try std.testing.expectEqualStrings("--uid", wa.argv.items[9]);
    try std.testing.expectEqualStrings("1000", wa.argv.items[10]);
    try std.testing.expectEqualStrings("--username", wa.argv.items[11]);
    try std.testing.expectEqualStrings("testuser", wa.argv.items[12]);
    try std.testing.expectEqualStrings("--catatonit-pid", wa.argv.items[13]);
    try std.testing.expectEqualStrings("12345", wa.argv.items[14]);

    // Verify temporary strings match argv references
    try std.testing.expectEqualStrings("1000", wa.uid_str);
    try std.testing.expectEqualStrings("12345", wa.pid_str);
    try std.testing.expectEqualStrings("net-porter-worker@1000.scope", wa.scope_name);
}

test "buildWorkerArgv builds correct argv with config_path (full parameters)" {
    const allocator = std.testing.allocator;
    const config = "/etc/net-porter/config.toml";

    var wa = try buildWorkerArgv(allocator, 1000, 12345, "testuser", config);
    defer wa.deinit(allocator);

    // 15 fixed args + 2 optional (--config + path) = 17
    try std.testing.expectEqual(@as(usize, 17), wa.argv.items.len);

    // Verify all 15 fixed args are identical to the no-config case
    try std.testing.expectEqualStrings("systemd-run", wa.argv.items[0]);
    try std.testing.expectEqualStrings("--scope", wa.argv.items[1]);
    try std.testing.expectEqualStrings("--unit", wa.argv.items[2]);
    try std.testing.expectEqualStrings("net-porter-worker@1000.scope", wa.argv.items[3]);
    try std.testing.expectEqualStrings("--property", wa.argv.items[4]);
    try std.testing.expectEqualStrings("CollectMode=inactive-or-failed", wa.argv.items[5]);
    try std.testing.expectEqualStrings("--", wa.argv.items[6]);
    try std.testing.expectEqualStrings("/proc/self/exe", wa.argv.items[7]);
    try std.testing.expectEqualStrings("worker", wa.argv.items[8]);
    try std.testing.expectEqualStrings("--uid", wa.argv.items[9]);
    try std.testing.expectEqualStrings("1000", wa.argv.items[10]);
    try std.testing.expectEqualStrings("--username", wa.argv.items[11]);
    try std.testing.expectEqualStrings("testuser", wa.argv.items[12]);
    try std.testing.expectEqualStrings("--catatonit-pid", wa.argv.items[13]);
    try std.testing.expectEqualStrings("12345", wa.argv.items[14]);

    // Verify the 2 config_path args at the end
    try std.testing.expectEqualStrings("--config", wa.argv.items[15]);
    try std.testing.expectEqualStrings(config, wa.argv.items[16]);
}

test "buildWorkerArgv with large UID and PID values" {
    const allocator = std.testing.allocator;

    var wa = try buildWorkerArgv(allocator, 4294967294, 2147483647, "root", "/opt/config.yaml");
    defer wa.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 17), wa.argv.items.len);
    try std.testing.expectEqualStrings("4294967294", wa.argv.items[10]); // uid_str
    try std.testing.expectEqualStrings("2147483647", wa.argv.items[14]); // pid_str
    try std.testing.expectEqualStrings("net-porter-worker@4294967294.scope", wa.argv.items[3]); // scope_name
}

// ── Tests: addPendingLocked / scheduleRetry ──────────────────────────

test "addPendingLocked adds UID and deduplicates" {
    var wm = WorkerManager.init(std.testing.io, std.testing.allocator, null);
    defer wm.deinit();

    wm.addPendingLocked(1000);
    try std.testing.expectEqual(@as(usize, 1), wm.pending_uids.items.len);
    try std.testing.expectEqual(@as(u32, 1000), wm.pending_uids.items[0]);

    // Duplicate should be no-op
    wm.addPendingLocked(1000);
    try std.testing.expectEqual(@as(usize, 1), wm.pending_uids.items.len);
}

test "addPendingLocked schedules retry if not already scheduled" {
    var wm = WorkerManager.init(std.testing.io, std.testing.allocator, null);
    defer wm.deinit();

    try std.testing.expect(wm.next_retry_ns == 0);
    wm.addPendingLocked(1000);
    try std.testing.expect(wm.next_retry_ns > 0);
}

test "addPendingLocked handles multiple different UIDs" {
    var wm = WorkerManager.init(std.testing.io, std.testing.allocator, null);
    defer wm.deinit();

    wm.addPendingLocked(1000);
    wm.addPendingLocked(2000);
    wm.addPendingLocked(3000);
    wm.addPendingLocked(2000); // duplicate

    try std.testing.expectEqual(@as(usize, 3), wm.pending_uids.items.len);
}

test "scheduleRetry sets next_retry_ns in the future" {
    var wm = WorkerManager.init(std.testing.io, std.testing.allocator, null);
    defer wm.deinit();

    const now_ns = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds;
    wm.scheduleRetry();

    try std.testing.expect(wm.next_retry_ns > now_ns);
}

// ── Tests: ensureWorkerWithPidLocked (no-op case) ───────────────────

test "ensureWorkerWithPidLocked is no-op when worker already running with same catatonit_pid" {
    var wm = WorkerManager.init(std.testing.io, std.testing.allocator, null);
    defer wm.deinit();

    // Manually insert a worker entry
    try wm.workers.put(1000, .{
        .uid = 1000,
        .pid = 9999,
        .pidfd = -1,
        .catatonit_pid = 500,
        .catatonit_pidfd = -1,
    });

    // Call with same catatonit_pid — should be no-op (worker stays)
    try wm.ensureWorkerWithPidLocked(1000, 500);

    // Worker should still be tracked
    const entry = wm.workers.get(1000);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(@as(std.posix.pid_t, 9999), entry.?.pid);
    try std.testing.expectEqual(@as(std.posix.pid_t, 500), entry.?.catatonit_pid);
}

// ── Tests: rebuildMonitoredFds ───────────────────────────────────────

test "rebuildMonitoredFds builds correct fd lists from workers" {
    var wm = WorkerManager.init(std.testing.io, std.testing.allocator, null);
    defer wm.deinit();

    // Add two worker entries with valid-looking pidfds (use -1 to skip close)
    try wm.workers.put(1000, .{
        .uid = 1000,
        .pid = 100,
        .pidfd = -1,
        .catatonit_pid = 200,
        .catatonit_pidfd = -1,
    });
    try wm.workers.put(2000, .{
        .uid = 2000,
        .pid = 300,
        .pidfd = -1,
        .catatonit_pid = 400,
        .catatonit_pidfd = -1,
    });

    wm.rebuildMonitoredFds();

    // 2 workers × 2 fds each (catatonit + worker) = 4 entries
    // But pidfd = -1 means those entries are skipped
    try std.testing.expectEqual(@as(usize, 0), wm.monitored_pollfds.items.len);
    try std.testing.expectEqual(@as(usize, 0), wm.monitored_metas.items.len);
}

// ── Tests: stopAndCleanup ────────────────────────────────────────────

test "stopAndCleanup removes worker entry" {
    var wm = WorkerManager.init(std.testing.io, std.testing.allocator, null);
    defer wm.deinit();

    try wm.workers.put(1000, .{
        .uid = 1000,
        .pid = 100,
        .pidfd = -1,
        .catatonit_pid = 200,
        .catatonit_pidfd = -1,
    });

    try std.testing.expect(wm.workers.get(1000) != null);
    wm.stopAndCleanup(1000);
    try std.testing.expect(wm.workers.get(1000) == null);
}

test "stopAndCleanup is no-op for non-existent UID" {
    var wm = WorkerManager.init(std.testing.io, std.testing.allocator, null);
    defer wm.deinit();

    // Should not crash
    wm.stopAndCleanup(9999);
    try std.testing.expectEqual(@as(usize, 0), wm.workers.count());
}

// ── Tests: stopWorker ────────────────────────────────────────────────

test "stopWorker removes UID from pending list" {
    var wm = WorkerManager.init(std.testing.io, std.testing.allocator, null);
    defer wm.deinit();

    wm.addPendingLocked(1000);
    wm.addPendingLocked(2000);
    try std.testing.expectEqual(@as(usize, 2), wm.pending_uids.items.len);

    wm.stopWorker(1000);
    try std.testing.expectEqual(@as(usize, 1), wm.pending_uids.items.len);
    try std.testing.expectEqual(@as(u32, 2000), wm.pending_uids.items[0]);
}

// ── Tests: WorkerArgv.deinit ─────────────────────────────────────────

test "WorkerArgv.deinit frees all allocated memory" {
    const allocator = std.testing.allocator;

    var wa = try buildWorkerArgv(allocator, 1000, 54321, "testuser", "/path/to/config.toml");
    // Verify it built correctly before cleanup
    try std.testing.expectEqual(@as(usize, 17), wa.argv.items.len);
    // deinit should not leak — verified by std.testing.allocator (detects leaks)
    wa.deinit(allocator);
}
