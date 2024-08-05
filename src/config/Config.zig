const std = @import("std");
const DomainSocket = @import("DomainSocket.zig");
const Config = @This();

domain_socket: DomainSocket = DomainSocket{},
config_dir: []const u8 = "",
config_path: []const u8 = "",
