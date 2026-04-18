//! Worker lifecycle manager — runs in the main server process.
//!
//! Responsible for:
//!   - Spawning worker processes: `net-porter worker --uid <UID> --catatonit-pid <PID> ...`
//!   - Monitoring worker health via pidfd
//!   - Restarting workers when catatonit PID changes
//!   - Stopping workers when UID disappears or ACL removes access
//!
//! Uses pidfd for efficient process monitoring (no polling).

const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const log = std.log.scoped(.worker_manager);
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

    // Build argv: /proc/self/exe worker --uid <uid> --catatonit-pid <pid> [--config <path>]
    var argv = std.ArrayList([]const u8).initCapacity(self.allocator, 8) catch return error.OutOfMemory;
    defer argv.deinit(self.allocator);

    argv.appendAssumeCapacity("/proc/self/exe");
    argv.appendAssumeCapacity("worker");
    argv.appendAssumeCapacity("--uid");
    argv.appendAssumeCapacity(uid_str);
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
    log.info("Spawned worker for uid={d} (pid={d}, catatonit_pid={d})", .{ uid, worker_pid, catatonit_pid });
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

/// Discover the catatonit PID for a given UID using pgrep.
fn discoverCatatonitPid(io: std.Io, uid: u32) ?std.posix.pid_t {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const uid_str = std.fmt.allocPrint(allocator, "{d}", .{uid}) catch return null;
    defer allocator.free(uid_str);

    const result = std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "pgrep", "-u", uid_str, "-f", "catatonit" },
    }) catch {
        log.warn("pgrep catatonit failed for uid={d}", .{uid});
        return null;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const pid_str = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (pid_str.len == 0) return null;

    // Only take the first PID if multiple lines
    const first_line = if (std.mem.indexOf(u8, pid_str, "\n")) |idx| pid_str[0..idx] else pid_str;
    return std.fmt.parseUnsigned(std.posix.pid_t, first_line, 10) catch null;
}
