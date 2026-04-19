//! Worker lifecycle manager — runs in the main server process.
//!
//! Responsible for:
//!   - Spawning worker processes via systemd template service for crash isolation
//!   - Monitoring worker health via pidfd (c)
//!   - Monitoring catatonit process via pidfd (a)
//!   - Restarting workers when catatonit PID changes or dies
//!   - Stopping workers when UID disappears or ACL removes access
//!   - Retrying worker startup with exponential backoff when catatonit is not yet running
//!
//! Workers run as instantiated systemd services (net-porter-worker@<uid>.service),
//! so they survive a server crash. The server only manages their lifecycle
//! (spawn/stop/restart) but does NOT kill workers on its own shutdown.
//!
//! Security hardening (filesystem, capabilities, syscall filtering) is configured
//! in the template service file: /usr/lib/systemd/system/net-porter-worker@.service
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
    // Workers run as independent systemd services and survive server shutdown.
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
        self.stopService(uid);
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
    if (self.tryAdoptExistingService(uid, catatonit_pid)) {
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

/// Root directory for per-worker data.
/// In production: /run/net-porter/workers (created by tmpfiles.d at boot).
/// In tests: /tmp/net-porter-test-workers (writable without root).
const workers_dir = if (@import("builtin").is_test)
    "/tmp/net-porter-test-workers"
else
    "/run/net-porter/workers";

/// Build the per-UID worker directory: <workers_dir>/<uid>
fn workerDir(allocator: Allocator, uid: u32) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{d}", .{ workers_dir, uid });
}

/// Build the environment file path: <workers_dir>/<uid>/worker.env
fn envFilePath(allocator: Allocator, uid: u32) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{d}/worker.env", .{ workers_dir, uid });
}

/// Build the systemd service instance name: net-porter-worker@<uid>.service
fn serviceInstanceName(allocator: Allocator, uid: u32) ![]const u8 {
    return std.fmt.allocPrint(allocator, "net-porter-worker@{d}.service", .{uid});
}

/// Write the environment file for a worker instance.
/// The template service file (net-porter-worker@.service) reads this via EnvironmentFile=.
fn writeEnvFile(io: std.Io, allocator: Allocator, uid: u32, username: []const u8, catatonit_pid: std.posix.pid_t, config_path: ?[]const u8) !void {
    const path = try envFilePath(allocator, uid);
    defer allocator.free(path);

    const pid_str = std.fmt.allocPrint(allocator, "{d}", .{catatonit_pid}) catch return;
    defer allocator.free(pid_str);

    // Use config_path if provided, otherwise default
    const config = config_path orelse "/etc/net-porter/config.json";

    // Build env file content
    var buf = std.ArrayList(u8).initCapacity(allocator, 256) catch return;
    defer buf.deinit(allocator);

    buf.appendSliceAssumeCapacity("NET_PORTER_USERNAME=");
    buf.appendSliceAssumeCapacity(username);
    buf.appendSliceAssumeCapacity("\nNET_PORTER_CATATONIT_PID=");
    buf.appendSliceAssumeCapacity(pid_str);
    buf.appendSliceAssumeCapacity("\nNET_PORTER_CONFIG=");
    buf.appendSliceAssumeCapacity(config);
    buf.appendSliceAssumeCapacity("\n");

    // Ensure <workers_dir>/<uid> directory exists
    const uid_dir = try workerDir(allocator, uid);
    defer allocator.free(uid_dir);
    std.Io.Dir.cwd().createDirPath(io, uid_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            log.warn("Failed to create worker directory {s}: {s}", .{ uid_dir, @errorName(err) });
            return err;
        },
    };

    // Write env file atomically: write to temp then rename
    const tmp_path = std.fmt.allocPrint(allocator, "{s}/.tmp-worker.env", .{uid_dir}) catch return;
    defer allocator.free(tmp_path);

    // Write temp file
    const tmp_path_z = try allocator.allocSentinel(u8, tmp_path.len, 0);
    defer allocator.free(tmp_path_z);
    @memcpy(tmp_path_z[0..tmp_path.len], tmp_path);

    const fd_rc = linux.open(tmp_path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
    if (fd_rc < 0) {
        log.warn("Failed to create temp env file {s}", .{tmp_path});
        return error.Unexpected;
    }
    var tmp_file = std.Io.File{ .handle = @intCast(fd_rc), .flags = .{ .nonblocking = false } };
    defer tmp_file.close(io);

    var write_buffer: [4096]u8 = undefined;
    var file_writer = tmp_file.writer(io, &write_buffer);
    file_writer.interface.writeAll(buf.items) catch return error.Unexpected;
    file_writer.end() catch return error.Unexpected;

    // Atomic rename: temp → final
    const final_path = try envFilePath(allocator, uid);
    defer allocator.free(final_path);

    const final_path_z = try allocator.allocSentinel(u8, final_path.len, 0);
    defer allocator.free(final_path_z);
    @memcpy(final_path_z[0..final_path.len], final_path);

    const rename_rc = linux.rename(tmp_path_z, final_path_z);
    if (rename_rc != 0) {
        log.warn("Failed to rename env file for uid={d}", .{uid});
        _ = linux.unlink(tmp_path_z);
        return error.Unexpected;
    }
}

