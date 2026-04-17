const std = @import("std");
const LogSettings = @This();

const ScopeLog = struct {
    scope: []const u8,
    level: std.log.Level,
};

level: std.log.Level = .info,
scope_levels: []const ScopeLog = &[_]ScopeLog{
    // Do not output request and response logs
    .{ .scope = "traffic", .level = .warn },
},

pub inline fn logEnabled(
    settings: LogSettings,
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
) bool {
    for (settings.scope_levels) |scope_level| {
        if (std.mem.eql(u8, @tagName(scope), scope_level.scope)) {
            return @intFromEnum(message_level) <= @intFromEnum(scope_level.level);
        }
    }
    return @intFromEnum(message_level) <= @intFromEnum(settings.level);
}
