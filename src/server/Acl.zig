const std = @import("std");
const user = @import("../user.zig");
const Allocator = std.mem.Allocator;

const Acl = @This();

allocator: Allocator,
name: []const u8,
allow_uids: std.ArrayList(u32) = .empty,
allow_gids: std.ArrayList(u32) = .empty,
// IP ranges per uid (parsed from grants with ips)
ip_ranges: IpRangeMap,

const IpRangeMap = std.AutoHashMap(u32, std.ArrayList(IpRange));

pub const IpRange = struct {
    start: u32,
    end: u32,
};

/// Data for a single grant to be added to an Acl.
pub const GrantData = struct {
    user: ?[:0]const u8 = null,
    group: ?[:0]const u8 = null,
    ips: ?[]const [:0]const u8 = null,
};

/// Create an empty Acl for the given resource name.
pub fn init(allocator: Allocator, name: []const u8) Acl {
    return Acl{
        .allocator = allocator,
        .name = name,
        .ip_ranges = IpRangeMap.init(allocator),
    };
}

/// Add a grant (user/group with optional IPs) to this Acl.
pub fn addGrant(self: *Acl, allocator: Allocator, grant: GrantData) !void {
    if (grant.user) |username| {
        if (resolveUser(username)) |uid| {
            try self.allow_uids.append(allocator, uid);

            if (grant.ips) |ips| {
                const ranges = try parseIpRanges(allocator, ips);
                try self.ip_ranges.put(uid, ranges);
            }
        } else {
            std.log.warn("Failed to resolve user '{s}', ignoring grant.", .{username});
        }
    }

    if (grant.group) |groupname| {
        if (resolveGroup(groupname)) |gid| {
            try self.allow_gids.append(allocator, gid);
        } else {
            std.log.warn("Failed to resolve group '{s}', ignoring grant.", .{groupname});
        }
    }
}

pub fn deinit(self: *Acl) void {
    self.allow_uids.deinit(self.allocator);
    self.allow_gids.deinit(self.allocator);

    var it = self.ip_ranges.valueIterator();
    while (it.next()) |list| {
        list.*.deinit(self.allocator);
    }
    self.ip_ranges.deinit();
}

pub fn hasAnyAllow(self: Acl) bool {
    return self.allow_uids.items.len > 0 or self.allow_gids.items.len > 0;
}

pub fn isAllowed(self: Acl, uid: u32, gid: u32) bool {
    for (self.allow_uids.items) |allowed_uid| {
        if (allowed_uid == uid) return true;
    }
    for (self.allow_gids.items) |allowed_gid| {
        if (allowed_gid == gid) return true;
    }
    return false;
}

/// Whether this resource has IP constraints (static IP resource).
pub fn isStatic(self: Acl) bool {
    return self.ip_ranges.count() > 0;
}

/// Check if a uid is allowed to use the given IP address.
/// The IP should be a plain address without CIDR prefix (e.g. "192.168.1.15").
pub fn isIpAllowed(self: Acl, uid: u32, ip: []const u8) bool {
    const ranges = self.ip_ranges.get(uid) orelse return false;
    const ip_int = parseIpToInt(ip) catch return false;
    for (ranges.items) |range| {
        if (ip_int >= range.start and ip_int <= range.end) {
            return true;
        }
    }
    return false;
}

// -- Tests --

test "init creates empty acl" {
    const allocator = std.testing.allocator;
    var acl = init(allocator, "test");
    defer acl.deinit();

    try std.testing.expectEqualSlices(u8, "test", acl.name);
    try std.testing.expectEqual(@as(usize, 0), acl.allow_uids.items.len);
    try std.testing.expectEqual(@as(usize, 0), acl.allow_gids.items.len);
    try std.testing.expectEqual(false, acl.hasAnyAllow());
}

