const std = @import("std");
const Allocator = std.mem.Allocator;
const DhcpService = @This();

allocator: Allocator,
ns_pid: []const u8,
bin_path: [:0]u8,
name: [:0]u8,
socket_path: []const u8,

pub fn init(allocator: Allocator, ns_pid: []const u8, container_id: []const u8, cni_path: []const u8, socket_path: []const u8) !DhcpService {
    const bin_path = try std.fmt.allocPrintZ(allocator, "{s}/dhcp", .{cni_path});
    const name = try std.fmt.allocPrintZ(allocator, "dhcp@{s}", .{container_id});

    return DhcpService{
        .allocator = allocator,
        .ns_pid = ns_pid,
        .bin_path = bin_path,
        .name = name,
        .socket_path = socket_path,
    };
}

pub fn deinit(self: DhcpService) void {
    self.allocator.free(self.bin_path);
    self.allocator.free(self.name);
}

fn startCmd(self: DhcpService) []const []const u8 {
    return &[_][]const u8{
        "systemd-run",
        "--slice",
        "net-porter",
        "--unit",
        self.name,
        "nsenter",
        "-t",
        self.ns_pid,
        "--mount",
        self.bin_path,
        "daemon",
        "-socketpath",
        self.socket_path,
    };
}

fn stopCmd(self: DhcpService) []const []const u8 {
    return &[_][]const u8{
        "systemctl",
        "stop",
        self.name,
    };
}

pub fn start(self: DhcpService) !std.process.Child.RunResult {
    // TODO: process result here?
    return try std.process.Child.run(.{
        .allocator = self.allocator,
        .argv = self.startCmd(),
    });
}

pub fn stop(self: DhcpService) !std.process.Child.RunResult {
    // Ensure systemd service file is removed after stopping
    const service_path = try std.fmt.allocPrintZ(self.allocator, "/run/systemd/transient/{s}.service", .{self.name});
    defer {
        std.fs.cwd().deleteFile(service_path) catch {};
        self.allocator.free(service_path);
    }

    // TODO: process result here?
    return try std.process.Child.run(.{
        .allocator = self.allocator,
        .argv = self.stopCmd(),
    });
}
