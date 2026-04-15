const std = @import("std");
const json = std.json;
const log = std.log.scoped(.server);
const traffic_log = std.log.scoped(.traffic);
const Responser = @This();

io: std.Io,
stream: *std.Io.net.Stream,
log_response: bool = false,
done: bool = false,
is_error: bool = false,

const stringify_options = json.Stringify.Options{
    .whitespace = .indent_2,
};

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

    var write_buffer: [4096]u8 = undefined;
    var stream_writer = self.stream.writer(self.io, &write_buffer);
    json.Stringify.value(
        .{ .@"error" = error_msg },
        stringify_options,
        &stream_writer.interface,
    ) catch |err| {
        log.warn("Failed to send error message: {s}", .{@errorName(err)});
        return;
    };
    stream_writer.interface.flush() catch |err| {
        log.warn("Failed to flush error message: {s}", .{@errorName(err)});
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
        var write_buffer: [4096]u8 = undefined;
        var stream_writer = self.stream.writer(self.io, &write_buffer);
        stream_writer.interface.writeAll(response) catch |err| {
            self.writeError("Failed to send response: {s}", .{@errorName(err)});
        };
        stream_writer.interface.flush() catch {};
        self.done = true;
        return;
    }

    var write_buffer: [4096]u8 = undefined;
    var stream_writer = self.stream.writer(self.io, &write_buffer);
    json.Stringify.value(
        response,
        stringify_options,
        &stream_writer.interface,
    ) catch |err| {
        self.writeError("Failed to format response: {s}", .{@errorName(err)});
        return;
    };
    stream_writer.interface.flush() catch |err| {
        self.writeError("Failed to flush response: {s}", .{@errorName(err)});
        return;
    };

    self.done = true;

    if (self.log_response) {
        var log_buffer: [4096]u8 = undefined;
        var file_writer = std.Io.File.stdout().writer(self.io, &log_buffer);
        json.Stringify.value(
            response,
            stringify_options,
            &file_writer.interface,
        ) catch {};
        file_writer.end() catch {};
    }
}