test "addGrant with user" {
    const allocator = std.testing.allocator;
    var acl = init(allocator, "test");
    defer acl.deinit();

    try acl.addGrant(allocator, .{ .user = "root" });

    try std.testing.expectEqual(@as(usize, 1), acl.allow_uids.items.len);
    try std.testing.expectEqual(@as(u32, 0), acl.allow_uids.items[0]);
    try std.testing.expect(acl.isAllowed(0, 0));
    try std.testing.expect(!acl.isAllowed(333, 0));
}

test "addGrant with group" {
    const allocator = std.testing.allocator;
    var acl = init(allocator, "test");
    defer acl.deinit();

    try acl.addGrant(allocator, .{ .group = "root" });

    try std.testing.expectEqual(@as(usize, 1), acl.allow_gids.items.len);
    try std.testing.expect(acl.isAllowed(0, 0));
}

test "addGrant with numeric uid" {
    const allocator = std.testing.allocator;
    var acl = init(allocator, "test");
    defer acl.deinit();

    try acl.addGrant(allocator, .{ .user = "333" });
    try acl.addGrant(allocator, .{ .group = "333" });

    try std.testing.expect(acl.isAllowed(333, 0));
    try std.testing.expect(acl.isAllowed(0, 333));
    try std.testing.expect(!acl.isAllowed(100, 100));
}

test "addGrant with ips" {
    const allocator = std.testing.allocator;
    var acl = init(allocator, "test");
    defer acl.deinit();

    try acl.addGrant(allocator, .{
        .user = "1000",
        .ips = &[_][:0]const u8{ "192.168.1.10-192.168.1.20", "10.0.0.5-10.0.0.10" },
    });

    try std.testing.expect(acl.isStatic());
    try std.testing.expect(acl.isIpAllowed(1000, "192.168.1.15"));
    try std.testing.expect(acl.isIpAllowed(1000, "10.0.0.7"));
    try std.testing.expect(!acl.isIpAllowed(1000, "192.168.1.30"));
    try std.testing.expect(!acl.isIpAllowed(1001, "192.168.1.15"));
}

test "addGrant with unresolvable user is skipped" {
    const allocator = std.testing.allocator;
    var acl = init(allocator, "test");
    defer acl.deinit();

    try acl.addGrant(allocator, .{ .user = "nonexistent-user-xyz" });
    try acl.addGrant(allocator, .{ .user = "1000" });

    try std.testing.expectEqual(@as(usize, 1), acl.allow_uids.items.len);
    try std.testing.expectEqual(@as(u32, 1000), acl.allow_uids.items[0]);
}

test "addGrant with unresolvable group is skipped" {
    const allocator = std.testing.allocator;
    var acl = init(allocator, "test");
    defer acl.deinit();

    try acl.addGrant(allocator, .{ .group = "nonexistent-group-xyz" });
    try acl.addGrant(allocator, .{ .group = "100" });

    try std.testing.expectEqual(@as(usize, 1), acl.allow_gids.items.len);
    try std.testing.expectEqual(@as(u32, 100), acl.allow_gids.items[0]);
}

test "addGrant with mixed user and group" {
    const allocator = std.testing.allocator;
    var acl = init(allocator, "test");
    defer acl.deinit();

    try acl.addGrant(allocator, .{ .user = "1000" });
    try acl.addGrant(allocator, .{ .group = "100" });
    try acl.addGrant(allocator, .{ .user = "2000" });

    try std.testing.expectEqual(@as(usize, 2), acl.allow_uids.items.len);
    try std.testing.expectEqual(@as(usize, 1), acl.allow_gids.items.len);
    try std.testing.expect(acl.isAllowed(1000, 0));
    try std.testing.expect(acl.isAllowed(0, 100));
    try std.testing.expect(acl.isAllowed(2000, 0));
}

test "isStatic returns false when no ip ranges" {
    const allocator = std.testing.allocator;
    var acl = init(allocator, "test");
    defer acl.deinit();

    try acl.addGrant(allocator, .{ .user = "1000" });
    try std.testing.expect(!acl.isStatic());
}

