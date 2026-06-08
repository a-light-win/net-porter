const std = @import("std");
const LogSettings = @import("../utils.zig").LogSettings;
const Config = @This();

/// Hardcoded default config directory used when the config path has no
/// directory component (e.g. a bare filename like "config.json") or when the
/// path cannot be otherwise resolved. Keeps fresh installs running with
/// built-in defaults instead of failing to start.
const default_config_dir = "/etc/net-porter";

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
        // Fallback for fresh installs where the config path might be relative
        // or the directory doesn't exist yet. Returning an error here would
        // prevent the server from starting with built-in defaults.
        self.config_dir = default_config_dir;
        std.log.warn("Could not derive config directory from path '{s}', using default: {s}", .{ path, self.config_dir });
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
        var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch {
            break :blk;
        };
        defer dir.close(io);
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

test "postInit falls back to default config_dir when dirname returns null" {
    const allocator = std.testing.allocator;
    var config = Config{};
    // Bare filename has no directory component, so dirname() returns null.
    try config.postInit(std.testing.io, allocator, "config.json");

    try std.testing.expectEqualSlices(u8, default_config_dir, config.config_dir);
    try std.testing.expectEqualSlices(u8, "config.json", config.config_path);
    try std.testing.expectEqualSlices(u8, "/etc/net-porter/acl.d", config.acl_dir);
    try std.testing.expectEqualSlices(u8, "/etc/net-porter/cni.d", config.cni_dir);
    allocator.free(config.acl_dir);
    allocator.free(config.cni_dir);
}
