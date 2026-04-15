const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const ParseOptions = json.ParseOptions;
const innerParseFromValue = json.innerParseFromValue;
const Value = json.Value;
const Resource = @This();

name: []const u8,
interface: Interface,
ipam: IpamConfig,
acl: []const Grant,

pub const Grant = struct {
    user: ?[:0]const u8 = null,
    group: ?[:0]const u8 = null,
    ips: ?[]const [:0]const u8 = null,
};

pub const Interface = struct {
    type: []const u8,
    master: []const u8,
    mode: ?[]const u8 = null,
    mtu: ?u32 = null,
};

// ============================================================
// CNI-aligned IPAM types
// ============================================================

/// A single address entry with optional gateway.
/// In config: address is the subnet CIDR template (e.g. "192.168.1.0/24").
/// At runtime: address is replaced with actual IP + prefix (e.g. "192.168.1.10/24").
pub const Address = struct {
    address: []const u8,
    gateway: ?[]const u8 = null,
};

/// A route entry with optional gateway override and priority.
pub const Route = struct {
    dst: []const u8,
    gw: ?[]const u8 = null,
    priority: ?u32 = null,
};

/// DNS configuration.
pub const Dns = struct {
    nameservers: ?[]const []const u8 = null,
    domain: ?[]const u8 = null,
    search: ?[]const []const u8 = null,
    options: ?[]const []const u8 = null,
};

/// Static IPAM configuration: addresses, routes, and DNS.
pub const StaticConfig = struct {
    addresses: []const Address,
    routes: ?[]const Route = null,
    dns: ?Dns = null,
};

/// DHCP IPAM configuration: optional daemon socket path override.
pub const DhcpConfig = struct {
    daemon_socket_path: ?[]const u8 = null,
};

/// Tagged union for IPAM configuration.
/// Uses "type" field as discriminator when parsing from JSON.
pub const IpamConfig = union(enum) {
    static: StaticConfig,
    dhcp: DhcpConfig,

    pub fn jsonParse(
        allocator: Allocator,
        source: anytype,
        options: ParseOptions,
    ) !@This() {
        const raw_value = try Value.jsonParse(allocator, source, options);
        return jsonParseFromValue(allocator, raw_value, options);
    }

    pub fn jsonParseFromValue(
        allocator: Allocator,
        source: Value,
        options: ParseOptions,
    ) !@This() {
        if (source != .object) return error.UnexpectedToken;
        const obj = source.object;

        // Read "type" discriminator
        const type_val = obj.get("type") orelse return error.MissingField;
        if (type_val != .string) return error.UnexpectedToken;

        // Allow child structs to skip the "type" field (it belongs to the union, not them)
        var relaxed = options;
        relaxed.ignore_unknown_fields = true;

        const IpamTag = enum { static, dhcp };
        const tag = std.meta.stringToEnum(IpamTag, type_val.string) orelse return error.InvalidEnumTag;

        switch (tag) {
            .static => return .{ .static = try innerParseFromValue(StaticConfig, allocator, source, relaxed) },
            .dhcp => return .{ .dhcp = try innerParseFromValue(DhcpConfig, allocator, source, relaxed) },
        }
    }
};

// ============================================================
// Tests
// ============================================================

test "Resource can be loaded from json - dhcp" {
    const allocator = std.testing.allocator;

    const data =
        \\{
        \\    "name": "test",
        \\    "interface": {
        \\        "type": "macvlan",
        \\        "master": "eth0"
        \\    },
        \\    "ipam": {
        \\        "type": "dhcp"
        \\    },
        \\    "acl": [
        \\        { "user": "alice" },
        \\        { "group": "devops" }
        \\    ]
        \\}
    ;

    const parsed = try json.parseFromSlice(Resource, allocator, data, .{});
    defer parsed.deinit();

    const resource = parsed.value;

    try std.testing.expectEqualSlices(u8, "test", resource.name);
    try std.testing.expectEqualSlices(u8, "macvlan", resource.interface.type);
    try std.testing.expectEqualSlices(u8, "eth0", resource.interface.master);
    try std.testing.expect(resource.ipam == .dhcp);
    try std.testing.expectEqual(@as(usize, 2), resource.acl.len);
    try std.testing.expectEqualSlices(u8, "alice", resource.acl[0].user.?);
    try std.testing.expectEqualSlices(u8, "devops", resource.acl[1].group.?);
}

