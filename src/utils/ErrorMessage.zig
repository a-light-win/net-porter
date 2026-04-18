const std = @import("std");
const ErrorMessage = @This();

const max_message_size = 4096;

@"error": ?[]const u8 = null,

pub fn init(err: []const u8) ErrorMessage {
    return ErrorMessage{ .@"error" = err };
}

pub fn isOk(self: ErrorMessage) bool {
    return self.@"error" == null;
}

pub fn message(self: ErrorMessage) []const u8 {
    return self.@"error" orelse "";
}

pub fn format(comptime err_format: []const u8, args: anytype) ErrorMessage {
    var buf: [max_message_size]u8 = undefined;
    const err = std.fmt.bufPrint(&buf, err_format, args) catch |e| switch (e) {
        error.NoSpaceLeft => "Can't generate error message: Error message too long",
        else => unreachable,
    };
    return ErrorMessage.init(err);
}

test "ErrorMessage" {
    const err = format("error {s} {d}", .{ "message", 3 });
    try std.testing.expect(!err.isOk());
    try std.testing.expectEqualSlices(u8, "error message 3", err.message());

    const allocator = std.heap.page_allocator;
    const long_msg = try allocator.alloc(u8, max_message_size + 1);
    defer allocator.free(long_msg);
    @memset(long_msg, 'x');

    const err_too_long = format("{s}", .{long_msg});
    try std.testing.expect(!err_too_long.isOk());
    try std.testing.expectEqualSlices(u8, "Can't generate error message: Error message too long", err_too_long.message());
}
