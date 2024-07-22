const std = @import("std");
const json = std.json;
const allocator = std.heap.page_allocator;

const json_options = json.StringifyOptions{
    .whitespace = .indent_2,
    .emit_null_optional_fields = false,
};

pub fn stringifyToStdout(value: anytype) !void {
    return stringify(value, std.io.getStdOut().writer());
}

pub fn stringify(value: anytype, out_stream: anytype) !void {
    return json.stringify(value, json_options, out_stream);
}
