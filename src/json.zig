const std = @import("std");
const json = std.json;

pub const Parsed = json.Parsed;
pub const max_json_size = 16 * 1024;

const stringify_options = json.StringifyOptions{
    .whitespace = .indent_2,
    .emit_null_optional_fields = false,
};

pub fn stringifyToStdout(value: anytype) !void {
    return stringify(value, std.io.getStdOut().writer());
}

pub fn stringify(value: anytype, out_stream: anytype) !void {
    return json.stringify(value, stringify_options, out_stream);
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

pub fn parseValueStrict(comptime T: type, allocator: std.mem.Allocator, s: json.Value) json.ParseError(json.Scanner)!json.Parsed(T) {
    return json.parseFromSlice(T, allocator, s, strict_parse_options);
}
