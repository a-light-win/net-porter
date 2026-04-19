const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const DhcpService = @This();
const log = std.log.scoped(.dhcp_service);

allocator: Allocator,
io: std.Io,
caller_uid: std.posix.uid_t,
dhcp_cni_path: []const u8,
sock_path: []const u8,
process: ?std.process.Child = null,
mutex: std.Io.Mutex = .init,

pub fn init(io: std.Io, allocator: Allocator, caller_uid: std.posix.uid_t, cni_path: []const u8) !DhcpService {
    // /run/user/<uid>/ is visible in the worker's namespace via rslave propagation.
    // Each worker is per-UID — no path conflict.
    const dhcp_sock_path = try std.fmt.allocPrint(
        allocator,
        "/run/user/{d}/net-porter-dhcp.sock",
        .{caller_uid},
    );
    errdefer allocator.free(dhcp_sock_path);

    const dhcp_cni_path = try std.fmt.allocPrint(
        allocator,
        "{s}/dhcp",
        .{cni_path},
    );
    errdefer allocator.free(dhcp_cni_path);

    return DhcpService{
        .allocator = allocator,
        .io = io,
        .caller_uid = caller_uid,
        .dhcp_cni_path = dhcp_cni_path,
        .sock_path = dhcp_sock_path,
    };
}

pub fn deinit(self: *DhcpService) void {
    self.mutex.lock(self.io) catch {};
    defer self.mutex.unlock(self.io);
    self.stop();

    self.removeSocketPath();
    self.allocator.free(self.sock_path);
    self.allocator.free(self.dhcp_cni_path);
}

pub fn ensureStarted(self: *DhcpService) !void {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);

    if (!self.isAlive()) {
        try self.start();
    }
}

fn start(self: *DhcpService) !void {
    self.removeSocketPath();

    // Spawn DHCP daemon directly — no nsenter needed.
    // The worker is already in the correct mount namespace.
    self.process = std.process.spawn(self.io, .{
        .argv = &[_][]const u8{
            self.dhcp_cni_path,
            "daemon",
            "-socketpath",
            self.sock_path,
        },
    }) catch |err| {
        self.process = null;
        log.warn("Failed to start DHCP service: {s}", .{@errorName(err)});
        return err;
    };

    const max_wait = 100 * 5; // wait 5 seconds
    self.waitSocketPathCreated(max_wait);
}

    fn isAlive(self: DhcpService) bool {
        if (self.process) |process| {
            const pid = process.id orelse return false;

            // Use waitpid(WNOHANG) instead of kill(pid, 0).
            //
            // kill(pid, 0) returns 0 for zombie processes, causing isAlive()
            // to incorrectly report a crashed daemon as alive. This prevents
            // automatic restart after a crash.
            //
            // waitpid(WNOHANG) is non-blocking:
            //   - returns 0     → process is still running
            //   - returns pid   → process exited (zombie reaped)
            //   - returns -ECHILD → already reaped or not our child
            var status: u32 = 0;
            const rc = linux.wait4(pid, &status, linux.W.NOHANG, null);
            if (rc == 0) return true; // Still running
            // Process exited or error — no longer alive
            return false;
        }
        return false;
    }

fn stop(self: *DhcpService) void {
    if (self.process) |*process| {
        // kill() sends SIGTERM, waits for exit, reaps the child, and
        // sets child.id = null. In Zig 0.16.0, calling wait() after kill()
        // would panic because wait() asserts child.id != null.
        process.kill(self.io);
        self.process = null;
    }
}

fn waitSocketPathCreated(self: DhcpService, comptime max_wait: comptime_int) void {
    var i: usize = 0;
    while (i < max_wait) : (i += 1) {
        const f = std.Io.Dir.cwd().openFile(self.io, self.sock_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                var req: std.posix.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
                _ = std.os.linux.nanosleep(&req, null);
                continue;
            },
            else => return,
        };
        f.close(self.io);
        return;
    }
}

fn removeSocketPath(self: DhcpService) void {
    _ = std.Io.Dir.cwd().deleteFile(self.io, self.sock_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {
            log.warn("Failed to remove {s}: {s}", .{ self.sock_path, @errorName(err) });
        },
    };
}
