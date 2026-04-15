const std = @import("std");
const Allocator = std.mem.Allocator;
const DhcpService = @This();
const log = std.log.scoped(.dhcpServer);

allocator: Allocator,
io: std.Io,
caller_uid: std.posix.uid_t,
dhcp_cni_path: []const u8,
sock_path: []const u8,
podman_infra_pid: ?[]const u8 = null,
process: ?std.process.Child = null,
mutex: std.Io.Mutex = .init,

pub fn init(io: std.Io, allocator: Allocator, caller_uid: std.posix.uid_t, cni_path: []const u8) !DhcpService {
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
    {
        self.mutex.lock(self.io) catch unreachable;
        defer self.mutex.unlock(self.io);

        self.stop();
    }

    self.removeSocketPath();

    if (self.podman_infra_pid) |pid| {
        self.allocator.free(pid);
    }

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
    // Always re-discover infra PID - it may have changed
    // after podman session restart
    if (self.podman_infra_pid) |old_pid| {
        self.allocator.free(old_pid);
        self.podman_infra_pid = null;
    }
    try self.initPodmanInfraPid();

    self.removeSocketPath();

    self.process = std.process.spawn(self.io, .{
        .argv = &[_][]const u8{
            "nsenter",
            "-t",
            self.podman_infra_pid.?,
            "--mount",
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
        std.posix.kill(process.id.?, @enumFromInt(0)) catch |err| switch (err) {
            error.ProcessNotFound => return false,
            else => {
                log.warn("Failed to check if DHCP service is alive: {s}", .{@errorName(err)});
                return false;
            },
        };
        return true;
    }
    return false;
}

fn stop(self: *DhcpService) void {
    if (self.process) |*process| {
        process.kill(self.io);
        _ = process.wait(self.io) catch |err| {
            log.warn("Failed to wait for DHCP service to stop: {s}", .{@errorName(err)});
            return;
        };
        self.process = null;
    }
}

fn waitSocketPathCreated(self: DhcpService, comptime max_wait: comptime_int) void {
    var i: usize = 0;
    while (i < max_wait) : (i += 1) {
        const f = std.Io.Dir.cwd().openFile(self.io, self.sock_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                var req: std.os.linux.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
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

pub const InitPodmanInfraPidError = error{
    FailedToGetPodmanInfraPid,
};

fn initPodmanInfraPid(self: *DhcpService) InitPodmanInfraPidError!void {
    const uid = std.fmt.allocPrint(self.allocator, "{d}", .{self.caller_uid}) catch {
        return error.FailedToGetPodmanInfraPid;
    };
    defer self.allocator.free(uid);

    const p = std.process.run(self.allocator, self.io, .{
        .argv = &[_][]const u8{
            "pgrep",
            "-u",
            uid,
            "-f",
            "catatonit",
        },
    }) catch |err| {
        log.warn("Failed to get podman infra pid: {s}", .{@errorName(err)});
        return error.FailedToGetPodmanInfraPid;
    };
    defer self.allocator.free(p.stdout);
    defer self.allocator.free(p.stderr);

    // strip the stdout to get the pid
    const pid = std.mem.trim(u8, p.stdout, " \t\r\n");
    if (pid.len == 0) {
        log.warn("Failed to get podman infra pid: {s}", .{p.stderr});
        return error.FailedToGetPodmanInfraPid;
    }

    self.podman_infra_pid = self.allocator.dupe(u8, pid) catch |err| {
        log.warn("Failed to get podman infra pid: {s}", .{@errorName(err)});
        return error.FailedToGetPodmanInfraPid;
    };
}
