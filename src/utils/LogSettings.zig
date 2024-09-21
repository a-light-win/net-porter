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
scope_levels: []const ScopeLog = &[_]ScopeLog{
    // Do not output request and response logs
    .{ .scope = "traffic", .level = .warn },
},
dump_env: EnvLog = .{},

pub inline fn logEnabled(
    settings: LogSettings,
    comptime message_level: std.log.Level,
    comptime scope: @Type(.EnumLiteral),
) bool {
    for (settings.scope_levels) |scope_level| {
        if (std.mem.eql(u8, @tagName(scope), scope_level.scope)) {
            return @intFromEnum(message_level) <= @intFromEnum(scope_level.level);
        }
    }
    return @intFromEnum(message_level) <= @intFromEnum(settings.level);
}
