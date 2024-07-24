const std = @import("std");
const DomainSocket = @import("domain_socket.zig").DomainSocket;

test "DomainSocket::postinit no owner or group" {
    var config_path_only = DomainSocket{
        .path = "/run/net-porter.sock",
    };
    config_path_only.postInit();
    try std.testing.expectEqual(null, config_path_only.owner);
    try std.testing.expectEqual(null, config_path_only.uid);
    try std.testing.expectEqual(null, config_path_only.group);
    try std.testing.expectEqual(null, config_path_only.gid);
}

test "DomainSocket::postinit owner and group are set" {
    var config_with_owner = DomainSocket{
        .path = "/run/net-porter.sock",
        .owner = "root",
        .group = "root",
    };
    config_with_owner.postInit();
    try std.testing.expectEqual("root", config_with_owner.owner);
    try std.testing.expectEqual(0, config_with_owner.uid);
    try std.testing.expectEqual("root", config_with_owner.group);
    try std.testing.expectEqual(0, config_with_owner.gid);
}

test "DomainSocket::postinit uid and gid are set" {
    var config_with_owner = DomainSocket{
        .path = "/run/net-porter.sock",
        .uid = 1000,
        .gid = 1000,
    };
    config_with_owner.postInit();
    try std.testing.expectEqual(null, config_with_owner.owner);
    try std.testing.expectEqual(1000, config_with_owner.uid);
    try std.testing.expectEqual(null, config_with_owner.group);
    try std.testing.expectEqual(1000, config_with_owner.gid);
}
