const std = @import("std");
const testing = std.testing;
const AclManager = @import("AclManager.zig");
const Resource = @import("../config.zig").Resource;
const Config = @import("../config.zig").Config;

test "AclManager: hasAnyPermission - single user allowed on single resource" {
    const allocator = testing.allocator;
    const config = Config{
        .resources = &[_]Resource{
            Resource{
                .name = "vlan-100",
                .interface = .{ .type = "macvlan", .master = "eth0" },
                .ipam = .{ .dhcp = .{} },
                .acl = &[_]Resource.Grant{
                    .{ .user = "1000" },
                },
            },
        },
    };

    var acl_manager = try AclManager.init(allocator, config);
    defer acl_manager.deinit();

    try testing.expect(acl_manager.hasAnyPermission(1000, 1000));
    try testing.expect(!acl_manager.hasAnyPermission(1001, 1001));
}

test "AclManager: hasAnyPermission - group permission" {
    const allocator = testing.allocator;
    const config = Config{
        .resources = &[_]Resource{
            Resource{
                .name = "vlan-100",
                .interface = .{ .type = "macvlan", .master = "eth0" },
                .ipam = .{ .dhcp = .{} },
                .acl = &[_]Resource.Grant{
                    .{ .group = "100" },
                },
            },
        },
    };

    var acl_manager = try AclManager.init(allocator, config);
    defer acl_manager.deinit();

    try testing.expect(acl_manager.hasAnyPermission(1000, 100));
    try testing.expect(!acl_manager.hasAnyPermission(1001, 101));
}

test "AclManager: hasAnyPermission - multiple resources" {
    const allocator = testing.allocator;
    const config = Config{
        .resources = &[_]Resource{
            Resource{
                .name = "vlan-100",
                .interface = .{ .type = "macvlan", .master = "eth0" },
                .ipam = .{ .dhcp = .{} },
                .acl = &[_]Resource.Grant{
                    .{ .user = "1000" },
                },
            },
            Resource{
                .name = "vlan-200",
                .interface = .{ .type = "macvlan", .master = "eth0" },
                .ipam = .{ .dhcp = .{} },
                .acl = &[_]Resource.Grant{
                    .{ .user = "1001" },
                },
            },
            Resource{
                .name = "vlan-300",
                .interface = .{ .type = "macvlan", .master = "eth0" },
                .ipam = .{ .dhcp = .{} },
                .acl = &[_]Resource.Grant{
                    .{ .group = "200" },
                },
            },
        },
    };

    var acl_manager = try AclManager.init(allocator, config);
    defer acl_manager.deinit();

    try testing.expect(acl_manager.hasAnyPermission(1000, 1000));
    try testing.expect(acl_manager.hasAnyPermission(1001, 1001));
    try testing.expect(acl_manager.hasAnyPermission(1002, 200));
    try testing.expect(!acl_manager.hasAnyPermission(1003, 1003));
}

test "AclManager: hasAnyPermission - no resources configured" {
    const allocator = testing.allocator;
    const config = Config{
        .resources = null,
    };

    var acl_manager = try AclManager.init(allocator, config);
    defer acl_manager.deinit();

    try testing.expect(!acl_manager.hasAnyPermission(0, 0));
    try testing.expect(!acl_manager.hasAnyPermission(1000, 1000));
}

test "AclManager: init rejects resource with empty acl" {
    const allocator = testing.allocator;
    const config = Config{
        .resources = &[_]Resource{
            Resource{
                .name = "insecure-resource",
                .interface = .{ .type = "macvlan", .master = "eth0" },
                .ipam = .{ .dhcp = .{} },
                .acl = &[_]Resource.Grant{},
            },
        },
    };

    const result = AclManager.init(allocator, config);
    try testing.expectError(error.ResourceMissingAcl, result);
}

test "AclManager: isAllowed - user allowed on specific resource" {
    const allocator = testing.allocator;
    const config = Config{
        .resources = &[_]Resource{
            Resource{
                .name = "vlan-100",
                .interface = .{ .type = "macvlan", .master = "eth0" },
                .ipam = .{ .dhcp = .{} },
                .acl = &[_]Resource.Grant{
                    .{ .user = "1000" },
                    .{ .user = "1001" },
                },
            },
            Resource{
                .name = "vlan-200",
                .interface = .{ .type = "macvlan", .master = "eth0" },
                .ipam = .{ .dhcp = .{} },
                .acl = &[_]Resource.Grant{
                    .{ .user = "1001" },
                    .{ .user = "1002" },
                },
            },
        },
    };

    var acl_manager = try AclManager.init(allocator, config);
    defer acl_manager.deinit();

    try testing.expect(acl_manager.isAllowed("vlan-100", 1000, 1000));
    try testing.expect(!acl_manager.isAllowed("vlan-200", 1000, 1000));

    try testing.expect(acl_manager.isAllowed("vlan-100", 1001, 1001));
    try testing.expect(acl_manager.isAllowed("vlan-200", 1001, 1001));

    try testing.expect(!acl_manager.isAllowed("vlan-100", 1002, 1002));
    try testing.expect(acl_manager.isAllowed("vlan-200", 1002, 1002));

    try testing.expect(!acl_manager.isAllowed("vlan-999", 0, 0));
}
