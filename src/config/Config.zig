const std = @import("std");
const DomainSocket = @import("DomainSocket.zig");
const Config = @This();

domain_socket: DomainSocket = DomainSocket{},

pub fn init(config_path: []const u8) !Config {
    _ = config_path;

    const config = Config{};
    return config;
}

test {
    _ = @import("user.zig");
    _ = @import("DomainSocket.zig");
}
