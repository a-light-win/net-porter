const std = @import("std");
const user = @import("user.zig");
const DomainSocket = @import("config/domain_socket.zig").DomainSocket;

pub const Config = struct {
    domain_socket: DomainSocket = DomainSocket{},

    pub fn init(config_path: []const u8) !Config {
        _ = config_path;

        var config = Config{};
        config.postInit();
        return config;
    }

    fn postInit(self: *Config) void {
        self.domain_socket.postInit();
    }
};

test {
    _ = @import("config/domain_socket.zig");
}
