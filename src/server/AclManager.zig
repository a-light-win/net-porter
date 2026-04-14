const std = @import("std");
const Acl = @import("Acl.zig");
const Config = @import("../config.zig").Config;
const ArenaAllocator = @import("../utils/ArenaAllocator.zig");
const Allocator = std.mem.Allocator;
const AclManager = @This();

arena: ArenaAllocator,
acls: ?std.ArrayList(Acl) = null,

pub fn init(root_allocator: Allocator, config: Config) !AclManager {
    var arena = try ArenaAllocator.init(root_allocator);
    errdefer arena.deinit();

    var acl_manager = AclManager{
        .arena = arena,
    };

    const allocator = arena.allocator();
    if (config.resources) |resources| {
        if (acl_manager.acls == null) {
            acl_manager.acls = try std.ArrayList(Acl).initCapacity(allocator, resources.len);
        }
        for (resources) |resource| {
            var acl = try Acl.fromResource(allocator, resource);
            if (!acl.hasAnyAllow()) {
                std.log.err("Resource '{s}' has no allow_users or allow_groups configured. Each resource must have at least one ACL rule for security.", .{resource.name});
                acl.deinit();
                return error.ResourceMissingAcl;
            }
            try acl_manager.acls.?.append(allocator, acl);
        }
    }
    return acl_manager;
}

pub fn deinit(self: *AclManager) void {
    const allocator = self.arena.allocator();
    if (self.acls) |*acls| {
        for (acls.items) |*acl| {
            acl.deinit();
        }
        acls.deinit(allocator);
    }

    self.arena.deinit();
}

pub fn isAllowed(self: AclManager, name: []const u8, uid: u32, gid: u32) bool {
    if (self.acls) |acls| {
        for (acls.items) |acl| {
            if (std.mem.eql(u8, name, acl.name)) {
                return acl.isAllowed(uid, gid);
            }
        }
    }
    return false;
}

/// Check if a uid has permission to access any resource.
/// Used for socket-level pre-filtering.
pub fn hasAnyPermission(self: AclManager, uid: u32, gid: u32) bool {
    if (self.acls) |acls| {
        for (acls.items) |acl| {
            if (acl.isAllowed(uid, gid)) {
                return true;
            }
        }
    }
    return false;
}

/// Collect all distinct uids that have permission on any resource.
/// Used by SocketManager to know which /run/user/<uid>/ directories to watch.
pub fn allAllowedUids(self: AclManager, allocator: Allocator) !std.ArrayList(u32) {
    var uid_set = std.AutoHashMap(u32, void).init(allocator);
    defer uid_set.deinit();

    if (self.acls) |acls| {
        for (acls.items) |acl| {
            for (acl.allow_uids.items) |uid| {
                try uid_set.put(uid, {});
            }
            // Also collect uids from ip_ranges (static resources)
            var ip_it = acl.ip_ranges.keyIterator();
            while (ip_it.next()) |uid| {
                try uid_set.put(uid.*, {});
            }
        }
    }

    var result = try std.ArrayList(u32).initCapacity(allocator, uid_set.count());
    var iter = uid_set.keyIterator();
    while (iter.next()) |uid| {
        result.appendAssumeCapacity(uid.*);
    }
    return result;
}

/// Check if a resource is a static IP resource (has IP constraints).
pub fn isStaticResource(self: AclManager, name: []const u8) bool {
    if (self.acls) |acls| {
        for (acls.items) |acl| {
            if (std.mem.eql(u8, name, acl.name)) {
                return acl.isStatic();
            }
        }
    }
    return false;
}

/// Check if a uid is allowed to use the given IP on the specified resource.
pub fn isIpAllowed(self: AclManager, name: []const u8, uid: u32, ip: []const u8) bool {
    if (self.acls) |acls| {
        for (acls.items) |acl| {
            if (std.mem.eql(u8, name, acl.name)) {
                return acl.isIpAllowed(uid, ip);
            }
        }
    }
    return false;
}