test "Resource with static ipam and ip ranges can be loaded from json" {
    const allocator = std.testing.allocator;

    const data =
        \\{
        \\    "name": "macvlan-static",
        \\    "interface": {
        \\        "type": "macvlan",
        \\        "master": "eth0",
        \\        "mode": "bridge"
        \\    },
        \\    "ipam": {
        \\        "type": "static",
        \\        "addresses": [
        \\            { "address": "192.168.1.0/24", "gateway": "192.168.1.1" }
        \\        ],
        \\        "routes": [
        \\            { "dst": "0.0.0.0/0" }
        \\        ]
        \\    },
        \\    "acl": [
        \\        {
        \\            "user": "alice",
        \\            "ips": ["192.168.1.10-192.168.1.20"]
        \\        },
        \\        {
        \\            "user": "1002",
        \\            "ips": ["192.168.1.50"]
        \\        }
        \\    ]
        \\}
    ;

    const parsed = try json.parseFromSlice(Resource, allocator, data, .{});
    defer parsed.deinit();

    const resource = parsed.value;

    try std.testing.expectEqualSlices(u8, "macvlan-static", resource.name);
    try std.testing.expect(resource.ipam == .static);

    const s = resource.ipam.static;
    try std.testing.expectEqual(@as(usize, 1), s.addresses.len);
    try std.testing.expectEqualSlices(u8, "192.168.1.0/24", s.addresses[0].address);
    try std.testing.expectEqualSlices(u8, "192.168.1.1", s.addresses[0].gateway.?);
    try std.testing.expect(s.routes != null);
    try std.testing.expectEqualSlices(u8, "0.0.0.0/0", s.routes.?[0].dst);
    try std.testing.expectEqual(@as(usize, 2), resource.acl.len);

    const alice_grant = resource.acl[0];
    try std.testing.expectEqualSlices(u8, "alice", alice_grant.user.?);
    try std.testing.expect(alice_grant.ips != null);
    try std.testing.expectEqual(@as(usize, 1), alice_grant.ips.?.len);
    try std.testing.expectEqualSlices(u8, "192.168.1.10-192.168.1.20", alice_grant.ips.?[0]);
}

test "Resource with all optional fields populated" {
    const allocator = std.testing.allocator;

    const data =
        \\{
        \\    "name": "full-resource",
        \\    "interface": {
        \\        "type": "macvlan",
        \\        "master": "bond0",
        \\        "mode": "bridge",
        \\        "mtu": 9000
        \\    },
        \\    "ipam": {
        \\        "type": "static",
        \\        "addresses": [
        \\            { "address": "10.0.0.0/16", "gateway": "10.0.0.1" }
        \\        ],
        \\        "routes": [
        \\            { "dst": "0.0.0.0/0" },
        \\            { "dst": "10.0.0.0/8", "gw": "10.0.0.254", "priority": 100 }
        \\        ],
        \\        "dns": {
        \\            "nameservers": ["8.8.8.8"],
        \\            "domain": "example.com",
        \\            "search": ["example.com"]
        \\        }
        \\    },
        \\    "acl": [
        \\        { "user": "alice", "ips": ["10.0.0.5-10.0.0.10", "10.0.1.0-10.0.1.5"] }
        \\    ]
        \\}
    ;

    const parsed = try json.parseFromSlice(Resource, allocator, data, .{});
    defer parsed.deinit();

    const r = parsed.value;
    try std.testing.expectEqualSlices(u8, "bond0", r.interface.master);
    try std.testing.expectEqualSlices(u8, "bridge", r.interface.mode.?);
    try std.testing.expectEqual(@as(u32, 9000), r.interface.mtu.?);

    try std.testing.expect(r.ipam == .static);
    const s = r.ipam.static;
    try std.testing.expectEqualSlices(u8, "10.0.0.1", s.addresses[0].gateway.?);
    try std.testing.expectEqual(@as(usize, 2), s.routes.?.len);
    try std.testing.expectEqualSlices(u8, "0.0.0.0/0", s.routes.?[0].dst);
    try std.testing.expectEqualSlices(u8, "10.0.0.0/8", s.routes.?[1].dst);
    try std.testing.expectEqualSlices(u8, "10.0.0.254", s.routes.?[1].gw.?);
    try std.testing.expectEqual(@as(u32, 100), s.routes.?[1].priority.?);

    try std.testing.expect(s.dns != null);
    try std.testing.expectEqualSlices(u8, "8.8.8.8", s.dns.?.nameservers.?[0]);
    try std.testing.expectEqualSlices(u8, "example.com", s.dns.?.domain.?);

    // Multiple ips in a single grant
    try std.testing.expectEqual(@as(usize, 2), r.acl[0].ips.?.len);
}

