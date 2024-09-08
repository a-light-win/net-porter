const std = @import("std");
const DomainSocket = @import("DomainSocket.zig");
const Resource = @import("Resource.zig");
const LogSettings = @import("LogSettings.zig");
const Config = @This();

config_dir: []const u8 = "",
config_path: []const u8 = "",
// CNI configuration directory
cni_dir: ?[]const u8 = null,
// CNI plugin directory
cni_plugin_dir: []const u8 = "/usr/lib/cni",

domain_socket: DomainSocket = DomainSocket{},
resources: ?[]const Resource = null,
log: LogSettings = .{},

pub fn init(self: *Config, allocator: std.mem.Allocator, path: []const u8, accepted_uid: std.posix.uid_t) !void {
    self.config_path = path;

    // std.log.default_level = self.log.level;

    if (std.fs.path.dirname(path)) |dir| {
        self.config_dir = dir;
    } else {
        std.log.warn("Can not get config directory from path: {s}", .{path});
        return error.InvalidPath;
    }

    try self.domain_socket.init(allocator, accepted_uid);
}
