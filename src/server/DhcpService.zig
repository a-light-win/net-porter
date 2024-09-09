const std = @import("std");
const Allocator = std.mem.Allocator;
const DhcpService = @This();
const log = std.log.scoped(.dhcpServer);

allocator: Allocator,
caller_uid: std.posix.uid_t,
dhcp_cni_path: []const u8,
sock_path: []const u8,
caller_pid: ?[]const u8 = null,
process: ?std.process.Child = null,
mutex: std.Thread.Mutex = std.Thread.Mutex{},

pub fn init(allocator: Allocator, caller_uid: std.posix.uid_t, cni_path: []const u8) !DhcpService {
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
        .caller_uid = caller_uid,
        .dhcp_cni_path = dhcp_cni_path,
        .sock_path = dhcp_sock_path,
    };
}

pub fn deinit(self: *DhcpService) void {
    {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.stop();
    }

    if (self.caller_pid) |pid| {
        self.allocator.free(pid);
        self.caller_pid = null;
    }

    self.allocator.free(self.sock_path);
    self.allocator.free(self.dhcp_cni_path);
}

pub fn ensureStarted(self: *DhcpService, caller_pid: std.posix.pid_t) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (!self.isAlive()) {
        try self.start(caller_pid);
    }
}

fn start(self: *DhcpService, caller_pid: std.posix.pid_t) !void {
    if (self.caller_pid) |pid| {
        self.allocator.free(pid);
    }
    self.caller_pid = try std.fmt.allocPrint(self.allocator, "{d}", .{caller_pid});

    self.process = std.process.Child.init(
        &[_][]const u8{
            "nsenter",
            "-t",
            self.caller_pid.?,
            "--mount",
            self.dhcp_cni_path,
            "daemon",
            "-socketpath",
            self.sock_path,
        },
        self.allocator,
    );

    self.process.?.spawn() catch |err| {
        self.process = null;
        log.warn("Failed to start DHCP service: {s}", .{@errorName(err)});
        return err;
    };

    const max_wait = 100 * 5; // wait 5 seconds
    self.waitSocketPathCreated(max_wait);
}

fn isAlive(self: DhcpService) bool {
    if (self.process) |process| {
        std.posix.kill(process.id, 0) catch |err| switch (err) {
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
        _ = process.kill() catch |err| {
            log.warn("Failed to stop DHCP service: {s}", .{@errorName(err)});
            return;
        };
        _ = process.wait() catch |err| {
            log.warn("Failed to wait for DHCP service to stop: {s}", .{@errorName(err)});
            return;
        };
        self.process = null;
    }
}

fn waitSocketPathCreated(self: DhcpService, comptime max_wait: comptime_int) void {
    var i: usize = 0;
    while (i < max_wait) : (i += 1) {
        _ = std.posix.fstatat(std.posix.AT.FDCWD, self.sock_path, 0) catch |err| switch (err) {
            error.FileNotFound => {
                std.time.sleep(10 * std.time.ns_per_ms);
                continue;
            },
            else => return,
        };
    }
}
