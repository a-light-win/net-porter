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
                .allow_users = &[_][:0]const u8{"1000"},
            },
        },
    };

    var acl_manager = try AclManager.init(allocator, config);
    defer acl_manager.deinit();

    // UID 1000 should have permission
    try testing.expect(acl_manager.hasAnyPermission(1000, 1000));
    // UID 1001 should not
    try testing.expect(!acl_manager.hasAnyPermission(1001, 1001));
}

test "AclManager: hasAnyPermission - group permission" {
    const allocator = testing.allocator;
    const config = Config{
        .resources = &[_]Resource{
            Resource{
                .name = "vlan-100",
                .allow_groups = &[_][:0]const u8{"100"}, // 100 is users group
            },
        },
    };

    var acl_manager = try AclManager.init(allocator, config);
    defer acl_manager.deinit();

    // GID 100 should have permission
    try testing.expect(acl_manager.hasAnyPermission(1000, 100));
    // GID 101 should not
    try testing.expect(!acl_manager.hasAnyPermission(1001, 101));
}

test "AclManager: hasAnyPermission - multiple resources" {
    const allocator = testing.allocator;
    const config = Config{
        .resources = &[_]Resource{
            Resource{
                .name = "vlan-100",
                .allow_users = &[_][:0]const u8{"1000"},
            },
            Resource{
                .name = "vlan-200",
                .allow_users = &[_][:0]const u8{"1001"},
            },
            Resource{
                .name = "vlan-300",
                .allow_groups = &[_][:0]const u8{"200"},
            },
        },
    };

    var acl_manager = try AclManager.init(allocator, config);
    defer acl_manager.deinit();

    try testing.expect(acl_manager.hasAnyPermission(1000, 1000)); // has vlan-100
    try testing.expect(acl_manager.hasAnyPermission(1001, 1001)); // has vlan-200
    try testing.expect(acl_manager.hasAnyPermission(1002, 200)); // has vlan-300 via group
    try testing.expect(!acl_manager.hasAnyPermission(1003, 1003)); // has nothing
}

test "AclManager: hasAnyPermission - no resources configured" {
    const allocator = testing.allocator;
    const config = Config{
        .resources = null,
    };

    var acl_manager = try AclManager.init(allocator, config);
    defer acl_manager.deinit();

    // No resources, no one has permission
    try testing.expect(!acl_manager.hasAnyPermission(0, 0));
    try testing.expect(!acl_manager.hasAnyPermission(1000, 1000));
}

test "AclManager: init rejects resource with neither allow_users nor allow_groups" {
    const allocator = testing.allocator;
    const config = Config{
        .resources = &[_]Resource{
            Resource{
                .name = "insecure-resource",
                // No allow_users or allow_groups
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
                .allow_users = &[_][:0]const u8{ "1000", "1001" },
            },
            Resource{
                .name = "vlan-200",
                .allow_users = &[_][:0]const u8{ "1001", "1002" },
            },
        },
    };

    var acl_manager = try AclManager.init(allocator, config);
    defer acl_manager.deinit();

    // 1000 only allowed on vlan-100
    try testing.expect(acl_manager.isAllowed("vlan-100", 1000, 1000));
    try testing.expect(!acl_manager.isAllowed("vlan-200", 1000, 1000));

    // 1001 allowed on both
    try testing.expect(acl_manager.isAllowed("vlan-100", 1001, 1001));
    try testing.expect(acl_manager.isAllowed("vlan-200", 1001, 1001));

    // 1002 only allowed on vlan-200
    try testing.expect(!acl_manager.isAllowed("vlan-100", 1002, 1002));
    try testing.expect(acl_manager.isAllowed("vlan-200", 1002, 1002));

    // non-existent resource
    try testing.expect(!acl_manager.isAllowed("vlan-999", 0, 0));
}
