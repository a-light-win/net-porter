const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const AclFile = @This();

/// A single grant entry within an ACL file.
/// Specifies which resource the caller can access, with optional IP constraints.
pub const Grant = struct {
    resource: []const u8,
    ips: ?[]const [:0]const u8 = null,
};

/// Represents a single ACL file's contents.
/// User ACL: grants + optional rule collection references.
/// Rule collection: grants only (file named @<name>.json).
pub const Entry = struct {
    grants: []const Grant = &[_]Grant{},
    /// Names of rule collections to include (user ACL only).
    /// References @<name>.json files. These are NOT Linux groups — just reusable grant sets.
    groups: ?[]const []const u8 = null,
};

/// Parse an ACL entry from raw JSON bytes.
/// Returns a parsed Entry owned by the caller.
pub fn parseFromSlice(allocator: Allocator, bytes: []const u8) !json.Parsed(Entry) {
    return try json.parseFromSlice(Entry, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

// ============================================================
// Tests
// ============================================================

test "AclFile: parse entry with single grant" {
    const allocator = std.testing.allocator;
    const data =
        \\{
        \\  "grants": [
        \\    { "resource": "macvlan-dhcp" }
        \\  ]
        \\}
    ;

    const parsed = try parseFromSlice(allocator, data);
    defer parsed.deinit();

    const entry = parsed.value;
    try std.testing.expectEqual(@as(usize, 1), entry.grants.len);
    try std.testing.expectEqualSlices(u8, "macvlan-dhcp", entry.grants[0].resource);
    try std.testing.expect(entry.grants[0].ips == null);
}

test "AclFile: parse entry with multiple grants and ips" {
    const allocator = std.testing.allocator;
    const data =
        \\{
        \\  "grants": [
        \\    { "resource": "macvlan-dhcp" },
        \\    { "resource": "bridge-static", "ips": ["192.168.1.100-192.168.1.110"] }
        \\  ]
        \\}
    ;

    const parsed = try parseFromSlice(allocator, data);
    defer parsed.deinit();

    const entry = parsed.value;
    try std.testing.expectEqual(@as(usize, 2), entry.grants.len);
    try std.testing.expectEqualSlices(u8, "macvlan-dhcp", entry.grants[0].resource);
    try std.testing.expectEqualSlices(u8, "bridge-static", entry.grants[1].resource);
    try std.testing.expect(entry.grants[1].ips != null);
    try std.testing.expectEqual(@as(usize, 1), entry.grants[1].ips.?.len);
    try std.testing.expectEqualSlices(u8, "192.168.1.100-192.168.1.110", entry.grants[1].ips.?[0]);
}

test "AclFile: parse entry with IP ranges" {
    const allocator = std.testing.allocator;
    const data =
        \\{
        \\  "grants": [
        \\    { "resource": "static-net", "ips": ["192.168.1.10-192.168.1.20", "10.0.0.5"] }
        \\  ]
        \\}
    ;

    const parsed = try parseFromSlice(allocator, data);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.grants.len);
    try std.testing.expect(parsed.value.grants[0].ips != null);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.grants[0].ips.?.len);
}

test "AclFile: parse entry with empty grants" {
    const allocator = std.testing.allocator;
    const data =
        \\{
        \\  "user": "nobody",
        \\  "grants": []
        \\}
    ;

    const parsed = try parseFromSlice(allocator, data);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), parsed.value.grants.len);
}

test "AclFile: parse entry with groups" {
    const allocator = std.testing.allocator;
    const data =
        \\{
        \\  "grants": [
        \\    { "resource": "test" }
        \\  ],
        \\  "groups": ["dhcp-users", "static-users"]
        \\}
    ;

    const parsed = try parseFromSlice(allocator, data);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.grants.len);
    try std.testing.expect(parsed.value.groups != null);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.groups.?.len);
    try std.testing.expectEqualSlices(u8, "dhcp-users", parsed.value.groups.?[0]);
    try std.testing.expectEqualSlices(u8, "static-users", parsed.value.groups.?[1]);
}

test "AclFile: reject invalid JSON" {
    const allocator = std.testing.allocator;
    const data = "not valid json";
    try std.testing.expectError(error.SyntaxError, parseFromSlice(allocator, data));
}

test "AclFile: grant with multiple IPs" {
    const allocator = std.testing.allocator;
    const data =
        \\{
        \\  "grants": [
        \\    {
        \\      "resource": "multi-net",
        \\      "ips": ["10.0.0.1-10.0.0.100", "172.16.0.1", "192.168.0.0-192.168.0.255"]
        \\    }
        \\  ]
        \\}
    ;

    const parsed = try parseFromSlice(allocator, data);
    defer parsed.deinit();

    const ips = parsed.value.grants[0].ips.?;
    try std.testing.expectEqual(@as(usize, 3), ips.len);
    try std.testing.expectEqualSlices(u8, "10.0.0.1-10.0.0.100", ips[0]);
    try std.testing.expectEqualSlices(u8, "172.16.0.1", ips[1]);
    try std.testing.expectEqualSlices(u8, "192.168.0.0-192.168.0.255", ips[2]);
}

test "AclFile: unknown fields are ignored" {
    const allocator = std.testing.allocator;
    const data =
        \\{
        \\  "user": "legacy-field",
        \\  "group": "legacy-field",
        \\  "grants": [
        \\    { "resource": "test" }
        \\  ]
        \\}
    ;

    const parsed = try parseFromSlice(allocator, data);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.grants.len);
    try std.testing.expectEqualSlices(u8, "test", parsed.value.grants[0].resource);
}