test "isAllowed" {
    const Resource = @import("../config.zig").Resource;
    const allocator = std.testing.allocator;
    var runtime = try init(allocator, Config{
        .resources = &[_]Resource{
            Resource{
                .name = "test",
                .interface = .{ .type = "macvlan", .master = "eth0" },
                .ipam = .{ .type = "dhcp" },
                .acl = &[_]Resource.Grant{
                    .{ .user = "root" },
                },
            },
        },
    });
    defer runtime.deinit();

    try std.testing.expect(runtime.isAllowed("test", 0, 0));
    try std.testing.expect(!runtime.isAllowed("test", 333, 0));
    try std.testing.expect(!runtime.isAllowed("not-exists", 0, 0));
}

test "hasAnyPermission" {
    const Resource = @import("../config.zig").Resource;
    const allocator = std.testing.allocator;
    var runtime = try init(allocator, Config{
        .resources = &[_]Resource{
            Resource{
                .name = "net-a",
                .interface = .{ .type = "macvlan", .master = "eth0" },
                .ipam = .{ .type = "dhcp" },
                .acl = &[_]Resource.Grant{
                    .{ .user = "root" },
                },
            },
            Resource{
                .name = "net-b",
                .interface = .{ .type = "macvlan", .master = "eth0" },
                .ipam = .{ .type = "dhcp" },
                .acl = &[_]Resource.Grant{
                    .{ .group = "999" },
                },
            },
        },
    });
    defer runtime.deinit();

    try std.testing.expect(runtime.hasAnyPermission(0, 0));
    try std.testing.expect(!runtime.hasAnyPermission(333, 0));
    try std.testing.expect(runtime.hasAnyPermission(100, 999));
}

test "init rejects resource without ACL" {
    const Resource = @import("../config.zig").Resource;
    const allocator = std.testing.allocator;
    const result = init(allocator, Config{
        .resources = &[_]Resource{
            Resource{
                .name = "insecure",
                .interface = .{ .type = "macvlan", .master = "eth0" },
                .ipam = .{ .type = "dhcp" },
                .acl = &[_]Resource.Grant{},
            },
        },
    });
    try std.testing.expectError(error.ResourceMissingAcl, result);
}

test "isStaticResource and isIpAllowed" {
    const Resource = @import("../config.zig").Resource;
    const allocator = std.testing.allocator;
    var runtime = try init(allocator, Config{
        .resources = &[_]Resource{
            Resource{
                .name = "dhcp-net",
                .interface = .{ .type = "macvlan", .master = "eth0" },
                .ipam = .{ .type = "dhcp" },
                .acl = &[_]Resource.Grant{
                    .{ .user = "1000" },
                },
            },
            Resource{
                .name = "static-net",
                .interface = .{ .type = "macvlan", .master = "eth0" },
                .ipam = .{ .type = "static" },
                .acl = &[_]Resource.Grant{
                    .{ .user = "1000", .ips = &[_][:0]const u8{"192.168.1.10-192.168.1.20"} },
                },
            },
        },
    });
    defer runtime.deinit();

    try std.testing.expect(!runtime.isStaticResource("dhcp-net"));
    try std.testing.expect(runtime.isStaticResource("static-net"));
    try std.testing.expect(!runtime.isStaticResource("not-exists"));

    try std.testing.expect(runtime.isIpAllowed("static-net", 1000, "192.168.1.15"));
    try std.testing.expect(!runtime.isIpAllowed("static-net", 1000, "192.168.1.30"));
    try std.testing.expect(!runtime.isIpAllowed("static-net", 1001, "192.168.1.15"));
    try std.testing.expect(!runtime.isIpAllowed("dhcp-net", 1000, "192.168.1.15"));
}

