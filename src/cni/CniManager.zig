const std = @import("std");
const Cni = @import("Cni.zig");
const Config = @import("../config.zig").Config;
const Resource = @import("../config.zig").Resource;
const Allocator = std.mem.Allocator;
const ArenaAllocator = @import("../utils/ArenaAllocator.zig");

const CniMap = std.StringHashMap(*Cni);
const CniManager = @This();

arena: ArenaAllocator,
cni_plugin_dir: []const u8,
resources: []const Resource,
cni_plugins: CniMap,

mutex: std.Thread.Mutex = std.Thread.Mutex{},

pub fn init(root_allocator: Allocator, config: Config) Allocator.Error!CniManager {
    var arena = try ArenaAllocator.init(root_allocator);
    errdefer arena.deinit();

    const resources = config.resources orelse &[_]Resource{};

    return CniManager{
        .arena = arena,
        .cni_plugin_dir = config.cni_plugin_dir,
        .resources = resources,
        .cni_plugins = CniMap.init(arena.allocator()),
    };
}

pub fn deinit(self: *CniManager) void {
    var plugin_it = self.cni_plugins.valueIterator();
    while (plugin_it.next()) |plugin| {
        plugin.*.deinit();
    }
    self.cni_plugins.deinit();

    self.arena.deinit();
}

pub fn loadCni(self: *CniManager, name: []const u8) !*Cni {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.cni_plugins.get(name)) |plugin| {
        return plugin;
    }

    // Find resource by name
    const resource = self.findResource(name) orelse {
        std.log.warn("Resource '{s}' not found in config", .{name});
        return error.ResourceNotFound;
    };

    const allocator = self.arena.allocator();

    const cni = try Cni.init(self.arena.childAllocator(), resource, self.cni_plugin_dir);
    errdefer cni.deinit();

    try self.cni_plugins.put(try allocator.dupe(u8, name), cni);
    return cni;
}

fn findResource(self: CniManager, name: []const u8) ?Resource {
    for (self.resources) |resource| {
        if (std.mem.eql(u8, resource.name, name)) {
            return resource;
        }
    }
    return null;
}

test "CniManager: findResource returns matching resource" {
    const allocator = std.testing.allocator;
    const config = Config{
        .resources = &[_]Resource{
            Resource{
                .name = "net-a",
                .interface = .{ .type = "macvlan", .master = "eth0" },
                .ipam = .{ .dhcp = .{} },
                .acl = &[_]Resource.Grant{
                    .{ .user = "1000" },
                },
            },
            Resource{
                .name = "net-b",
                .interface = .{ .type = "macvlan", .master = "eth1" },
                .ipam = .{ .dhcp = .{} },
                .acl = &[_]Resource.Grant{
                    .{ .user = "2000" },
                },
            },
        },
    };

    var manager = try init(allocator, config);
    defer manager.deinit();

    const found = manager.findResource("net-a");
    try std.testing.expect(found != null);
    try std.testing.expectEqualSlices(u8, "eth0", found.?.interface.master);

    const found_b = manager.findResource("net-b");
    try std.testing.expect(found_b != null);
    try std.testing.expectEqualSlices(u8, "eth1", found_b.?.interface.master);

    const not_found = manager.findResource("not-exists");
    try std.testing.expect(not_found == null);
}

test "CniManager: loadCni returns ResourceNotFound for unknown resource" {
    const allocator = std.testing.allocator;
    const config = Config{
        .resources = &[_]Resource{
            Resource{
                .name = "net-a",
                .interface = .{ .type = "macvlan", .master = "eth0" },
                .ipam = .{ .dhcp = .{} },
                .acl = &[_]Resource.Grant{
                    .{ .user = "1000" },
                },
            },
        },
    };

    var manager = try init(allocator, config);
    defer manager.deinit();

    const result = manager.loadCni("not-exists");
    try std.testing.expectError(error.ResourceNotFound, result);
}

test "CniManager: loadCni with null resources returns ResourceNotFound" {
    const allocator = std.testing.allocator;
    const config = Config{
        .resources = null,
    };

    var manager = try init(allocator, config);
    defer manager.deinit();

    const result = manager.loadCni("anything");
    try std.testing.expectError(error.ResourceNotFound, result);
}