/// Remove the environment file for a worker instance.
/// Also removes the per-UID directory if empty.
fn removeEnvFile(io: std.Io, allocator: Allocator, uid: u32) void {
    const path = envFilePath(allocator, uid) catch return;
    defer allocator.free(path);

    const path_z = allocator.allocSentinel(u8, path.len, 0) catch return;
    defer allocator.free(path_z);
    @memcpy(path_z[0..path.len], path);
    _ = linux.unlink(path_z);

    // Try to clean up empty per-UID directory
    const uid_dir = workerDir(allocator, uid) catch return;
    defer allocator.free(uid_dir);
    std.Io.Dir.cwd().deleteDir(io, uid_dir) catch {};
}

fn spawnWorker(self: *WorkerManager, uid: u32, catatonit_pid: std.posix.pid_t) !void {
    // Resolve UID to username for worker ACL loading
    const username = user_mod.getUsername(self.allocator, uid) orelse {
        log.err("Failed to resolve uid={d} to username, cannot spawn worker", .{uid});
        return error.UserNotFound;
    };
    defer self.allocator.free(username);

    // Write environment file for the template service to consume
    writeEnvFile(self.io, self.allocator, uid, username, catatonit_pid, self.config_path) catch |err| {
        log.err("Failed to write env file for uid={d}: {s}", .{ uid, @errorName(err) });
        return err;
    };

    // Start the worker via the systemd template service
    const svc_name = serviceInstanceName(self.allocator, uid) catch return error.OutOfMemory;
    defer self.allocator.free(svc_name);

    const result = std.process.run(self.allocator, self.io, .{
        .argv = &[_][]const u8{ "systemctl", "start", svc_name },
    }) catch |err| {
        log.err("Failed to start {s}: {s}", .{ svc_name, @errorName(err) });
        return err;
    };
    defer self.allocator.free(result.stdout);
    defer self.allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        log.err("systemctl start {s} failed (term={any})", .{ svc_name, result.term });
        return error.SpawnFailed;
    }

    // Find the actual worker PID inside the service's cgroup.
    const worker_pid = self.findServiceWorkerPid(uid) catch |err| blk: {
        log.warn("Failed to find worker PID for uid={d}: {s}", .{ uid, @errorName(err) });
        break :blk @as(std.posix.pid_t, -1);
    };
    if (worker_pid < 0) {
        log.err("Could not locate worker PID for uid={d} after start", .{uid});
        return error.SpawnFailed;
    }

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
    log.info("Spawned worker for uid={d} (username={s}, pid={d}, service={s}, catatonit_pid={d})", .{ uid, username, worker_pid, svc_name, catatonit_pid });
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
    self.stopService(uid);
}

/// Stop a worker service via systemctl and clean up its env file.
fn stopService(self: *WorkerManager, uid: u32) void {
    const svc_name = std.fmt.allocPrint(self.allocator, "net-porter-worker@{d}.service", .{uid}) catch return;
    defer self.allocator.free(svc_name);

    const result = std.process.run(self.allocator, self.io, .{
        .argv = &[_][]const u8{ "systemctl", "stop", svc_name },
    }) catch |err| {
        log.warn("Failed to stop service {s}: {s}", .{ svc_name, @errorName(err) });
        return;
    };
    defer self.allocator.free(result.stdout);
    defer self.allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        log.warn("systemctl stop {s} failed (term={any})", .{ svc_name, result.term });
    }

    // Clean up env file
    removeEnvFile(self.io, self.allocator, uid);
}

/// Check if a running worker's binary differs from the current server binary.
/// Compares /proc/<pid>/exe with /proc/self/exe.
/// Returns true if the worker binary is outdated (different path or deleted).
/// Returns false if same or if detection fails (fail-open: don't restart on error).
fn isBinaryOutdated(self: *WorkerManager, worker_pid: std.posix.pid_t) bool {
    // Read current process exe path
    var self_buf: [std.posix.PATH_MAX]u8 = undefined;
    const self_n = std.Io.Dir.readLinkAbsolute(self.io, "/proc/self/exe", &self_buf) catch return false;
    const self_exe = self_buf[0..self_n];

    var path_buf: [64]u8 = undefined;
    const exe_link = std.fmt.bufPrint(&path_buf, "/proc/{d}/exe", .{worker_pid}) catch return false;

    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const n = std.Io.Dir.readLinkAbsolute(self.io, exe_link, &buf) catch return false;

    return !std.mem.eql(u8, self_exe, buf[0..n]);
}

