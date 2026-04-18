const std = @import("std");
const json = std.json;

const stringify_options = json.Stringify.Options{
    .whitespace = .indent_2,
    .emit_null_optional_fields = false,
};

pub fn stringifyToStdout(io: std.Io, value: anytype) !void {
    var write_buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &write_buffer);
    try json.Stringify.value(value, stringify_options, &file_writer.interface);
    try file_writer.end();
}
