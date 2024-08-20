const std = @import("std");
const LogSettings = @This();

// TODO: how to set the log level in runtime?
// level: std.log.Level = .info,

dump_env: EnvLog = .{},

const EnvLog = struct {
    enabled: bool = false,
    path: []const u8 = "/var/log/net-porter/env",
};
