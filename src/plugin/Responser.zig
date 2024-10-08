const std = @import("std");
const json = std.json;
const log = std.log.scoped(.server);
const traffic_log = std.log.scoped(.traffic);
const Responser = @This();

stream: *std.net.Stream,
log_response: bool = false,
done: bool = false,
is_error: bool = false,

pub fn writeError(self: *Responser, comptime fmt: []const u8, args: anytype) void {
    if (self.done) {
        log.info("Response already sent, ignoring error: {s}", .{fmt});
        return;
    }

    var buf: [1024]u8 = undefined;

    const error_msg = std.fmt.bufPrint(&buf, fmt, args) catch |err| {
        log.warn("Failed to format error message: {s}", .{@errorName(err)});
        return;
    };

    log.warn("{s}", .{error_msg});

    json.stringify(
        .{ .@"error" = error_msg },
        .{ .whitespace = .indent_2 },
        self.stream.writer(),
    ) catch |err| {
        log.warn("Failed to send error message: {s}", .{@errorName(err)});
        return;
    };

    self.is_error = true;
    self.done = true;
}

pub fn write(self: *Responser, response: anytype) void {
    if (self.done) {
        log.warn("Response already sent, ignoring new response", .{});
        return;
    }

    if (@TypeOf(response) == []const u8) {
        self.stream.writeAll(response) catch |err| {
            self.writeError("Failed to send response: {s}", .{@errorName(err)});
        };
        self.done = true;
        return;
    }

    json.stringify(
        response,
        .{ .whitespace = .indent_2 },
        self.stream.writer(),
    ) catch |err| {
        self.writeError("Failed to format response: {s}", .{@errorName(err)});
        return;
    };

    self.done = true;

    if (self.log_response) {
        json.stringify(
            response,
            .{ .whitespace = .indent_2 },
            std.io.getStdOut().writer(),
        ) catch {};
    }
}
