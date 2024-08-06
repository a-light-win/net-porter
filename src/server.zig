const std = @import("std");
const Server = @import("server/Server.zig");

pub fn run() !void {
    var server = try Server.new("config.json");
    defer server.deinit();

    try server.run();
}

test {
    _ = @import("server/Server.zig");
}
