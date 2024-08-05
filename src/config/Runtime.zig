const std = @import("std");
const Acl = @import("Acl.zig");
const Config = @import("Config.zig");
const Runtime = @This();

acls: ?std.ArrayList(Acl) = null,

pub fn init(self: *Runtime, allocator: std.mem.Allocator, config: Config) void {
    if (config.resources) |resources| {
        if (self.acls == null) {
            self.acls = std.ArrayList(Acl).initCapacity(allocator, resources.len) catch unreachable;
        }
        for (resources) |resource| {
            self.acls.?.append(Acl.fromResource(allocator, resource)) catch unreachable;
        }
    }
}

pub fn deinit(self: Runtime) void {
    if (self.acls) |acls| {
        for (acls.items) |acl| {
            acl.deinit();
        }
        acls.deinit();
    }
}

pub fn isAllowed(self: Runtime, name: []const u8, uid: u32, gid: u32) bool {
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
    const Resource = @import("Resource.zig");
    const allocator = std.testing.allocator;
    var runtime = Runtime{};
    runtime.init(allocator, Config{
        .resources = &[_]Resource{
            Resource{ .name = "test", .allow_users = &[_][]const u8{"root"} },
        },
    });
    defer runtime.deinit();

    try std.testing.expect(runtime.isAllowed("test", 0, 0));
    try std.testing.expect(!runtime.isAllowed("test", 333, 0));
    try std.testing.expect(!runtime.isAllowed("not-exists", 0, 0));
}

test {
    _ = @import("Acl.zig");
}
