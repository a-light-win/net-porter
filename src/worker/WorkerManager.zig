//! Worker lifecycle manager — runs in the main server process.
//!
//! Responsible for:
//!   - Spawning worker processes: `net-porter worker --uid <UID> --username <name> ...`
//!   - Monitoring worker health via pidfd
//!   - Restarting workers when catatonit PID changes
//!   - Stopping workers when UID disappears or ACL removes access
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
    // Stop all workers
    var it = self.workers.iterator();
    while (it.next()) |entry| {
        self.killWorker(entry.value_ptr.*);
    }
    self.workers.deinit();
}

/// Ensure a worker is running for the given UID.
/// Discovers the catatonit PID and spawns a worker if needed.
/// If the catatonit PID has changed, restarts the worker.
pub fn ensureWorker(self: *WorkerManager, uid: u32) !void {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);

    const catatonit_pid = discoverCatatonitPid(self.io, uid) orelse {
        log.warn("No catatonit process found for uid={d}, skipping worker start", .{uid});
        return;
    };

    if (self.workers.get(uid)) |existing| {
        if (existing.catatonit_pid == catatonit_pid) {
            // Worker already running with correct catatonit PID
            log.debug("Worker already running for uid={d} (pid={d})", .{ uid, existing.pid });
            return;
        }
        // Catatonit PID changed — restart worker
        log.info("Catatonit PID changed for uid={d}: {d} → {d}, restarting worker", .{ uid, existing.catatonit_pid, catatonit_pid });
        self.killWorker(existing);
        _ = self.workers.remove(uid);
    }

    self.spawnWorker(uid, catatonit_pid) catch |err| {
        log.err("Failed to spawn worker for uid={d}: {s}", .{ uid, @errorName(err) });
        return err;
    };
}

/// Stop the worker for the given UID (if running).
pub fn stopWorker(self: *WorkerManager, uid: u32) void {
    self.mutex.lock(self.io) catch return;
    defer self.mutex.unlock(self.io);

    if (self.workers.fetchRemove(uid)) |removed| {
        self.killWorker(removed.value);
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

    // Build argv: /proc/self/exe worker --uid <uid> --username <name> --catatonit-pid <pid> [--config <path>]
    var argv = std.ArrayList([]const u8).initCapacity(self.allocator, 10) catch return error.OutOfMemory;
    defer argv.deinit(self.allocator);

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
        log.err("Failed to spawn worker process: {s}", .{@errorName(err)});
        return err;
    };

    const worker_pid: std.posix.pid_t = @intCast(process.id.?);

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
    log.info("Spawned worker for uid={d} (username={s}, pid={d}, catatonit_pid={d})", .{ uid, username, worker_pid, catatonit_pid });
}

fn killWorker(self: *WorkerManager, entry: WorkerEntry) void {
    _ = self;
    // Close pidfd first
    if (entry.pidfd >= 0) {
        _ = linux.close(entry.pidfd);
    }
    // Send SIGTERM for graceful shutdown
    std.posix.kill(entry.pid, std.posix.SIG.TERM) catch {};
    // Wait for process to exit (with timeout)
    var status: u32 = 0;
    _ = linux.wait4(entry.pid, &status, 1, null); // WNOHANG = 1
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
