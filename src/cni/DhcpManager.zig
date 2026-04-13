const std = @import("std");
const Allocator = std.mem.Allocator;
const DhcpService = @import("DhcpService.zig");
const DhcpManager = @This();
const log = std.log.scoped(.dhcpManager);

allocator: Allocator,
cni_plugin_dir: []const u8,
mutex: std.Thread.Mutex,
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

pub fn init(allocator: Allocator, cni_plugin_dir: []const u8) DhcpManager {
    return DhcpManager{
        .allocator = allocator,
        .cni_plugin_dir = cni_plugin_dir,
        .mutex = .{},
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
    self.mutex.lock();
    defer self.mutex.unlock();

    const result = try self.services.getOrPut(uid);
    if (!result.found_existing) {
        const svc = try self.allocator.create(DhcpService);
        svc.* = try DhcpService.init(self.allocator, uid, self.cni_plugin_dir);
        result.value_ptr.* = svc;
        log.info("Created DHCP service for uid={d}", .{uid});
    }
    try result.value_ptr.*.*.ensureStarted();
}