test "Resource with minimal fields - optional fields default to null" {
    const allocator = std.testing.allocator;

    const data =
        \\{
        \\    "name": "minimal",
        \\    "interface": {
        \\        "type": "macvlan",
        \\        "master": "eth0"
        \\    },
        \\    "ipam": {
        \\        "type": "dhcp"
        \\    },
        \\    "acl": [
        \\        { "user": "alice" }
        \\    ]
        \\}
    ;

    const parsed = try json.parseFromSlice(Resource, allocator, data, .{});
    defer parsed.deinit();

    const r = parsed.value;
    try std.testing.expect(r.interface.mode == null);
    try std.testing.expect(r.interface.mtu == null);
    try std.testing.expect(r.ipam == .dhcp);
    try std.testing.expect(r.ipam.dhcp.daemon_socket_path == null);
    try std.testing.expect(r.acl[0].ips == null);
    try std.testing.expect(r.acl[0].group == null);
}

test "Resource with grant having both user and group" {
    const allocator = std.testing.allocator;

    const data =
        \\{
        \\    "name": "test",
        \\    "interface": { "type": "macvlan", "master": "eth0" },
        \\    "ipam": { "type": "dhcp" },
        \\    "acl": [
        \\        { "user": "alice", "group": "devops" }
        \\    ]
        \\}
    ;

    const parsed = try json.parseFromSlice(Resource, allocator, data, .{});
    defer parsed.deinit();

    try std.testing.expectEqualSlices(u8, "alice", parsed.value.acl[0].user.?);
    try std.testing.expectEqualSlices(u8, "devops", parsed.value.acl[0].group.?);
}

test "Resource parsing fails for missing required fields" {
    const allocator = std.testing.allocator;

    // Missing interface
    const data_missing_interface =
        \\{ "name": "test", "ipam": { "type": "dhcp" }, "acl": [] }
    ;
    try std.testing.expectError(error.MissingField, json.parseFromSlice(Resource, allocator, data_missing_interface, .{}));

    // Missing ipam
    const data_missing_ipam =
        \\{ "name": "test", "interface": { "type": "macvlan", "master": "eth0" }, "acl": [] }
    ;
    try std.testing.expectError(error.MissingField, json.parseFromSlice(Resource, allocator, data_missing_ipam, .{}));
}

test "Resource with empty acl array parses successfully" {
    const allocator = std.testing.allocator;

    const data =
        \\{
        \\    "name": "empty-acl",
        \\    "interface": { "type": "macvlan", "master": "eth0" },
        \\    "ipam": { "type": "dhcp" },
        \\    "acl": []
        \\}
    ;

    const parsed = try json.parseFromSlice(Resource, allocator, data, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.acl.len);
}

test "IpamConfig rejects unknown type" {
    const allocator = std.testing.allocator;

    const data =
        \\{
        \\    "name": "bad",
        \\    "interface": { "type": "macvlan", "master": "eth0" },
        \\    "ipam": { "type": "host-local" },
        \\    "acl": []
        \\}
    ;

    try std.testing.expectError(
        error.InvalidEnumTag,
        json.parseFromSlice(Resource, allocator, data, .{}),
    );
}

test "IpamConfig rejects missing type" {
    const allocator = std.testing.allocator;

    const data =
        \\{
        \\    "name": "bad",
        \\    "interface": { "type": "macvlan", "master": "eth0" },
        \\    "ipam": { "addresses": [] },
        \\    "acl": []
        \\}
    ;

    try std.testing.expectError(
        error.MissingField,
        json.parseFromSlice(Resource, allocator, data, .{}),
    );
}

test "Static IPAM requires addresses" {
    const allocator = std.testing.allocator;

    const data =
        \\{
        \\    "name": "bad-static",
        \\    "interface": { "type": "macvlan", "master": "eth0" },
        \\    "ipam": { "type": "static" },
        \\    "acl": []
        \\}
    ;

    // static without addresses → MissingField for the required field
    try std.testing.expectError(
        error.MissingField,
        json.parseFromSlice(Resource, allocator, data, .{}),
    );
}

