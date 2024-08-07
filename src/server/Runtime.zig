const std = @import("std");
const Acl = @import("Acl.zig");
const Config = @import("../config.zig").Config;
const Allocator = std.mem.Allocator;
const Runtime = @This();

arena: *std.heap.ArenaAllocator,
cni_dir: []const u8,
acls: ?std.ArrayList(Acl) = null,

pub fn init(allocator: Allocator, config: Config) Allocator.Error!Runtime {
    var arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);

    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const child_allocator = arena.allocator();

    var runtime = Runtime{
        .arena = arena,
        .cni_dir = try genCniDir(child_allocator, config),
    };

    if (config.resources) |resources| {
        if (runtime.acls == null) {
            runtime.acls = try std.ArrayList(Acl).initCapacity(allocator, resources.len);
        }
        for (resources) |resource| {
            try runtime.acls.?.append(try Acl.fromResource(allocator, resource));
        }
    }
    return runtime;
}

pub fn deinit(self: Runtime) void {
    if (self.acls) |acls| {
        for (acls.items) |acl| {
            acl.deinit();
        }
        acls.deinit();
    }

    const allocator = self.arena.child_allocator;
    self.arena.deinit();
    allocator.destroy(self.arena);
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
    const Resource = @import("../config.zig").Resource;
    const allocator = std.testing.allocator;
    const runtime = try init(allocator, Config{
        .resources = &[_]Resource{
            Resource{ .name = "test", .allow_users = &[_][]const u8{"root"} },
        },
    });
    defer runtime.deinit();

    try std.testing.expect(runtime.isAllowed("test", 0, 0));
    try std.testing.expect(!runtime.isAllowed("test", 333, 0));
    try std.testing.expect(!runtime.isAllowed("not-exists", 0, 0));
}

pub fn getCniPath(self: Runtime, allocator: std.mem.Allocator, name: []const u8) []const u8 {
    const buf = allocator.alloc(u8, self.cni_dir.len + 1 + name.len) catch unreachable;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.cni_dir, name }) catch unreachable;
}

fn genCniDir(allocator: std.mem.Allocator, config: Config) Allocator.Error![]const u8 {
    if (config.cni_dir) |dir| {
        return dir;
    }

    const buf = try allocator.alloc(u8, config.config_dir.len + 6);
    return std.fmt.bufPrint(buf, "{s}/cni.d", .{config.config_dir}) catch unreachable;
}