test "allAllowedUids collects uids from both dhcp and static resources" {
    const Resource = @import("../config.zig").Resource;
    const allocator = std.testing.allocator;
    var runtime = try init(allocator, Config{
        .resources = &[_]Resource{
            Resource{
                .name = "dhcp-net",
                .interface = .{ .type = "macvlan", .master = "eth0" },
                .ipam = .{ .type = "dhcp" },
                .acl = &[_]Resource.Grant{
                    .{ .user = "1000" },
                },
            },
            Resource{
                .name = "static-net",
                .interface = .{ .type = "macvlan", .master = "eth0" },
                .ipam = .{ .type = "static" },
                .acl = &[_]Resource.Grant{
                    .{ .user = "2000", .ips = &[_][:0]const u8{"10.0.0.5-10.0.0.10"} },
                },
            },
        },
    });
    defer runtime.deinit();

    var uids = try runtime.allAllowedUids(allocator);
    defer uids.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), uids.items.len);
    // Both 1000 and 2000 should be present (order not guaranteed)
    var found_1000 = false;
    var found_2000 = false;
    for (uids.items) |uid| {
        if (uid == 1000) found_1000 = true;
        if (uid == 2000) found_2000 = true;
    }
    try std.testing.expect(found_1000);
    try std.testing.expect(found_2000);
}

test "allAllowedUids deduplicates uid across resources" {
    const Resource = @import("../config.zig").Resource;
    const allocator = std.testing.allocator;
    var runtime = try init(allocator, Config{
        .resources = &[_]Resource{
            Resource{
                .name = "dhcp-net",
                .interface = .{ .type = "macvlan", .master = "eth0" },
                .ipam = .{ .type = "dhcp" },
                .acl = &[_]Resource.Grant{
                    .{ .user = "1000" },
                },
            },
            Resource{
                .name = "static-net",
                .interface = .{ .type = "macvlan", .master = "eth0" },
                .ipam = .{ .type = "static" },
                .acl = &[_]Resource.Grant{
                    .{ .user = "1000", .ips = &[_][:0]const u8{"10.0.0.5-10.0.0.10"} },
                },
            },
        },
    });
    defer runtime.deinit();

    var uids = try runtime.allAllowedUids(allocator);
    defer uids.deinit(allocator);

    // uid 1000 appears in both resources but should be deduplicated
    try std.testing.expectEqual(@as(usize, 1), uids.items.len);
    try std.testing.expectEqual(@as(u32, 1000), uids.items[0]);
}

test "allAllowedUids with null resources returns empty" {
    const allocator = std.testing.allocator;
    var runtime = try init(allocator, Config{
        .resources = null,
    });
    defer runtime.deinit();

    var uids = try runtime.allAllowedUids(allocator);
    defer uids.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), uids.items.len);
}

test "isIpAllowed scoped to correct resource" {
    const Resource = @import("../config.zig").Resource;
    const allocator = std.testing.allocator;
    var runtime = try init(allocator, Config{
        .resources = &[_]Resource{
            Resource{
                .name = "static-a",
                .interface = .{ .type = "macvlan", .master = "eth0" },
                .ipam = .{ .type = "static" },
                .acl = &[_]Resource.Grant{
                    .{ .user = "1000", .ips = &[_][:0]const u8{"10.0.0.5-10.0.0.10"} },
                },
            },
            Resource{
                .name = "static-b",
                .interface = .{ .type = "macvlan", .master = "eth0" },
                .ipam = .{ .type = "static" },
                .acl = &[_]Resource.Grant{
                    .{ .user = "1000", .ips = &[_][:0]const u8{"192.168.1.5-192.168.1.10"} },
                },
            },
        },
    });
    defer runtime.deinit();

    // Same uid, different ranges on different resources
    try std.testing.expect(runtime.isIpAllowed("static-a", 1000, "10.0.0.7"));
    try std.testing.expect(!runtime.isIpAllowed("static-a", 1000, "192.168.1.7"));

    try std.testing.expect(!runtime.isIpAllowed("static-b", 1000, "10.0.0.7"));
    try std.testing.expect(runtime.isIpAllowed("static-b", 1000, "192.168.1.7"));

    // Non-existent resource
    try std.testing.expect(!runtime.isIpAllowed("not-exists", 1000, "10.0.0.7"));
}