test "isIpAllowed with single IP" {
    const allocator = std.testing.allocator;
    var acl = init(allocator, "test");
    defer acl.deinit();

    try acl.addGrant(allocator, .{
        .user = "1000",
        .ips = &[_][:0]const u8{"192.168.1.50"},
    });

    try std.testing.expect(acl.isIpAllowed(1000, "192.168.1.50"));
    try std.testing.expect(!acl.isIpAllowed(1000, "192.168.1.51"));
}

test "isIpAllowed returns false for invalid IP string" {
    const allocator = std.testing.allocator;
    var acl = init(allocator, "test");
    defer acl.deinit();

    try acl.addGrant(allocator, .{
        .user = "1000",
        .ips = &[_][:0]const u8{"192.168.1.10-192.168.1.20"},
    });

    try std.testing.expect(!acl.isIpAllowed(1000, "not-an-ip"));
    try std.testing.expect(!acl.isIpAllowed(1000, ""));
    try std.testing.expect(!acl.isIpAllowed(1000, "999.999.999.999"));
}

test "isIpAllowed with multiple disjoint ranges for same user" {
    const allocator = std.testing.allocator;
    var acl = init(allocator, "test");
    defer acl.deinit();

    try acl.addGrant(allocator, .{
        .user = "1000",
        .ips = &[_][:0]const u8{
            "10.0.0.5-10.0.0.10",
            "10.0.1.100-10.0.1.110",
        },
    });

    try std.testing.expect(acl.isIpAllowed(1000, "10.0.0.7"));
    try std.testing.expect(acl.isIpAllowed(1000, "10.0.1.105"));
    try std.testing.expect(!acl.isIpAllowed(1000, "10.0.0.15"));
    try std.testing.expect(!acl.isIpAllowed(1000, "10.0.1.99"));
}

// -- Internal helpers --

fn resolveUser(username: [:0]const u8) ?u32 {
    if (std.fmt.parseUnsigned(u32, username, 10)) |uid| {
        return uid;
    } else |e| switch (e) {
        else => {},
    }
    return user.getUid(username);
}

fn resolveGroup(groupname: [:0]const u8) ?u32 {
    if (std.fmt.parseUnsigned(u32, groupname, 10)) |gid| {
        return gid;
    } else |e| switch (e) {
        else => {},
    }
    return user.getGid(groupname);
}

fn parseIpRanges(allocator: Allocator, ips: []const [:0]const u8) !std.ArrayList(IpRange) {
    var ranges = std.ArrayList(IpRange).empty;
    errdefer ranges.deinit(allocator);

    for (ips) |ip_spec| {
        try ranges.append(allocator, try parseIpRange(ip_spec));
    }
    return ranges;
}

fn parseIpRange(ip_spec: []const u8) !IpRange {
    // Check if it's a range (contains '-')
    if (std.mem.indexOf(u8, ip_spec, "-")) |dash_pos| {
        const start_str = std.mem.trim(u8, ip_spec[0..dash_pos], " ");
        const end_str = std.mem.trim(u8, ip_spec[dash_pos + 1 ..], " ");
        return IpRange{
            .start = try parseIpToInt(start_str),
            .end = try parseIpToInt(end_str),
        };
    } else {
        // Single IP
        const ip_int = try parseIpToInt(ip_spec);
        return IpRange{ .start = ip_int, .end = ip_int };
    }
}

fn parseIpToInt(ip: []const u8) !u32 {
    var parts = std.mem.splitScalar(u8, ip, '.');
    var result: u32 = 0;
    var count: u32 = 0;
    while (parts.next()) |part| : (count += 1) {
        if (count >= 4) return error.InvalidIp;
        const byte = std.fmt.parseUnsigned(u8, part, 10) catch return error.InvalidIp;
        result = (result << 8) | @as(u32, byte);
    }
    if (count != 4) return error.InvalidIp;
    return result;
}

