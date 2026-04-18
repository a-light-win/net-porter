const std = @import("std");
const json = std.json;

pub const Parsed = json.Parsed;
pub const max_json_size = 16 * 1024;

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

pub fn stringify(value: anytype, out_writer: *std.io.Writer) !void {
    return json.Stringify.value(value, stringify_options, out_writer);
}

const loose_parse_options = json.ParseOptions{
    .ignore_unknown_fields = true,
    .max_value_len = max_json_size,
};

const strict_parse_options = json.ParseOptions{
    .ignore_unknown_fields = false,
    .max_value_len = max_json_size,
};

pub fn parse(allocator: std.mem.Allocator, s: []const u8) json.ParseError(json.Scanner)!json.Value {
    var scanner = json.Scanner.initCompleteInput(allocator, s);
    defer scanner.deinit();
    return json.Value.jsonParse(allocator, &scanner, loose_parse_options);
}

pub fn parseStrict(allocator: std.mem.Allocator, s: []const u8) json.ParseError(json.Scanner)!json.Value {
    var scanner = json.Scanner.initCompleteInput(allocator, s);
    defer scanner.deinit();
    return json.Value.jsonParse(allocator, &scanner, strict_parse_options);
}

pub fn parseValue(comptime T: type, allocator: std.mem.Allocator, s: json.Value) json.ParseError(json.Scanner)!json.Parsed(T) {
    return json.parseFromValue(T, allocator, s, loose_parse_options);
}
