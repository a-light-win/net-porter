const std = @import("std");
const Resource = @import("Resource.zig");
const LogSettings = @import("../utils.zig").LogSettings;
const Config = @This();

config_dir: []const u8 = "",
config_path: []const u8 = "",
// CNI configuration directory
cni_dir: ?[]const u8 = null,
// CNI plugin directory
cni_plugin_dir: []const u8 = "",

resources: ?[]const Resource = null,
log: LogSettings = .{},

pub fn postInit(self: *Config, allocator: std.mem.Allocator, path: []const u8) !void {
    _ = allocator;
    self.config_path = path;

    if (std.fs.path.dirname(path)) |dir| {
        self.config_dir = dir;
    } else {
        std.log.warn("Can not get config directory from path: {s}", .{path});
        return error.InvalidPath;
    }

    self.setCNIPluginDir();
}

const cni_plugin_search_paths = &[_][]const u8{
    "/usr/lib/cni",
    "/opt/cni/bin",
};

fn setCNIPluginDir(self: *Config) void {
    if (!std.mem.eql(u8, self.cni_plugin_dir, "")) {
        return;
    }
    for (cni_plugin_search_paths) |path| blk: {
        _ = std.fs.cwd().openDir(path, .{}) catch {
            break :blk;
        };
        self.cni_plugin_dir = path;
        return;
    }
}