test "parseIpToInt" {
    const ip = try parseIpToInt("192.168.1.15");
    try std.testing.expectEqual(@as(u32, 0xC0A8010F), ip);

    const ip2 = try parseIpToInt("10.0.0.1");
    try std.testing.expectEqual(@as(u32, 0x0A000001), ip2);

    const ip3 = try parseIpToInt("0.0.0.0");
    try std.testing.expectEqual(@as(u32, 0), ip3);

    try std.testing.expectError(error.InvalidIp, parseIpToInt("invalid"));
    try std.testing.expectError(error.InvalidIp, parseIpToInt("192.168.1"));
    try std.testing.expectError(error.InvalidIp, parseIpToInt("192.168.1.1.1"));
}

test "parseIpRange with range" {
    const range = try parseIpRange("192.168.1.10-192.168.1.20");
    try std.testing.expectEqual(@as(u32, 0xC0A8010A), range.start);
    try std.testing.expectEqual(@as(u32, 0xC0A80114), range.end);
}

test "parseIpRange with single IP" {
    const range = try parseIpRange("192.168.1.50");
    try std.testing.expectEqual(@as(u32, 0xC0A80132), range.start);
    try std.testing.expectEqual(@as(u32, 0xC0A80132), range.end);
}

test "parseIpToInt with boundary values" {
    const max_ip = try parseIpToInt("255.255.255.255");
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), max_ip);

    const small_ip = try parseIpToInt("1.2.3.4");
    try std.testing.expectEqual(@as(u32, 0x01020304), small_ip);
}

test "parseIpToInt rejects invalid inputs" {
    try std.testing.expectError(error.InvalidIp, parseIpToInt(""));
    try std.testing.expectError(error.InvalidIp, parseIpToInt("192.168.1.999"));
    try std.testing.expectError(error.InvalidIp, parseIpToInt("256.0.0.1"));
    try std.testing.expectError(error.InvalidIp, parseIpToInt("abc.def.ghi.jkl"));
    try std.testing.expectError(error.InvalidIp, parseIpToInt("192.168.1."));
    try std.testing.expectError(error.InvalidIp, parseIpToInt(".192.168.1.1"));
}

test "parseIpRange with whitespace around dash" {
    const range = try parseIpRange("192.168.1.10 - 192.168.1.20");
    try std.testing.expectEqual(@as(u32, 0xC0A8010A), range.start);
    try std.testing.expectEqual(@as(u32, 0xC0A80114), range.end);
}

test "parseIpRange rejects invalid IP in range" {
    try std.testing.expectError(error.InvalidIp, parseIpRange("192.168.1.10-invalid"));
    try std.testing.expectError(error.InvalidIp, parseIpRange("invalid-192.168.1.20"));
    try std.testing.expectError(error.InvalidIp, parseIpRange("-"));
    try std.testing.expectError(error.InvalidIp, parseIpRange(""));
}

test "parseIpRanges with multiple entries" {
    const allocator = std.testing.allocator;
    const ips = &[_][:0]const u8{
        "192.168.1.10-192.168.1.20",
        "10.0.0.5-10.0.0.10",
        "172.16.0.1",
    };
    var ranges = try parseIpRanges(allocator, ips);
    defer ranges.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), ranges.items.len);
    try std.testing.expectEqual(@as(u32, 0xC0A8010A), ranges.items[0].start);
    try std.testing.expectEqual(@as(u32, 0xC0A80114), ranges.items[0].end);
    try std.testing.expectEqual(@as(u32, 0x0A000005), ranges.items[1].start);
    try std.testing.expectEqual(@as(u32, 0x0A00000A), ranges.items[1].end);
    try std.testing.expectEqual(@as(u32, 0xAC100001), ranges.items[2].start);
    try std.testing.expectEqual(@as(u32, 0xAC100001), ranges.items[2].end);
}
