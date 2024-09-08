const std = @import("std");
const Acl = @import("Acl.zig");
const Config = @import("../config.zig").Config;
const ArenaAllocator = @import("../ArenaAllocator.zig");
const Allocator = std.mem.Allocator;
const AclManager = @This();

arena: ArenaAllocator,
accepted_uid: std.posix.uid_t,
acls: ?std.ArrayList(Acl) = null,

pub fn init(root_allocator: Allocator, config: Config, accepted_uid: std.posix.uid_t) Allocator.Error!AclManager {
    var arena = try ArenaAllocator.init(root_allocator);
    errdefer arena.deinit();

    var acl_manager = AclManager{
        .arena = arena,
        .accepted_uid = accepted_uid,
    };

    const allocator = arena.allocator();
    if (config.resources) |resources| {
        if (acl_manager.acls == null) {
            acl_manager.acls = try std.ArrayList(Acl).initCapacity(allocator, resources.len);
        }
        for (resources) |resource| {
            try acl_manager.acls.?.append(try Acl.fromResource(allocator, resource));
        }
    }
    return acl_manager;
}

pub fn deinit(self: AclManager) void {
    if (self.acls) |acls| {
        for (acls.items) |acl| {
            acl.deinit();
        }
        acls.deinit();
    }

    self.arena.deinit();
}

pub fn isAllowed(self: AclManager, name: []const u8, uid: u32, gid: u32) bool {
    if (uid != self.accepted_uid) {
        return false;
    }
    if (self.acls) |acls| {
        for (acls.items) |acl| {
            if (std.mem.eql(u8, name, acl.name)) {
                return acl.isAllowed(uid, gid);
            }
        }
    }
    return false;
}

test "isAllowed" {
    const Resource = @import("../config.zig").Resource;
    const allocator = std.testing.allocator;
    const runtime = try init(allocator, Config{
        .resources = &[_]Resource{
            Resource{ .name = "test", .allow_users = &[_][:0]const u8{"root"} },
        },
    }, 0);
    defer runtime.deinit();

    try std.testing.expect(runtime.isAllowed("test", 0, 0));
    try std.testing.expect(!runtime.isAllowed("test", 333, 0));
    try std.testing.expect(!runtime.isAllowed("not-exists", 0, 0));
}
