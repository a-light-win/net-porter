const std = @import("std");
const Resource = @This();

name: []const u8,
allow_users: ?[]const [:0]const u8 = null,
allow_groups: ?[]const [:0]const u8 = null,

test "Resource can be loaded from json" {
    const allocator = std.testing.allocator;
    const json = std.json;

    const data =
        \\ {
        \\    "name": "test",
        \\    "allow_users": ["root", "333"]
        \\}
    ;

    const parsed = try json.parseFromSlice(
        Resource,
        allocator,
        data,
        .{},
    );
    defer parsed.deinit();

    const resource = parsed.value;

    try std.testing.expectEqualSlices(u8, "test", resource.name);
}
