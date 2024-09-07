const std = @import("std");
const Allocator = std.mem.Allocator;
const DhcpService = @This();

allocator: Allocator,
caller_uid: std.posix.uid_t,
name: [:0]u8,
sock_path: [:0]const u8,

pub fn init(allocator: Allocator, caller_uid: std.posix.uid_t) !DhcpService {
    const name = try std.fmt.allocPrintZ(
        allocator,
        "net-porter-dhcp@{d}",
        .{caller_uid},
    );
    errdefer allocator.free(name);

    const dhcp_sock_path = try std.fmt.allocPrintZ(
        allocator,
        "/run/user/{d}/net-porter/dhcp.sock",
        .{caller_uid},
    );
    errdefer allocator.free(dhcp_sock_path);

    return DhcpService{
        .allocator = allocator,
        .caller_uid = caller_uid,
        .name = name,
        .sock_path = dhcp_sock_path,
    };
}

pub fn deinit(self: DhcpService) void {
    self.allocator.free(self.name);
    self.allocator.free(self.sock_path);
}

fn startCmd(self: DhcpService) []const []const u8 {
    return &[_][]const u8{
        "systemctl",
        "start",
        self.name,
    };
}

pub fn start(self: DhcpService, caller_pid: std.posix.pid_t, cni_path: []const u8) !std.process.Child.RunResult {
    var env_map = std.process.EnvMap.init(self.allocator);
    defer env_map.deinit();

    const pid = try std.fmt.printAlloc(self.allocator, "{d}", .{caller_pid});
    defer self.allocator.free(pid);

    try env_map.put("NET_PORTER_CALLER_PID", pid);
    try env_map.put("NET_PORTER_CNI_PATH", cni_path);
    try env_map.put("NET_PORTER_DHCP_SOCK_PATH", self.sock_path);

    // TODO: process result here?
    const result = try std.process.Child.run(.{
        .allocator = self.allocator,
        .argv = self.startCmd(),
        .env_map = env_map,
    });

    switch (result.term) {
        .Exited => |exit_code| if (exit_code != 0) {
            return result;
        },
        else => return result,
    }

    const max_wait = 100 * 5; // wait 5 seconds
    self.waitSocketPathCreated(max_wait);

    return result;
}

pub fn waitSocketPathCreated(self: DhcpService, comptime max_wait: comptime_int) void {
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
