const std = @import("std");
const Allocator = std.mem.Allocator;

const Acl = @This();

allocator: Allocator,
/// Resource name this ACL entry controls.
name: []const u8,
/// IP ranges per uid (parsed from grants with ips).
/// In per-user daemon mode, this is keyed by the worker's UID.
ip_ranges: IpRangeMap,

const IpRangeMap = std.AutoHashMap(u32, std.ArrayList(IpRange));

pub const IpRange = struct {
    start: u128,
    end: u128,
};

/// Create an empty Acl for the given resource name.
pub fn init(allocator: Allocator, name: []const u8) Acl {
    return Acl{
        .allocator = allocator,
        .name = name,
        .ip_ranges = IpRangeMap.init(allocator),
    };
}

pub fn deinit(self: *Acl) void {
    var it = self.ip_ranges.valueIterator();
    while (it.next()) |list| {
        list.*.deinit(self.allocator);
    }
    self.ip_ranges.deinit();
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

pub fn parseIpRanges(allocator: Allocator, ips: []const [:0]const u8) !std.ArrayList(IpRange) {
    var ranges = std.ArrayList(IpRange).empty;
    errdefer ranges.deinit(allocator);

    for (ips) |ip_spec| {
        try ranges.append(allocator, try parseIpRange(ip_spec));
    }
    return ranges;
}

fn parseIpRange(ip_spec: []const u8) !IpRange {
    if (std.mem.indexOf(u8, ip_spec, "-")) |dash_pos| {
        const start_str = std.mem.trim(u8, ip_spec[0..dash_pos], " ");
        const end_str = std.mem.trim(u8, ip_spec[dash_pos + 1 ..], " ");
        const start = try parseIpToInt(start_str);
        const end = try parseIpToInt(end_str);
        if (start > end) return error.InvalidIpRange;
        return IpRange{ .start = start, .end = end };
    } else {
        const ip_int = try parseIpToInt(ip_spec);
        return IpRange{ .start = ip_int, .end = ip_int };
    }
}

fn parseIpToInt(ip: []const u8) !u128 {
    // Detect IPv6 by presence of ':'
    if (std.mem.indexOf(u8, ip, ":") != null) {
        return parseIpv6ToInt(ip);
    }
    return parseIpv4ToInt(ip);
}

fn parseIpv4ToInt(ip: []const u8) !u128 {
    var parts = std.mem.splitScalar(u8, ip, '.');
    var result: u32 = 0;
    var count: u32 = 0;
    while (parts.next()) |part| : (count += 1) {
        if (count >= 4) return error.InvalidIp;
        const byte = std.fmt.parseUnsigned(u8, part, 10) catch return error.InvalidIp;
        result = (result << 8) | @as(u32, byte);
    }
    if (count != 4) return error.InvalidIp;
    return @as(u128, result);
}

fn parseIpv6ToInt(ip: []const u8) !u128 {
    // Handle :: expansion
    // Strategy: split on '::', parse left and right halves, fill zeros in between
    const double_colon = std.mem.indexOf(u8, ip, "::");

    var left_str: []const u8 = "";
    var right_str: []const u8 = "";

    if (double_colon) |pos| {
        if (pos > 0) left_str = ip[0..pos];
        if (pos + 2 < ip.len) right_str = ip[pos + 2 ..];
    } else {
        left_str = ip;
    }

    var result: u128 = 0;
    var groups: u32 = 0;

    // Parse left part (before ::)
    if (left_str.len > 0) {
        var left_parts = std.mem.splitScalar(u8, left_str, ':');
        while (left_parts.next()) |part| {
            if (part.len == 0) return error.InvalidIp;
            const val = std.fmt.parseUnsigned(u16, part, 16) catch return error.InvalidIp;
            result = (result << 16) | @as(u128, val);
            groups += 1;
        }
    }

    // If no ::, right_str is empty; otherwise, insert zeros
    if (double_colon != null) {
        // Expand :: to fill remaining groups (total 8 groups for full IPv6)
        var right_groups: u32 = 0;
        // Count right groups first
        if (right_str.len > 0) {
            var right_parts = std.mem.splitScalar(u8, right_str, ':');
            while (right_parts.next()) |_| {
                right_groups += 1;
            }
        }
        const zeros_needed = 8 - groups - right_groups;
        if (zeros_needed > 8) return error.InvalidIp;
        const shift_bits = zeros_needed * 16;
        if (shift_bits > 0 and shift_bits < 128) {
            result = result << @intCast(shift_bits);
        }
        groups += zeros_needed;
    }

    // Parse right part (after ::)
    if (right_str.len > 0) {
        var right_parts = std.mem.splitScalar(u8, right_str, ':');
        while (right_parts.next()) |part| {
            if (part.len == 0) return error.InvalidIp;
            const val = std.fmt.parseUnsigned(u16, part, 16) catch return error.InvalidIp;
            result = (result << 16) | @as(u128, val);
            groups += 1;
        }
    }

    if (groups != 8) return error.InvalidIp;
    return result;
}

// ============================================================
// Tests
// ============================================================

test "init creates empty acl" {
    const allocator = std.testing.allocator;
    var acl = init(allocator, "test");
    defer acl.deinit();

    try std.testing.expectEqualSlices(u8, "test", acl.name);
    try std.testing.expectEqual(@as(usize, 0), acl.ip_ranges.count());
    try std.testing.expect(!acl.isStatic());
}

test "isStatic with ip ranges" {
    const allocator = std.testing.allocator;
    var acl = init(allocator, "test");
    defer acl.deinit();

    const ips = &[_][:0]const u8{ "192.168.1.10-192.168.1.20", "10.0.0.5-10.0.0.10" };
    const ranges = try parseIpRanges(allocator, ips);
    // Ownership transferred to acl.ip_ranges via put — do NOT deinit ranges separately.
    try acl.ip_ranges.put(1000, ranges);

    try std.testing.expect(acl.isStatic());
}

test "isIpAllowed with ip ranges" {
    const allocator = std.testing.allocator;
    var acl = init(allocator, "test");
    defer acl.deinit();

    const ips = &[_][:0]const u8{ "192.168.1.10-192.168.1.20", "10.0.0.5-10.0.0.10" };
    const ranges = try parseIpRanges(allocator, ips);
    try acl.ip_ranges.put(1000, ranges);

    try std.testing.expect(acl.isIpAllowed(1000, "192.168.1.15"));
    try std.testing.expect(acl.isIpAllowed(1000, "10.0.0.7"));
    try std.testing.expect(!acl.isIpAllowed(1000, "192.168.1.30"));
    try std.testing.expect(!acl.isIpAllowed(1001, "192.168.1.15"));
}

test "isIpAllowed with single IP" {
    const allocator = std.testing.allocator;
    var acl = init(allocator, "test");
    defer acl.deinit();

    const ips = &[_][:0]const u8{"192.168.1.50"};
    const ranges = try parseIpRanges(allocator, ips);
    try acl.ip_ranges.put(1000, ranges);

    try std.testing.expect(acl.isIpAllowed(1000, "192.168.1.50"));
    try std.testing.expect(!acl.isIpAllowed(1000, "192.168.1.51"));
}

test "isIpAllowed returns false for invalid IP string" {
    const allocator = std.testing.allocator;
    var acl = init(allocator, "test");
    defer acl.deinit();

    const ips = &[_][:0]const u8{"192.168.1.10-192.168.1.20"};
    const ranges = try parseIpRanges(allocator, ips);
    try acl.ip_ranges.put(1000, ranges);

    try std.testing.expect(!acl.isIpAllowed(1000, "not-an-ip"));
    try std.testing.expect(!acl.isIpAllowed(1000, ""));
    try std.testing.expect(!acl.isIpAllowed(1000, "999.999.999.999"));
}

test "isIpAllowed with multiple disjoint ranges for same user" {
    const allocator = std.testing.allocator;
    var acl = init(allocator, "test");
    defer acl.deinit();

    const ips = &[_][:0]const u8{
        "10.0.0.5-10.0.0.10",
        "10.0.1.100-10.0.1.110",
    };
    const ranges = try parseIpRanges(allocator, ips);
    try acl.ip_ranges.put(1000, ranges);

    try std.testing.expect(acl.isIpAllowed(1000, "10.0.0.7"));
    try std.testing.expect(acl.isIpAllowed(1000, "10.0.1.105"));
    try std.testing.expect(!acl.isIpAllowed(1000, "10.0.0.15"));
    try std.testing.expect(!acl.isIpAllowed(1000, "10.0.1.99"));
}

test "isIpAllowed returns false when uid has no ranges" {
    const allocator = std.testing.allocator;
    var acl = init(allocator, "test");
    defer acl.deinit();

    try std.testing.expect(!acl.isIpAllowed(9999, "192.168.1.1"));
}

test "isIpAllowed with IPv6 range" {
    const allocator = std.testing.allocator;
    var acl = init(allocator, "test");
    defer acl.deinit();

    const ips = &[_][:0]const u8{"2001:db8::1-2001:db8::ff"};
    const ranges = try parseIpRanges(allocator, ips);
    try acl.ip_ranges.put(1000, ranges);

    try std.testing.expect(acl.isIpAllowed(1000, "2001:db8::1"));
    try std.testing.expect(acl.isIpAllowed(1000, "2001:db8::80"));
    try std.testing.expect(acl.isIpAllowed(1000, "2001:db8::ff"));
    try std.testing.expect(!acl.isIpAllowed(1000, "2001:db8::100"));
    try std.testing.expect(!acl.isIpAllowed(1000, "2001:db8::0"));
    try std.testing.expect(!acl.isIpAllowed(1001, "2001:db8::1"));
}

test "isIpAllowed with single IPv6" {
    const allocator = std.testing.allocator;
    var acl = init(allocator, "test");
    defer acl.deinit();

    const ips = &[_][:0]const u8{"::1"};
    const ranges = try parseIpRanges(allocator, ips);
    try acl.ip_ranges.put(1000, ranges);

    try std.testing.expect(acl.isIpAllowed(1000, "::1"));
    try std.testing.expect(!acl.isIpAllowed(1000, "::2"));
}

test "parseIpToInt" {
    const ip = try parseIpToInt("192.168.1.15");
    try std.testing.expectEqual(@as(u128, 0xC0A8010F), ip);

    const ip2 = try parseIpToInt("10.0.0.1");
    try std.testing.expectEqual(@as(u128, 0x0A000001), ip2);

    const ip3 = try parseIpToInt("0.0.0.0");
    try std.testing.expectEqual(@as(u128, 0), ip3);

    try std.testing.expectError(error.InvalidIp, parseIpToInt("invalid"));
    try std.testing.expectError(error.InvalidIp, parseIpToInt("192.168.1"));
    try std.testing.expectError(error.InvalidIp, parseIpToInt("192.168.1.1.1"));
}

test "parseIpToInt IPv6" {
    // Full form
    const ip_full = try parseIpToInt("2001:0db8:0000:0000:0000:0000:0000:0001");
    try std.testing.expectEqual(@as(u128, 0x20010DB8000000000000000000000001), ip_full);

    // Compressed form ::1
    const ip_loopback = try parseIpToInt("::1");
    try std.testing.expectEqual(@as(u128, 0x00000000000000000000000000000001), ip_loopback);

    // Compressed form with prefix 2001:db8::1
    const ip_compressed = try parseIpToInt("2001:db8::1");
    try std.testing.expectEqual(@as(u128, 0x20010DB8000000000000000000000001), ip_compressed);

    // All zeros ::
    const ip_all_zeros = try parseIpToInt("::");
    try std.testing.expectEqual(@as(u128, 0), ip_all_zeros);

    // Link-local fe80::1
    const ip_link_local = try parseIpToInt("fe80::1");
    try std.testing.expectEqual(@as(u128, 0xFE800000000000000000000000000001), ip_link_local);

    // Reject invalid IPv6
    try std.testing.expectError(error.InvalidIp, parseIpToInt(":::1"));
    try std.testing.expectError(error.InvalidIp, parseIpToInt("2001:db8:::1"));
    try std.testing.expectError(error.InvalidIp, parseIpToInt("2001:db8::1::2"));
}

test "parseIpRange with range" {
    const range = try parseIpRange("192.168.1.10-192.168.1.20");
    try std.testing.expectEqual(@as(u128, 0xC0A8010A), range.start);
    try std.testing.expectEqual(@as(u128, 0xC0A80114), range.end);
}

test "parseIpRange with single IP" {
    const range = try parseIpRange("192.168.1.50");
    try std.testing.expectEqual(@as(u128, 0xC0A80132), range.start);
    try std.testing.expectEqual(@as(u128, 0xC0A80132), range.end);
}

test "parseIpToInt with boundary values" {
    const max_ip = try parseIpToInt("255.255.255.255");
    try std.testing.expectEqual(@as(u128, 0xFFFFFFFF), max_ip);

    const small_ip = try parseIpToInt("1.2.3.4");
    try std.testing.expectEqual(@as(u128, 0x01020304), small_ip);
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
    try std.testing.expectEqual(@as(u128, 0xC0A8010A), range.start);
    try std.testing.expectEqual(@as(u128, 0xC0A80114), range.end);
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
    try std.testing.expectEqual(@as(u128, 0xC0A8010A), ranges.items[0].start);
    try std.testing.expectEqual(@as(u128, 0xC0A80114), ranges.items[0].end);
    try std.testing.expectEqual(@as(u128, 0x0A000005), ranges.items[1].start);
    try std.testing.expectEqual(@as(u128, 0x0A00000A), ranges.items[1].end);
    try std.testing.expectEqual(@as(u128, 0xAC100001), ranges.items[2].start);
    try std.testing.expectEqual(@as(u128, 0xAC100001), ranges.items[2].end);
}

test "parseIpRange with IPv6 range" {
    const range = try parseIpRange("2001:db8::1-2001:db8::ff");
    try std.testing.expectEqual(@as(u128, 0x20010DB8000000000000000000000001), range.start);
    try std.testing.expectEqual(@as(u128, 0x20010DB80000000000000000000000FF), range.end);
}

test "parseIpRange with single IPv6" {
    const range = try parseIpRange("::1");
    try std.testing.expectEqual(@as(u128, 0x00000000000000000000000000000001), range.start);
    try std.testing.expectEqual(@as(u128, 0x00000000000000000000000000000001), range.end);
}
