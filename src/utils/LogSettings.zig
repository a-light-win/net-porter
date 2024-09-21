const std = @import("std");
const LogSettings = @This();

const ScopeLog = struct {
    scope: []const u8,
    level: std.log.Level,
};

const EnvLog = struct {
    enabled: bool = false,
    path: []const u8 = "/var/log/net-porter/env",
};

level: std.log.Level = .info,
scope_levels: ?[]ScopeLog = null,
dump_env: EnvLog = .{},
