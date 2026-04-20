const std = @import("std");
const LogSettings = @import("../utils.zig").LogSettings;
const Config = @This();

config_dir: []const u8 = "",
config_path: []const u8 = "",
// CNI plugin directory (auto-detected if not set)
cni_plugin_dir: []const u8 = "",

/// Directory containing dynamic ACL files.
/// Defaults to {config_dir}/acl.d if not explicitly set.
acl_dir: []const u8 = "",

/// Directory containing standard CNI configuration files.
/// Defaults to {config_dir}/cni.d if not explicitly set.
cni_dir: []const u8 = "",

log: LogSettings = .{},

pub fn postInit(self: *Config, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    self.config_path = path;

    if (std.Io.Dir.path.dirname(path)) |dir| {
        self.config_dir = dir;
    } else {
        std.log.warn("Can not get config directory from path: {s}", .{path});
        return error.InvalidPath;
    }

    self.setCNIPluginDir(io);
    self.setDefaultSubDir(allocator, "acl.d", &self.acl_dir);
    self.setDefaultSubDir(allocator, "cni.d", &self.cni_dir);
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

/// Set default sub-directory to {config_dir}/<suffix> if not explicitly configured.
fn setDefaultSubDir(self: *Config, allocator: std.mem.Allocator, comptime suffix: []const u8, field: *[]const u8) void {
    if (field.len > 0) return;
    if (self.config_dir.len == 0) return;

    const default = std.fmt.allocPrint(allocator, "{s}/" ++ suffix, .{self.config_dir}) catch {
        std.log.warn("Failed to allocate default {s} path", .{suffix});
        return;
    };
    field.* = default;
}

// ============================================================
// Tests
// ============================================================

test "postInit sets default acl_dir from config_dir" {
    const allocator = std.testing.allocator;
    var config = Config{};
    try config.postInit(std.testing.io, allocator, "/etc/net-porter/config.json");

    try std.testing.expectEqualSlices(u8, "/etc/net-porter/acl.d", config.acl_dir);
    try std.testing.expectEqualSlices(u8, "/etc/net-porter/cni.d", config.cni_dir);
    allocator.free(config.acl_dir);
    allocator.free(config.cni_dir);
}

test "postInit preserves explicit acl_dir" {
    const allocator = std.testing.allocator;
    var config = Config{ .acl_dir = "/custom/acl/path" };
    try config.postInit(std.testing.io, allocator, "/etc/net-porter/config.json");

    try std.testing.expectEqualSlices(u8, "/custom/acl/path", config.acl_dir);
    try std.testing.expectEqualSlices(u8, "/etc/net-porter/cni.d", config.cni_dir);
    allocator.free(config.cni_dir);
}

test "postInit preserves explicit cni_dir" {
    const allocator = std.testing.allocator;
    var config = Config{ .cni_dir = "/custom/cni/path" };
    try config.postInit(std.testing.io, allocator, "/etc/net-porter/config.json");

    try std.testing.expectEqualSlices(u8, "/custom/cni/path", config.cni_dir);
    try std.testing.expectEqualSlices(u8, "/etc/net-porter/acl.d", config.acl_dir);
    allocator.free(config.acl_dir);
}

test "postInit sets config_dir and config_path" {
    const allocator = std.testing.allocator;
    var config = Config{};
    try config.postInit(std.testing.io, allocator, "/etc/net-porter/config.json");

    try std.testing.expectEqualSlices(u8, "/etc/net-porter", config.config_dir);
    try std.testing.expectEqualSlices(u8, "/etc/net-porter/config.json", config.config_path);
    allocator.free(config.acl_dir);
    allocator.free(config.cni_dir);
}
