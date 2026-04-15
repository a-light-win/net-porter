const std = @import("std");
const Resource = @import("Resource.zig");
const LogSettings = @import("../utils.zig").LogSettings;
const user = @import("../user.zig");
const Config = @This();

config_dir: []const u8 = "",
config_path: []const u8 = "",
// CNI plugin directory (auto-detected if not set)
cni_plugin_dir: []const u8 = "",

/// List of users (usernames or numeric UIDs) that need a net-porter.sock entry.
/// The server creates per-user sockets only for users listed here.
users: ?[]const [:0]const u8 = null,
resources: ?[]const Resource = null,
log: LogSettings = .{},

pub fn postInit(self: *Config, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    _ = allocator;
    self.config_path = path;

    if (std.Io.Dir.path.dirname(path)) |dir| {
        self.config_dir = dir;
    } else {
        std.log.warn("Can not get config directory from path: {s}", .{path});
        return error.InvalidPath;
    }

    self.setCNIPluginDir(io);
}

const cni_plugin_search_paths = &[_][]const u8{
    "/usr/lib/cni",
    "/opt/cni/bin",
};

fn setCNIPluginDir(self: *Config, io: std.Io) void {
    if (!std.mem.eql(u8, self.cni_plugin_dir, "")) {
        return;
    }
    for (cni_plugin_search_paths) |path| blk: {
        _ = std.Io.Dir.cwd().openDir(io, path, .{}) catch {
            break :blk;
        };
        self.cni_plugin_dir = path;
        return;
    }
}

/// Resolve the `users` list to a deduplicated list of numeric UIDs.
/// Returns an ArrayList owned by the caller.
pub fn resolveUserUids(self: Config, allocator: std.mem.Allocator) !std.ArrayList(u32) {
    var uid_set = std.AutoHashMap(u32, void).init(allocator);
    defer uid_set.deinit();

    if (self.users) |users| {
        for (users) |username| {
            if (resolveUsername(username)) |uid| {
                try uid_set.put(uid, {});
            } else {
                std.log.warn("Failed to resolve user '{s}', skipping.", .{username});
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

fn resolveUsername(username: [:0]const u8) ?u32 {
    // Try parsing as numeric UID first
    if (std.fmt.parseUnsigned(u32, username, 10)) |uid| {
        return uid;
    } else |_| {}
    return user.getUid(username);
}

test "resolveUserUids with numeric UIDs" {
    const allocator = std.testing.allocator;
    var config = Config{
        .users = &[_][:0]const u8{ "1000", "2000", "1000" },
    };
    var uids = try config.resolveUserUids(allocator);
    defer uids.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), uids.items.len);
    var found_1000 = false;
    var found_2000 = false;
    for (uids.items) |uid| {
        if (uid == 1000) found_1000 = true;
        if (uid == 2000) found_2000 = true;
    }
    try std.testing.expect(found_1000);
    try std.testing.expect(found_2000);
}

test "resolveUserUids with null users returns empty" {
    const allocator = std.testing.allocator;
    var config = Config{ .users = null };
    var uids = try config.resolveUserUids(allocator);
    defer uids.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), uids.items.len);
}

test "resolveUserUids skips unresolvable users" {
    const allocator = std.testing.allocator;
    var config = Config{
        .users = &[_][:0]const u8{ "1000", "nonexistent-user-xyz" },
    };
    var uids = try config.resolveUserUids(allocator);
    defer uids.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), uids.items.len);
    try std.testing.expectEqual(@as(u32, 1000), uids.items[0]);
}
