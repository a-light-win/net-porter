const std = @import("std");
const json = std.json;
const allocator = std.heap.page_allocator;

pub const max_json_size = 1024 * 1024;

const stringify_options = json.StringifyOptions{
    .whitespace = .indent_2,
    .emit_null_optional_fields = false,
};

pub fn stringifyToStdout(value: anytype) !void {
    return stringify(value, std.io.getStdOut().writer());
}

test "stringifyToStdout" {
    // Create a JSON object
    const JsonStruct = struct {
        key: []const u8,
    };
    const object = JsonStruct{ .key = "value" };

    var buf: [1024]u8 = undefined;
    const old_stdout = std.io.getStdOut();
    std.io.setStdOut(std.io.bufferedOutStream(&buf));
    defer std.io.setStdOut(old_stdout);

    // Call the function
    try json.stringifyToStdout(object);

    // Check the output
    const expected_output =
        \\{
        \\  "key": "value"
        \\}
    ;
    const actual_output = std.mem.sliceTo(buf[0..], '\x00');
    std.testing.expectEqualStrings(expected_output, actual_output);
}

pub fn stringify(value: anytype, out_stream: anytype) !void {
    return json.stringify(value, stringify_options, out_stream);
}

const loose_parse_options = json.ParseOptions{
    .ignore_unknown_fields = true,
    .max_value_len = max_json_size,
};

const strict_parse_options = json.ParseOptions{
    .ignore_unknown_fields = true,
    .max_value_len = max_json_size,
};

pub fn parse(comptime T: type, s: []const u8) json.ParseError(json.Scanner)!json.Parsed(T) {
    return json.parseFromSlice(T, allocator, s, loose_parse_options);
}

pub fn parseStrict(comptime T: type, s: []const u8) json.ParseError(json.Scanner)!json.Parsed(T) {
    return json.parseFromSlice(T, allocator, s, strict_parse_options);
}
