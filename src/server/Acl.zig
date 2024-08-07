const std = @import("std");
const user = @import("../user.zig");
const Allocator = std.mem.Allocator;
const Resource = @import("../config.zig").Resource;

const Acl = @This();

name: []const u8,
allow_uids: ?std.ArrayList(u32) = null,
allow_gids: ?std.ArrayList(u32) = null,

pub fn fromResource(allocator: Allocator, resource: Resource) Allocator.Error!Acl {
    var acl = Acl{ .name = resource.name };
    try acl.init(allocator, resource);
    return acl;
}

fn init(self: *Acl, allocator: std.mem.Allocator, resource: Resource) Allocator.Error!void {
    if (resource.allow_users) |users| {
        try self.initUids(allocator, users);
    }

    if (resource.allow_groups) |groups| {
        try self.initGids(allocator, groups);
    }
}

pub fn deinit(self: Acl) void {
    if (self.allow_uids) |uids| {
        uids.deinit();
    }
    if (self.allow_gids) |gids| {
        gids.deinit();
    }
}

pub fn isAllowed(self: Acl, uid: u32, gid: u32) bool {
    if (self.allow_uids) |uids| {
        if (contains(uids, uid)) {
            return true;
        }
    }
    if (self.allow_gids) |gids| {
        if (contains(gids, gid)) {
            return true;
        }
    }
    return false;
}

test "isAllowed() should failed if allow_uids is empty" {
    const allocator = std.testing.allocator;
    var acl = try fromResource(allocator, Resource{ .name = "test" });
    defer acl.deinit();
    try std.testing.expectEqual(false, acl.isAllowed(0, 0));
}

test "isAllowed() should success if uid is allowed" {
    const allocator = std.testing.allocator;
    var acl = try fromResource(
        allocator,
        Resource{
            .name = "test",
            .allow_users = &[_][]const u8{"root"},
        },
    );
    defer acl.deinit();
    try std.testing.expectEqual(true, acl.isAllowed(0, 0));
}

test "isAllowed() should success if gid is allowed" {
    const allocator = std.testing.allocator;
    var acl = try fromResource(
        allocator,
        Resource{
            .name = "test",
            .allow_groups = &[_][]const u8{"root"},
        },
    );
    defer acl.deinit();
    try std.testing.expectEqual(true, acl.isAllowed(0, 0));
}

fn initUids(self: *Acl, allocator: Allocator, users: []const []const u8) Allocator.Error!void {
    // Only init uids once
    if (users.len == 0) {
        return;
    }

    if (self.allow_uids == null) {
        self.allow_uids = try std.ArrayList(u32).initCapacity(
            allocator,
            users.len,
        );

        if (self.allow_uids) |*uids| {
            resolveUsers(uids, users);
        }
    }
}

test "initUids() should success if no users are specified" {
    const allocator = std.testing.allocator;
    const resource = Resource{
        .name = "test",
    };
    var acl = try fromResource(allocator, resource);
    defer acl.deinit();

    try std.testing.expectEqual(null, acl.allow_uids);
}

test "initUids() should success if users is empty" {
    const allocator = std.testing.allocator;
    const resource = Resource{
        .name = "test",
        .allow_users = &[_][]const u8{},
    };

    var acl = try fromResource(allocator, resource);
    defer acl.deinit();

    try std.testing.expectEqual(null, acl.allow_uids);
}

test "initUids() should success if users are specified" {
    const allocator = std.testing.allocator;
    const resource = Resource{
        .name = "test",
        .allow_users = &[_][]const u8{ "root", "333" },
        .allow_groups = &[_][]const u8{ "root", "333" },
    };

    var acl = try fromResource(allocator, resource);
    defer acl.deinit();

    const uids = acl.allow_uids.?;
    try std.testing.expectEqual(2, uids.items.len);
    try std.testing.expectEqual(0, uids.items[0]);
    try std.testing.expectEqual(333, uids.items[1]);
}

fn resolveUsers(uids: *std.ArrayList(u32), users: []const []const u8) void {
    for (users) |u| {
        // if the user is number, add it directly
        // otherwise, resolve the user name to uid
        if (std.fmt.parseUnsigned(u32, u, 10)) |uid| {
            uids.append(uid) catch unreachable;
            continue;
        } else |e| switch (e) {
            else => {},
        }

        if (user.getUid(u)) |uid| {
            uids.append(uid) catch unreachable;
        } else {
            std.log.warn(
                "Failed to resolve user '{s}', ignore it.",
                .{u},
            );
        }
    }
}

fn initGids(self: *Acl, allocator: Allocator, groups: []const []const u8) Allocator.Error!void {
    // Only init gids once
    if (groups.len == 0) {
        return;
    }
    if (self.allow_gids == null) {
        self.allow_gids = try std.ArrayList(u32).initCapacity(
            allocator,
            groups.len,
        );
        if (self.allow_gids) |*gids| {
            resolveGroups(gids, groups);
        }
    }
}

test "initGids() should success if no groups are specified" {
    const allocator = std.testing.allocator;
    const resource = Resource{
        .name = "test",
    };

    var acl = try fromResource(allocator, resource);
    defer acl.deinit();

    try std.testing.expectEqual(null, acl.allow_gids);
}

test "initGids() should success if groups is empty" {
    const allocator = std.testing.allocator;
    const resource = Resource{
        .name = "test",
        .allow_groups = &[_][]const u8{},
    };
    var acl = try fromResource(allocator, resource);
    defer acl.deinit();

    try std.testing.expectEqual(null, acl.allow_gids);
}

test "initGids() should success if groups are specified" {
    const allocator = std.testing.allocator;
    const resource = Resource{
        .name = "test",
        .allow_users = &[_][]const u8{ "root", "333" },
        .allow_groups = &[_][]const u8{ "root", "333" },
    };

    var acl = try fromResource(allocator, resource);
    defer acl.deinit();
    const gids = acl.allow_gids.?;
    try std.testing.expectEqual(2, gids.items.len);
    try std.testing.expectEqual(0, gids.items[0]);
    try std.testing.expectEqual(333, gids.items[1]);
}

fn resolveGroups(gids: *std.ArrayList(u32), groups: []const []const u8) void {
    for (groups) |g| {
        // if the group is number, add it directly
        // otherwise, resolve the group name to gid
        if (std.fmt.parseUnsigned(u32, g, 10)) |gid| {
            gids.append(gid) catch unreachable;
            continue;
        } else |e| switch (e) {
            else => {},
        }

        if (user.getGid(g)) |gid| {
            gids.append(gid) catch unreachable;
        } else {
            std.log.warn(
                "Failed to resolve group '{s}', ignore it.",
                .{g},
            );
        }
    }
}

fn contains(list: std.ArrayList(u32), value: u32) bool {
    for (list.items) |v| {
        if (v == value) {
            return true;
        }
    }
    return false;
}

test "contains()" {
    const allocator = std.testing.allocator;

    var list = std.ArrayList(u32).init(allocator);
    defer list.deinit();
    list.append(1) catch unreachable;

    try std.testing.expectEqual(true, contains(list, 1));
    try std.testing.expectEqual(false, contains(list, 2));
}
