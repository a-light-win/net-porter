//! Worker lifecycle manager — runs in the main server process.
//!
//! Responsible for:
//!   - Spawning worker processes via `systemd-run --scope` for crash isolation
//!   - Monitoring worker health via pidfd
//!   - Restarting workers when catatonit PID changes
//!   - Stopping workers when UID disappears or ACL removes access
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

allocator: Allocator,
io: std.Io,
config_path: ?[]const u8,
workers: WorkerMap,
mutex: std.Io.Mutex = .init,

pub fn init(io: std.Io, allocator: Allocator, config_path: ?[]const u8) WorkerManager {
    return .{
        .allocator = allocator,
        .io = io,
        .config_path = config_path,
        .workers = WorkerMap.init(allocator),
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
    }
    self.workers.deinit();
}

/// Ensure a worker is running for the given UID.
/// Discovers the catatonit PID and spawns a worker if needed.
/// If the catatonit PID has changed, stops the old scope and respawns.
/// Idempotent: if a scope already exists with the same catatonit PID, no-op.
pub fn ensureWorker(self: *WorkerManager, uid: u32) !void {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);

    const catatonit_pid = discoverCatatonitPid(self.io, uid) orelse {
        log.warn("No catatonit process found for uid={d}, skipping worker start", .{uid});
        return;
    };

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

    // Check if a scope already exists from a previous server instance.
    // If the scope is active (worker still running), reuse it.
    if (self.tryAdoptExistingScope(uid, catatonit_pid)) {
        return;
    }

    self.spawnWorker(uid, catatonit_pid) catch |err| {
        log.err("Failed to spawn worker for uid={d}: {s}", .{ uid, @errorName(err) });
        return err;
    };
}

/// Stop the worker for the given UID (if running).
/// Sends SIGTERM via systemd scope to gracefully stop the worker.
pub fn stopWorker(self: *WorkerManager, uid: u32) void {
    self.mutex.lock(self.io) catch return;
    defer self.mutex.unlock(self.io);

    if (self.workers.fetchRemove(uid)) |removed| {
        self.stopScope(uid);
        if (removed.value.pidfd >= 0) {
            _ = linux.close(removed.value.pidfd);
        }
        log.info("Stopped worker for uid={d}", .{uid});
    }
}

