const std = @import("std");
const DomainSocket = @import("DomainSocket.zig");
const Resource = @import("Resource.zig");
const Config = @This();

config_dir: []const u8 = "",
config_path: []const u8 = "",

domain_socket: DomainSocket = DomainSocket{},
resources: ?[]const Resource = null,
