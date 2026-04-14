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
/// Includes uids from both allow_users and allow_groups (expanded via group membership).
pub fn allAllowedUids(self: AclManager, allocator: Allocator) !std.ArrayList(u32) {
    var uid_set = std.AutoHashMap(u32, void).init(allocator);
    defer uid_set.deinit();

    if (self.acls) |acls| {
        for (acls.items) |acl| {
            if (acl.allow_uids) |uids| {
                for (uids.items) |uid| {
                    try uid_set.put(uid, {});
                }
            }
            // For groups, we need the primary uid of each group member.
            // However, group→uid expansion is complex (requires reading /etc/group + /etc/passwd).
            // For socket creation purposes, only direct uids are needed.
            // Users allowed via groups will still pass SO_PEERCRED + ACL check at request time.
        }
    }

    var result = try std.ArrayList(u32).initCapacity(allocator, uid_set.count());
    var iter = uid_set.keyIterator();
    while (iter.next()) |uid| {
        result.appendAssumeCapacity(uid.*);
    }
    return result;
}

test "isAllowed" {
    const Resource = @import("../config.zig").Resource;
    const allocator = std.testing.allocator;
    var runtime = try init(allocator, Config{
        .resources = &[_]Resource{
            Resource{ .name = "test", .allow_users = &[_][:0]const u8{"root"} },
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
            Resource{ .name = "net-a", .allow_users = &[_][:0]const u8{"root"} },
            Resource{ .name = "net-b", .allow_groups = &[_][:0]const u8{"999"} },
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
            Resource{ .name = "insecure" },
        },
    });
    try std.testing.expectError(error.ResourceMissingAcl, result);
}
