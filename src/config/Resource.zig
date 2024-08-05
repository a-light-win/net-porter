const std = @import("std");
const user = @import("user.zig");
const Resource = @This();

name: []const u8,
allow_users: ?[]const []const u8 = null,
allow_groups: ?[]const []const u8 = null,

allow_uids: ?std.ArrayList(u32) = null,
allow_gids: ?std.ArrayList(u32) = null,

pub fn init(self: *Resource, allocator: std.mem.Allocator) void {
    self.initUids(allocator);
    self.initGids(allocator);
}

pub fn deinit(self: Resource) void {
    if (self.allow_uids) |uids| {
        uids.deinit();
    }
    if (self.allow_gids) |gids| {
        gids.deinit();
    }
}

pub fn isAllowed(self: Resource, uid: u32, gid: u32) bool {
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
    var resource = Resource{
        .name = "test",
    };
    resource.init(allocator);
    defer resource.deinit();
    try std.testing.expectEqual(false, resource.isAllowed(0, 0));
}

test "isAllowed() should success if uid is allowed" {
    const allocator = std.testing.allocator;
    var resource = Resource{
        .name = "test",
        .allow_users = &[_][]const u8{"root"},
    };
    resource.init(allocator);
    defer resource.deinit();
    try std.testing.expectEqual(true, resource.isAllowed(0, 0));
}

test "isAllowed() should success if gid is allowed" {
    const allocator = std.testing.allocator;
    var resource = Resource{
        .name = "test",
        .allow_groups = &[_][]const u8{"root"},
    };
    resource.init(allocator);
    defer resource.deinit();
    try std.testing.expectEqual(true, resource.isAllowed(0, 0));
}

fn initUids(self: *Resource, allocator: std.mem.Allocator) void {
    // Only init uids once
    if (self.allow_users) |users| {
        if (users.len == 0) {
            return;
        }

        if (self.allow_uids == null) {
            self.allow_uids = std.ArrayList(u32).initCapacity(
                allocator,
                users.len,
            ) catch unreachable;

            if (self.allow_uids) |*uids| {
                resolveUsers(uids, users);
            }
        }
    }
}

test "initUids() should success if no users are specified" {
    const allocator = std.testing.allocator;
    var resource = Resource{
        .name = "test",
    };

    resource.initUids(allocator);
    defer resource.deinit();

    try std.testing.expectEqual(null, resource.allow_uids);
}

test "initUids() should success if users is empty" {
    const allocator = std.testing.allocator;
    var resource = Resource{
        .name = "test",
        .allow_users = &[_][]const u8{},
    };

    resource.initUids(allocator);
    defer resource.deinit();

    try std.testing.expectEqual(null, resource.allow_uids);
}

test "initUids() should success if users are specified" {
    const allocator = std.testing.allocator;
    var resource = Resource{
        .name = "test",
        .allow_users = &[_][]const u8{ "root", "333" },
        .allow_groups = &[_][]const u8{ "root", "333" },
    };

    resource.initUids(allocator);
    defer resource.deinit();

    const uids = resource.allow_uids.?;
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

fn initGids(self: *Resource, allocator: std.mem.Allocator) void {
    // Only init gids once
    if (self.allow_groups) |groups| {
        if (groups.len == 0) {
            return;
        }
        if (self.allow_gids == null) {
            self.allow_gids = std.ArrayList(u32).initCapacity(
                allocator,
                groups.len,
            ) catch unreachable;
            if (self.allow_gids) |*gids| {
                resolveGroups(gids, groups);
            }
        }
    }
}

test "initGids() should success if no groups are specified" {
    const allocator = std.testing.allocator;
    var resource = Resource{
        .name = "test",
    };
    resource.initGids(allocator);
    defer resource.deinit();
    try std.testing.expectEqual(null, resource.allow_gids);
}

test "initGids() should success if groups is empty" {
    const allocator = std.testing.allocator;
    var resource = Resource{
        .name = "test",
        .allow_groups = &[_][]const u8{},
    };
    resource.initGids(allocator);
    defer resource.deinit();
    try std.testing.expectEqual(null, resource.allow_gids);
}

test "initGids() should success if groups are specified" {
    const allocator = std.testing.allocator;
    var resource = Resource{
        .name = "test",
        .allow_users = &[_][]const u8{ "root", "333" },
        .allow_groups = &[_][]const u8{ "root", "333" },
    };
    resource.initGids(allocator);
    defer resource.deinit();
    const gids = resource.allow_gids.?;
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
