const std = @import("std");
const user = @import("../user.zig");
const Allocator = std.mem.Allocator;
const Resource = @import("../config.zig").Resource;

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

pub fn fromResource(allocator: Allocator, resource: Resource) !Acl {
    var acl = Acl{
        .allocator = allocator,
        .name = resource.name,
        .ip_ranges = IpRangeMap.init(allocator),
    };
    try acl.initGrants(allocator, resource);
    return acl;
}

fn initGrants(self: *Acl, allocator: Allocator, resource: Resource) !void {
    for (resource.acl) |grant| {
        if (grant.user) |username| {
            if (resolveUser(username)) |uid| {
                try self.allow_uids.append(allocator, uid);

                if (grant.ips) |ips| {
                    const ranges = try parseIpRanges(allocator, ips);
                    try self.ip_ranges.put(uid, ranges);
                }
            } else {
                std.log.warn("Failed to resolve user '{s}', ignore it.", .{username});
            }
        }

        if (grant.group) |groupname| {
            if (resolveGroup(groupname)) |gid| {
                try self.allow_gids.append(allocator, gid);
            } else {
                std.log.warn("Failed to resolve group '{s}', ignore it.", .{groupname});
            }
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

test "isAllowed() should fail if acl is empty" {
    const allocator = std.testing.allocator;
    var acl = try fromResource(allocator, Resource{
        .name = "test",
        .interface = .{ .type = "macvlan", .master = "eth0" },
        .ipam = .{ .dhcp = .{} },
        .acl = &[_]Resource.Grant{},
    });
    defer acl.deinit();
    try std.testing.expectEqual(false, acl.isAllowed(0, 0));
}

test "isAllowed() should succeed if uid is allowed" {
    const allocator = std.testing.allocator;
    var acl = try fromResource(
        allocator,
        Resource{
            .name = "test",
            .interface = .{ .type = "macvlan", .master = "eth0" },
            .ipam = .{ .dhcp = .{} },
            .acl = &[_]Resource.Grant{
                .{ .user = "root" },
            },
        },
    );
    defer acl.deinit();
    try std.testing.expectEqual(true, acl.isAllowed(0, 0));
}

test "isAllowed() should succeed if gid is allowed" {
    const allocator = std.testing.allocator;
    var acl = try fromResource(
        allocator,
        Resource{
            .name = "test",
            .interface = .{ .type = "macvlan", .master = "eth0" },
            .ipam = .{ .dhcp = .{} },
            .acl = &[_]Resource.Grant{
                .{ .group = "root" },
            },
        },
    );
    defer acl.deinit();
    try std.testing.expectEqual(true, acl.isAllowed(0, 0));
}

test "isAllowed() with numeric uid in grant" {
    const allocator = std.testing.allocator;
    var acl = try fromResource(
        allocator,
        Resource{
            .name = "test",
            .interface = .{ .type = "macvlan", .master = "eth0" },
            .ipam = .{ .dhcp = .{} },
            .acl = &[_]Resource.Grant{
                .{ .user = "333" },
                .{ .group = "333" },
            },
        },
    );
    defer acl.deinit();

    try std.testing.expectEqual(true, acl.isAllowed(333, 0));
    try std.testing.expectEqual(true, acl.isAllowed(0, 333));
    try std.testing.expectEqual(false, acl.isAllowed(100, 100));
}

test "hasAnyAllow() returns false for empty acl" {
    const allocator = std.testing.allocator;
    var acl = try fromResource(allocator, Resource{
        .name = "test",
        .interface = .{ .type = "macvlan", .master = "eth0" },
        .ipam = .{ .dhcp = .{} },
        .acl = &[_]Resource.Grant{},
    });
    defer acl.deinit();
    try std.testing.expectEqual(false, acl.hasAnyAllow());
}

test "hasAnyAllow() returns true when users are present" {
    const allocator = std.testing.allocator;
    var acl = try fromResource(allocator, Resource{
        .name = "test",
        .interface = .{ .type = "macvlan", .master = "eth0" },
        .ipam = .{ .dhcp = .{} },
        .acl = &[_]Resource.Grant{
            .{ .user = "root" },
        },
    });
    defer acl.deinit();
    try std.testing.expectEqual(true, acl.hasAnyAllow());
}

test "isStatic() returns false when no ip ranges" {
    const allocator = std.testing.allocator;
    var acl = try fromResource(allocator, Resource{
        .name = "test",
        .interface = .{ .type = "macvlan", .master = "eth0" },
        .ipam = .{ .dhcp = .{} },
        .acl = &[_]Resource.Grant{
            .{ .user = "root" },
        },
    });
    defer acl.deinit();
    try std.testing.expectEqual(false, acl.isStatic());
}

test "isStatic() returns true when ip ranges exist" {
    const allocator = std.testing.allocator;
    var acl = try fromResource(allocator, Resource{
        .name = "test",
        .interface = .{ .type = "macvlan", .master = "eth0" },
        .ipam = .{ .static = .{ .addresses = &[_]Resource.Address{} } },
        .acl = &[_]Resource.Grant{
            .{ .user = "1000", .ips = &[_][:0]const u8{"192.168.1.10-192.168.1.20"} },
        },
    });
    defer acl.deinit();
    try std.testing.expectEqual(true, acl.isStatic());
}

test "isIpAllowed() validates IP against ranges" {
    const allocator = std.testing.allocator;
    var acl = try fromResource(allocator, Resource{
        .name = "test",
        .interface = .{ .type = "macvlan", .master = "eth0" },
        .ipam = .{ .static = .{ .addresses = &[_]Resource.Address{} } },
        .acl = &[_]Resource.Grant{
            .{ .user = "1000", .ips = &[_][:0]const u8{
                "192.168.1.10-192.168.1.20",
                "10.0.0.5-10.0.0.10",
            } },
        },
    });
    defer acl.deinit();

    // uid 1000 is allowed
    try std.testing.expect(acl.isIpAllowed(1000, "192.168.1.15"));
    try std.testing.expect(acl.isIpAllowed(1000, "192.168.1.10")); // boundary
    try std.testing.expect(acl.isIpAllowed(1000, "192.168.1.20")); // boundary
    try std.testing.expect(acl.isIpAllowed(1000, "10.0.0.7"));
    // uid 1000 not in range
    try std.testing.expect(!acl.isIpAllowed(1000, "192.168.1.30"));
    try std.testing.expect(!acl.isIpAllowed(1000, "10.0.0.1"));
    // uid 1001 has no ranges
    try std.testing.expect(!acl.isIpAllowed(1001, "192.168.1.15"));
}

test "isIpAllowed() with single IP" {
    const allocator = std.testing.allocator;
    var acl = try fromResource(allocator, Resource{
        .name = "test",
        .interface = .{ .type = "macvlan", .master = "eth0" },
        .ipam = .{ .static = .{ .addresses = &[_]Resource.Address{} } },
        .acl = &[_]Resource.Grant{
            .{ .user = "1000", .ips = &[_][:0]const u8{"192.168.1.50"} },
        },
    });
    defer acl.deinit();

    try std.testing.expect(acl.isIpAllowed(1000, "192.168.1.50"));
    try std.testing.expect(!acl.isIpAllowed(1000, "192.168.1.51"));
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
    // 255.255.255.255 - max IP
    const max_ip = try parseIpToInt("255.255.255.255");
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), max_ip);

    // 1.2.3.4 - small values
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
    // First range
    try std.testing.expectEqual(@as(u32, 0xC0A8010A), ranges.items[0].start);
    try std.testing.expectEqual(@as(u32, 0xC0A80114), ranges.items[0].end);
    // Second range
    try std.testing.expectEqual(@as(u32, 0x0A000005), ranges.items[1].start);
    try std.testing.expectEqual(@as(u32, 0x0A00000A), ranges.items[1].end);
    // Single IP
    try std.testing.expectEqual(@as(u32, 0xAC100001), ranges.items[2].start);
    try std.testing.expectEqual(@as(u32, 0xAC100001), ranges.items[2].end);
}

test "isIpAllowed() returns false for invalid IP string" {
    const allocator = std.testing.allocator;
    var acl = try fromResource(allocator, Resource{
        .name = "test",
        .interface = .{ .type = "macvlan", .master = "eth0" },
        .ipam = .{ .static = .{ .addresses = &[_]Resource.Address{} } },
        .acl = &[_]Resource.Grant{
            .{ .user = "1000", .ips = &[_][:0]const u8{"192.168.1.10-192.168.1.20"} },
        },
    });
    defer acl.deinit();

    try std.testing.expect(!acl.isIpAllowed(1000, "not-an-ip"));
    try std.testing.expect(!acl.isIpAllowed(1000, ""));
    try std.testing.expect(!acl.isIpAllowed(1000, "999.999.999.999"));
}

test "isIpAllowed() with multiple disjoint ranges for same user" {
    const allocator = std.testing.allocator;
    var acl = try fromResource(allocator, Resource{
        .name = "test",
        .interface = .{ .type = "macvlan", .master = "eth0" },
        .ipam = .{ .static = .{ .addresses = &[_]Resource.Address{} } },
        .acl = &[_]Resource.Grant{
            .{
                .user = "1000",
                .ips = &[_][:0]const u8{
                    "10.0.0.5-10.0.0.10",
                    "10.0.1.100-10.0.1.110",
                },
            },
        },
    });
    defer acl.deinit();

    try std.testing.expect(acl.isIpAllowed(1000, "10.0.0.7"));
    try std.testing.expect(acl.isIpAllowed(1000, "10.0.1.105"));
    try std.testing.expect(!acl.isIpAllowed(1000, "10.0.0.15")); // gap between ranges
    try std.testing.expect(!acl.isIpAllowed(1000, "10.0.1.99")); // just before second range
}

test "fromResource with unresolvable user is skipped" {
    const allocator = std.testing.allocator;
    var acl = try fromResource(allocator, Resource{
        .name = "test",
        .interface = .{ .type = "macvlan", .master = "eth0" },
        .ipam = .{ .dhcp = .{} },
        .acl = &[_]Resource.Grant{
            .{ .user = "nonexistent-user-xyz" },
            .{ .user = "1000" },
        },
    });
    defer acl.deinit();

    // Only uid 1000 should be present
    try std.testing.expectEqual(@as(usize, 1), acl.allow_uids.items.len);
    try std.testing.expectEqual(@as(u32, 1000), acl.allow_uids.items[0]);
}

test "fromResource with unresolvable group is skipped" {
    const allocator = std.testing.allocator;
    var acl = try fromResource(allocator, Resource{
        .name = "test",
        .interface = .{ .type = "macvlan", .master = "eth0" },
        .ipam = .{ .dhcp = .{} },
        .acl = &[_]Resource.Grant{
            .{ .group = "nonexistent-group-xyz" },
            .{ .group = "100" },
        },
    });
    defer acl.deinit();

    try std.testing.expectEqual(@as(usize, 1), acl.allow_gids.items.len);
    try std.testing.expectEqual(@as(u32, 100), acl.allow_gids.items[0]);
}

test "fromResource with mixed user and group grants" {
    const allocator = std.testing.allocator;
    var acl = try fromResource(allocator, Resource{
        .name = "test",
        .interface = .{ .type = "macvlan", .master = "eth0" },
        .ipam = .{ .dhcp = .{} },
        .acl = &[_]Resource.Grant{
            .{ .user = "1000" },
            .{ .group = "100" },
            .{ .user = "2000" },
        },
    });
    defer acl.deinit();

    try std.testing.expectEqual(@as(usize, 2), acl.allow_uids.items.len);
    try std.testing.expectEqual(@as(usize, 1), acl.allow_gids.items.len);
    try std.testing.expect(acl.isAllowed(1000, 0));
    try std.testing.expect(acl.isAllowed(0, 100));
    try std.testing.expect(acl.isAllowed(2000, 0));
}