test "DHCP IPAM with daemon_socket_path" {
    const allocator = std.testing.allocator;

    const data =
        \\{
        \\    "name": "dhcp-custom",
        \\    "interface": { "type": "macvlan", "master": "eth0" },
        \\    "ipam": {
        \\        "type": "dhcp",
        \\        "daemon_socket_path": "/run/cni/dhcp.sock"
        \\    },
        \\    "acl": [{ "user": "root" }]
        \\}
    ;

    const parsed = try json.parseFromSlice(Resource, allocator, data, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value.ipam == .dhcp);
    try std.testing.expectEqualStrings("/run/cni/dhcp.sock", parsed.value.ipam.dhcp.daemon_socket_path.?);
}

test "Static IPAM with dual-stack addresses" {
    const allocator = std.testing.allocator;

    const data =
        \\{
        \\    "name": "dual-stack",
        \\    "interface": { "type": "macvlan", "master": "eth0" },
        \\    "ipam": {
        \\        "type": "static",
        \\        "addresses": [
        \\            { "address": "10.10.0.0/24", "gateway": "10.10.0.254" },
        \\            { "address": "3ffe:ffff:0:01ff::/64", "gateway": "3ffe:ffff:0::1" }
        \\        ],
        \\        "routes": [
        \\            { "dst": "0.0.0.0/0" },
        \\            { "dst": "192.168.0.0/16", "gw": "10.10.5.1", "priority": 100 },
        \\            { "dst": "3ffe:ffff:0:01ff::/64" }
        \\        ],
        \\        "dns": {
        \\            "nameservers": ["8.8.8.8"],
        \\            "domain": "example.com",
        \\            "search": ["example.com"]
        \\        }
        \\    },
        \\    "acl": [{ "user": "1000" }]
        \\}
    ;

    const parsed = try json.parseFromSlice(Resource, allocator, data, .{});
    defer parsed.deinit();

    const s = parsed.value.ipam.static;
    // Dual-stack addresses
    try std.testing.expectEqual(@as(usize, 2), s.addresses.len);
    try std.testing.expectEqualStrings("10.10.0.0/24", s.addresses[0].address);
    try std.testing.expectEqualStrings("10.10.0.254", s.addresses[0].gateway.?);
    try std.testing.expectEqualStrings("3ffe:ffff:0:01ff::/64", s.addresses[1].address);
    try std.testing.expectEqualStrings("3ffe:ffff:0::1", s.addresses[1].gateway.?);

    // Routes with gw and priority
    try std.testing.expectEqual(@as(usize, 3), s.routes.?.len);
    try std.testing.expect(s.routes.?[0].gw == null);
    try std.testing.expectEqualStrings("10.10.5.1", s.routes.?[1].gw.?);
    try std.testing.expectEqual(@as(u32, 100), s.routes.?[1].priority.?);
    try std.testing.expect(s.routes.?[2].gw == null);
    try std.testing.expect(s.routes.?[2].priority == null);

    // DNS
    try std.testing.expectEqualStrings("8.8.8.8", s.dns.?.nameservers.?[0]);
    try std.testing.expectEqualStrings("example.com", s.dns.?.domain.?);
    try std.testing.expectEqualStrings("example.com", s.dns.?.search.?[0]);
}

test "Static IPAM with minimal address (no gateway)" {
    const allocator = std.testing.allocator;

    const data =
        \\{
        \\    "name": "minimal-static",
        \\    "interface": { "type": "macvlan", "master": "eth0" },
        \\    "ipam": {
        \\        "type": "static",
        \\        "addresses": [{ "address": "192.168.1.0/24" }]
        \\    },
        \\    "acl": [{ "user": "root" }]
        \\}
    ;

    const parsed = try json.parseFromSlice(Resource, allocator, data, .{});
    defer parsed.deinit();

    const s = parsed.value.ipam.static;
    try std.testing.expectEqual(@as(usize, 1), s.addresses.len);
    try std.testing.expect(s.addresses[0].gateway == null);
    try std.testing.expect(s.routes == null);
    try std.testing.expect(s.dns == null);
}