/// Try to adopt a worker that was spawned by a previous server instance.
fn tryAdoptExistingService(self: *WorkerManager, uid: u32, catatonit_pid: std.posix.pid_t) bool {
    const svc_name = std.fmt.allocPrint(self.allocator, "net-porter-worker@{d}.service", .{uid}) catch return false;
    defer self.allocator.free(svc_name);

    const worker_pid = self.findServiceWorkerPid(uid) catch return false;

    // Check if the running worker's binary is outdated (e.g., after upgrade).
    // If so, stop the old worker and return false to trigger a fresh spawn
    // with the new binary. This ensures security fixes and bug fixes take
    // effect after a package upgrade + service restart.
    if (self.isBinaryOutdated(worker_pid)) {
        log.info("Worker binary outdated for uid={d} (pid={d}), stopping for respawn", .{ uid, worker_pid });
        self.stopService(uid);
        return false;
    }

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

    log.info("Adopted existing worker for uid={d} (pid={d}, service={s})", .{ uid, worker_pid, svc_name });
    return true;
}

/// Find the worker PID by querying systemd for the service's MainPID.
/// Uses `systemctl show --property=MainPID --value` instead of reading
/// cgroup files directly — no hardcoded cgroup paths, resilient to
/// systemd version or layout changes.
fn findServiceWorkerPid(self: *WorkerManager, uid: u32) !std.posix.pid_t {
    const svc_name = std.fmt.allocPrint(self.allocator, "net-porter-worker@{d}.service", .{uid}) catch return error.OutOfMemory;
    defer self.allocator.free(svc_name);

    var attempts: u8 = 0;
    while (attempts < 20) : (attempts += 1) {
        if (self.queryServiceMainPid(svc_name)) |pid| {
            return pid;
        }
        const req: std.os.linux.timespec = .{ .sec = 0, .nsec = 50_000_000 };
        _ = linux.nanosleep(&req, null); // 50ms
    }
    return error.ScopeNotFound;
}

/// Query systemd for a service's MainPID via `systemctl show`.
/// Returns null if the PID is not yet available or on any error.
fn queryServiceMainPid(self: *WorkerManager, svc_name: []const u8) ?std.posix.pid_t {
    const result = std.process.run(self.allocator, self.io, .{
        .argv = &[_][]const u8{ "systemctl", "show", svc_name, "--property=MainPID", "--value" },
    }) catch return null;
    defer self.allocator.free(result.stdout);
    defer self.allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) return null;

    const output = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (output.len == 0) return null;

    const pid = std.fmt.parseUnsigned(std.posix.pid_t, output, 10) catch return null;
    if (pid <= 0) return null;
    return pid;
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

// ── Tests: env file & service helpers ────────────────────────────────

test "envFilePath builds correct path" {
    const allocator = std.testing.allocator;
    const path = try envFilePath(allocator, 1000);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/net-porter-test-workers/1000/worker.env", path);
}

test "serviceInstanceName builds correct name" {
    const allocator = std.testing.allocator;
    const name = try serviceInstanceName(allocator, 1000);
    defer allocator.free(name);
    try std.testing.expectEqualStrings("net-porter-worker@1000.service", name);
}

test "writeEnvFile writes correct content" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const uid = 1000;

    writeEnvFile(io, allocator, uid, "testuser", 12345, "/etc/net-porter/config.json") catch return error.Unexpected;
    defer removeEnvFile(io, allocator, uid);

    // Read back and verify
    const path = try envFilePath(allocator, uid);
    defer allocator.free(path);

    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return error.Unexpected;
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    const content = file_reader.interface.allocRemaining(allocator, .limited(512)) catch return error.Unexpected;
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "NET_PORTER_USERNAME=testuser") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "NET_PORTER_CATATONIT_PID=12345") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "NET_PORTER_CONFIG=/etc/net-porter/config.json") != null);
}

test "writeEnvFile uses default config when null" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const uid = 9999;

    writeEnvFile(io, allocator, uid, "testuser", 12345, null) catch return error.Unexpected;
    defer removeEnvFile(io, allocator, uid);

    const path = try envFilePath(allocator, uid);
    defer allocator.free(path);

    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return error.Unexpected;
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    const content = file_reader.interface.allocRemaining(allocator, .limited(512)) catch return error.Unexpected;
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "NET_PORTER_CONFIG=/etc/net-porter/config.json") != null);
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

// ── Tests: isBinaryOutdated ────────────────────────────────────────

test "isBinaryOutdated returns false for current process" {
    var wm = WorkerManager.init(std.testing.io, std.testing.allocator, null);
    defer wm.deinit();

    // Current process is never outdated compared to itself
    const own_pid: std.posix.pid_t = @intCast(std.os.linux.getpid());
    try std.testing.expect(!wm.isBinaryOutdated(own_pid));
}

test "isBinaryOutdated returns false for non-existent PID" {
    var wm = WorkerManager.init(std.testing.io, std.testing.allocator, null);
    defer wm.deinit();

    // Non-existent PID → readlink fails → fail-open (returns false)
    try std.testing.expect(!wm.isBinaryOutdated(99999999));
}