/// Check if any workers have exited (non-blocking).
/// Should be called periodically from the main event loop.
/// Returns the UID of an exited worker, or null.
pub fn pollExited(self: *WorkerManager) ?u32 {
    // Use ppoll with timeout=0 on all pidfds
    var poll_fds = std.ArrayList(std.posix.pollfd).initCapacity(self.allocator, self.workers.count()) catch return null;
    defer poll_fds.deinit(self.allocator);

    var uids = std.ArrayList(u32).initCapacity(self.allocator, self.workers.count()) catch return null;
    defer uids.deinit(self.allocator);

    var it = self.workers.iterator();
    while (it.next()) |entry| {
        poll_fds.appendAssumeCapacity(.{
            .fd = entry.value_ptr.pidfd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        });
        uids.appendAssumeCapacity(entry.key_ptr.*);
    }

    if (poll_fds.items.len == 0) return null;

    const n = std.posix.poll(poll_fds.items, 0) catch return null;
    if (n == 0) return null;

    for (poll_fds.items, 0..) |pfd, i| {
        if (pfd.revents & std.posix.POLL.IN != 0) {
            return uids.items[i];
        }
    }
    return null;
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

// ─── Internal ─────────────────────────────────────────────────────────

fn spawnWorker(self: *WorkerManager, uid: u32, catatonit_pid: std.posix.pid_t) !void {
    const uid_str = try std.fmt.allocPrint(self.allocator, "{d}", .{uid});
    defer self.allocator.free(uid_str);

    const pid_str = try std.fmt.allocPrint(self.allocator, "{d}", .{catatonit_pid});
    defer self.allocator.free(pid_str);

    // Resolve UID to username for worker ACL loading
    const username = user_mod.getUsername(self.allocator, uid) orelse {
        log.err("Failed to resolve uid={d} to username, cannot spawn worker", .{uid});
        return error.UserNotFound;
    };
    defer self.allocator.free(username);

    // Scope unit name: net-porter-worker@<uid>.scope
    const scope_name = try std.fmt.allocPrint(self.allocator, "net-porter-worker@{d}.scope", .{uid});
    defer self.allocator.free(scope_name);

    // Build argv: systemd-run --scope --unit=<scope> /proc/self/exe worker ...
    var argv = std.ArrayList([]const u8).initCapacity(self.allocator, 16) catch return error.OutOfMemory;
    defer argv.deinit(self.allocator);

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

    if (self.config_path) |cp| {
        argv.appendAssumeCapacity("--config");
        argv.appendAssumeCapacity(cp);
    }

    const process = std.process.spawn(self.io, .{
        .argv = argv.items,
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
    // systemd places the main process PID in the scope's cgroup.procs.
    const worker_pid = self.findScopeWorkerPid(uid) catch |err| blk: {
        log.warn("Failed to find worker PID for uid={d}: {s}, falling back to systemd-run pid", .{ uid, @errorName(err) });
        break :blk systemd_run_pid;
    };

    // Create pidfd for monitoring
    const pidfd_rc = linux.pidfd_open(worker_pid, 0);
    const worker_pidfd: std.posix.fd_t = if (std.posix.errno(pidfd_rc) == .SUCCESS)
        @intCast(pidfd_rc)
    else
        -1;

    const entry = WorkerEntry{
        .uid = uid,
        .pid = worker_pid,
        .pidfd = worker_pidfd,
        .catatonit_pid = catatonit_pid,
    };

    try self.workers.put(uid, entry);
    log.info("Spawned worker for uid={d} (username={s}, pid={d}, scope={s}, catatonit_pid={d})", .{ uid, username, worker_pid, scope_name, catatonit_pid });
}

/// Stop an existing worker scope via systemctl and clean up tracking entry.
fn stopAndCleanup(self: *WorkerManager, uid: u32) void {
    if (self.workers.fetchRemove(uid)) |removed| {
        if (removed.value.pidfd >= 0) {
            _ = linux.close(removed.value.pidfd);
        }
    }
    self.stopScope(uid);
}

/// Stop a worker scope via systemctl.
fn stopScope(self: *WorkerManager, uid: u32) void {
    const scope_name = std.fmt.allocPrint(self.allocator, "net-porter-worker@{d}.scope", .{uid}) catch return;
    defer self.allocator.free(scope_name);

    // Use systemctl to stop the scope (sends SIGTERM to all processes in scope)
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
/// Checks if a scope is active and if so, tracks the worker PID.
/// Returns true if an active worker was found and adopted.
fn tryAdoptExistingScope(self: *WorkerManager, uid: u32, catatonit_pid: std.posix.pid_t) bool {
    const scope_name = std.fmt.allocPrint(self.allocator, "net-porter-worker@{d}.scope", .{uid}) catch return false;
    defer self.allocator.free(scope_name);

    // Check if scope is active by reading cgroup.procs
    const worker_pid = self.findScopeWorkerPid(uid) catch return false;

    // Verify the worker is still alive
    const pidfd_rc = linux.pidfd_open(worker_pid, 0);
    const worker_pidfd: std.posix.fd_t = if (std.posix.errno(pidfd_rc) == .SUCCESS)
        @intCast(pidfd_rc)
    else
        return false;

    const entry = WorkerEntry{
        .uid = uid,
        .pid = worker_pid,
        .pidfd = worker_pidfd,
        .catatonit_pid = catatonit_pid,
    };

    self.workers.put(uid, entry) catch {
        _ = linux.close(worker_pidfd);
        return false;
    };

    log.info("Adopted existing worker for uid={d} (pid={d}, scope={s})", .{ uid, worker_pid, scope_name });
    return true;
}

/// Find the worker PID by reading the scope's cgroup.procs file.
fn findScopeWorkerPid(self: *WorkerManager, uid: u32) !std.posix.pid_t {
    // cgroup v2 path: /sys/fs/cgroup/system.slice/net-porter-worker@<uid>.scope/cgroup.procs
    const path = try std.fmt.allocPrint(self.allocator, "/sys/fs/cgroup/system.slice/net-porter-worker@{d}.scope/cgroup.procs", .{uid});
    defer self.allocator.free(path);

    // Wait briefly for the scope to appear (systemd-run needs time to create it)
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
fn readFirstPid(self: *WorkerManager, path: []const u8) ?std.posix.pid_t {
    var file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch return null;
    defer file.close(self.io);

    var buf: [64]u8 = undefined;
    var reader = file.reader(self.io, &buf);
    const data = reader.interface.allocRemaining(std.heap.page_allocator, .limited(64)) catch return null;
    defer std.heap.page_allocator.free(data);

    const line = std.mem.trim(u8, data, " \t\r\n");
    if (line.len == 0) return null;
    const first_line = if (std.mem.indexOf(u8, line, "\n")) |idx| line[0..idx] else line;
    return std.fmt.parseUnsigned(std.posix.pid_t, first_line, 10) catch null;
}

/// Discover the catatonit PID for a given UID by scanning /proc directly.
/// Uses statx on /proc/<pid> directories to check ownership (UID), and
/// reads /proc/<pid>/comm for the process name (kernel-provided, not spoofable).
/// This avoids trusting an external `pgrep` binary which could be replaced.
fn discoverCatatonitPid(io: std.Io, uid: u32) ?std.posix.pid_t {
    var proc_dir = std.Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true }) catch {
        log.warn("discoverCatatonitPid: failed to open /proc", .{});
        return null;
    };
    defer proc_dir.close(io);

    var iter = proc_dir.iterate();

    while (iter.next(io) catch null) |entry| {
        // NOTE: Do NOT check entry.kind — /proc may report DT_UNKNOWN for
        // d_type, making entry.kind = .unknown and filtering out ALL entries.
        // isAllDigits is sufficient to filter PID directory entries.
        if (!isAllDigits(entry.name)) continue;

        const pid = std.fmt.parseUnsigned(std.posix.pid_t, entry.name, 10) catch continue;

        // Check process UID via statx on /proc/<pid> directory
        if (!checkProcessUidByStat(pid, uid)) continue;

        // Check process name from /proc/<pid>/comm (kernel-provided, not argv)
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
/// In /proc, PID directories are owned by the process's effective UID.
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
/// The comm field comes from the kernel (task_struct->comm), set from the
/// binary's filename — not spoofable via argv or command-line arguments.
fn isCatatonit(io: std.Io, pid: std.posix.pid_t) bool {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch return false;

    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);

    var read_buf: [64]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    const data = reader.interface.allocRemaining(std.heap.page_allocator, .limited(64)) catch return false;
    defer std.heap.page_allocator.free(data);

    const name = std.mem.trim(u8, data, " \t\r\n");
    return std.mem.eql(u8, name, "catatonit");
}

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
    // UID 999999 is very unlikely to have a running catatonit process
    const result = discoverCatatonitPid(std.testing.io, 999999);
    try std.testing.expect(result == null);
}

test "checkProcessUidByStat reads /proc/<pid> ownership" {
    // Our own process should have a valid /proc/<pid> directory
    const own_pid: std.posix.pid_t = @intCast(std.os.linux.getpid());
    // Verify the function doesn't crash and returns a boolean
    _ = checkProcessUidByStat(own_pid, 0); // Likely false unless running as root
    _ = checkProcessUidByStat(own_pid, std.math.maxInt(u32)); // Definitely false
}

test "isCatatonit returns false for current process" {
    // The test runner is not catatonit
    const own_pid: std.posix.pid_t = @intCast(std.os.linux.getpid());
    try std.testing.expect(!isCatatonit(std.testing.io, own_pid));
}
