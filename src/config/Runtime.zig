const std = @import("std");
const Acl = @import("Acl.zig");
const Config = @import("Config.zig");
const Runtime = @This();

arena: *std.heap.ArenaAllocator,
cni_dir: []const u8,
acls: ?std.ArrayList(Acl) = null,

pub fn newRuntime(allocator: std.mem.Allocator, config: Config) Runtime {
    var arena = allocator.create(std.heap.ArenaAllocator) catch unreachable;
    arena.* = std.heap.ArenaAllocator.init(allocator);
    const child_allocator = arena.allocator();

    var runtime = Runtime{
        .arena = arena,
        .cni_dir = genCniDir(child_allocator, config),
    };

    runtime.init(config);
    return runtime;
}

fn init(self: *Runtime, config: Config) void {
    const allocator = self.arena.allocator();

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
    const Resource = @import("Resource.zig");
    const allocator = std.testing.allocator;
    const runtime = newRuntime(allocator, Config{
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

fn genCniDir(allocator: std.mem.Allocator, config: Config) []const u8 {
    if (config.cni_dir) |dir| {
        return dir;
    }

    const buf = allocator.alloc(u8, config.config_dir.len + 6) catch unreachable;
    return std.fmt.bufPrint(buf, "{s}/cni.d", .{config.config_dir}) catch unreachable;
}

test {
    _ = @import("Acl.zig");
}
