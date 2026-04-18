const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const AclFile = @This();

/// A single grant entry within an ACL file.
/// Specifies which resource the user/group can access, with optional IP constraints.
pub const Grant = struct {
    resource: []const u8,
    ips: ?[]const [:0]const u8 = null,
};

/// Represents a single ACL file's contents.
/// User ACL: grants + optional group references.
/// Group ACL: grants only (file named @<group>.json).
pub const Entry = struct {
    user: ?[:0]const u8 = null,
    group: ?[:0]const u8 = null,
    grants: []const Grant = &[_]Grant{},
    /// Names of ACL groups to include (user ACL only).
    /// Group files are named @<name>.json in the same directory.
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

test "AclFile: parse entry with user and single grant" {
    const allocator = std.testing.allocator;
    const data =
        \\{
        \\  "user": "jellyfin",
        \\  "grants": [
        \\    { "resource": "macvlan-dhcp" }
        \\  ]
        \\}
    ;

    const parsed = try parseFromSlice(allocator, data);
    defer parsed.deinit();

    const entry = parsed.value;
    try std.testing.expect(entry.user != null);
    try std.testing.expectEqualSlices(u8, "jellyfin", entry.user.?);
    try std.testing.expect(entry.group == null);
    try std.testing.expectEqual(@as(usize, 1), entry.grants.len);
    try std.testing.expectEqualSlices(u8, "macvlan-dhcp", entry.grants[0].resource);
    try std.testing.expect(entry.grants[0].ips == null);
}

test "AclFile: parse entry with group and multiple grants" {
    const allocator = std.testing.allocator;
    const data =
        \\{
        \\  "group": "media",
        \\  "grants": [
        \\    { "resource": "macvlan-dhcp" },
        \\    { "resource": "bridge-static", "ips": ["192.168.1.100-192.168.1.110"] }
        \\  ]
        \\}
    ;

    const parsed = try parseFromSlice(allocator, data);
    defer parsed.deinit();

    const entry = parsed.value;
    try std.testing.expect(entry.user == null);
    try std.testing.expect(entry.group != null);
    try std.testing.expectEqualSlices(u8, "media", entry.group.?);
    try std.testing.expectEqual(@as(usize, 2), entry.grants.len);
    try std.testing.expectEqualSlices(u8, "macvlan-dhcp", entry.grants[0].resource);
    try std.testing.expectEqualSlices(u8, "bridge-static", entry.grants[1].resource);
    try std.testing.expect(entry.grants[1].ips != null);
    try std.testing.expectEqual(@as(usize, 1), entry.grants[1].ips.?.len);
    try std.testing.expectEqualSlices(u8, "192.168.1.100-192.168.1.110", entry.grants[1].ips.?[0]);
}

test "AclFile: parse entry with user and IP ranges" {
    const allocator = std.testing.allocator;
    const data =
        \\{
        \\  "user": "1000",
        \\  "grants": [
        \\    { "resource": "static-net", "ips": ["192.168.1.10-192.168.1.20", "10.0.0.5"] }
        \\  ]
        \\}
    ;

    const parsed = try parseFromSlice(allocator, data);
    defer parsed.deinit();

    const entry = parsed.value;
    try std.testing.expectEqualSlices(u8, "1000", entry.user.?);
    try std.testing.expectEqual(@as(usize, 1), entry.grants.len);
    try std.testing.expect(entry.grants[0].ips != null);
    try std.testing.expectEqual(@as(usize, 2), entry.grants[0].ips.?.len);
}

test "AclFile: parse entry with both user and group" {
    const allocator = std.testing.allocator;
    const data =
        \\{
        \\  "user": "alice",
        \\  "group": "devops",
        \\  "grants": [
        \\    { "resource": "macvlan-dhcp" }
        \\  ]
        \\}
    ;

    const parsed = try parseFromSlice(allocator, data);
    defer parsed.deinit();

    const entry = parsed.value;
    try std.testing.expect(entry.user != null);
    try std.testing.expect(entry.group != null);
    try std.testing.expectEqualSlices(u8, "alice", entry.user.?);
    try std.testing.expectEqualSlices(u8, "devops", entry.group.?);
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

test "AclFile: parse entry without optional fields" {
    const allocator = std.testing.allocator;
    const data =
        \\{
        \\  "grants": [
        \\    { "resource": "test" }
        \\  ]
        \\}
    ;

    const parsed = try parseFromSlice(allocator, data);
    defer parsed.deinit();

    try std.testing.expect(parsed.value.user == null);
    try std.testing.expect(parsed.value.group == null);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.grants.len);
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
        \\  "user": "admin",
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
