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

/// Opt-in flag for verbose netns topology diagnostics (inodes, fs magic numbers,
/// owning user namespace). Disabled by default because these logs can leak
/// sensitive host/container topology information if debug logging is enabled
/// in production (SEV-004).
diagnostics: bool = false,

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

// ============================================================
// Tests
// ============================================================

test "LogSettings defaults diagnostics to false" {
    const settings = LogSettings{};
    try std.testing.expectEqual(false, settings.diagnostics);
}

test "LogSettings accepts explicit diagnostics = true" {
    const settings = LogSettings{ .diagnostics = true };
    try std.testing.expectEqual(true, settings.diagnostics);
}
