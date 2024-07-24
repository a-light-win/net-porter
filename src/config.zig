const std = @import("std");

pub const Config = struct {
    domain_socket_path: []const u8 = "/run/net-porter.sock",

    pub fn init(config_path: []const u8) !Config {
        _ = config_path;
        return Config{};
    }
};
