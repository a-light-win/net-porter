const std = @import("std");
const Allocator = std.mem.Allocator;
const DhcpService = @import("DhcpService.zig");
const DhcpManager = @This();
const log = std.log.scoped(.dhcpManager);

allocator: Allocator,
io: std.Io,
cni_plugin_dir: []const u8,
mutex: std.Io.Mutex = .init,
services: ServiceMap,

const ServiceMap = std.HashMap(u32, *DhcpService, ServiceMapContext, 80);

const ServiceMapContext = struct {
    pub fn hash(self: ServiceMapContext, uid: u32) u64 {
        _ = self;
        return std.hash.int(uid);
    }
    pub fn eql(self: ServiceMapContext, a: u32, b: u32) bool {
        _ = self;
        return a == b;
    }
};

pub fn init(io: std.Io, allocator: Allocator, cni_plugin_dir: []const u8) DhcpManager {
    return DhcpManager{
        .allocator = allocator,
        .io = io,
        .cni_plugin_dir = cni_plugin_dir,
        .services = ServiceMap.init(allocator),
    };
}

pub fn deinit(self: *DhcpManager) void {
    var it = self.services.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.*.*.deinit();
        self.allocator.destroy(entry.value_ptr.*);
    }
    self.services.deinit();
}

pub fn ensureStarted(self: *DhcpManager, uid: u32) !void {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);

    const result = try self.services.getOrPut(uid);
    if (!result.found_existing) {
        const svc = try self.allocator.create(DhcpService);
        errdefer self.allocator.destroy(svc);
        svc.* = try DhcpService.init(self.io, self.allocator, uid, self.cni_plugin_dir);
        result.value_ptr.* = svc;
        log.info("Created DHCP service for uid={d}", .{uid});
    }
    try result.value_ptr.*.*.ensureStarted();
}

/// Stop and remove the DHCP service for the given uid.
/// Safe to call even if no service exists for this uid.
pub fn stop(self: *DhcpManager, uid: u32) void {
    self.mutex.lock(self.io) catch return;
    defer self.mutex.unlock(self.io);

    if (self.services.fetchRemove(uid)) |removed| {
        removed.value.deinit();
        self.allocator.destroy(removed.value);
        log.info("Stopped DHCP service for uid={d}", .{uid});
    }
}
