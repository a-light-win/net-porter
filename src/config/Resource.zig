const std = @import("std");
const Resource = @This();

name: []const u8,
interface: Interface,
ipam: Ipam,
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

pub const Route = struct {
    dst: []const u8,
};

pub const Ipam = struct {
    type: []const u8,
    gateway: ?[]const u8 = null,
    subnet: ?[]const u8 = null,
    routes: ?[]const Route = null,
};

test "Resource can be loaded from json" {
    const allocator = std.testing.allocator;
    const json = std.json;

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

    const parsed = try json.parseFromSlice(
        Resource,
        allocator,
        data,
        .{},
    );
    defer parsed.deinit();

    const resource = parsed.value;

    try std.testing.expectEqualSlices(u8, "test", resource.name);
    try std.testing.expectEqualSlices(u8, "macvlan", resource.interface.type);
    try std.testing.expectEqualSlices(u8, "eth0", resource.interface.master);
    try std.testing.expectEqualSlices(u8, "dhcp", resource.ipam.type);
    try std.testing.expectEqual(@as(usize, 2), resource.acl.len);
    try std.testing.expectEqualSlices(u8, "alice", resource.acl[0].user.?);
    try std.testing.expectEqualSlices(u8, "devops", resource.acl[1].group.?);
}

test "Resource with static ipam and ip ranges can be loaded from json" {
    const allocator = std.testing.allocator;
    const json = std.json;

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
        \\        "gateway": "192.168.1.1",
        \\        "subnet": "192.168.1.0/24",
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

    const parsed = try json.parseFromSlice(
        Resource,
        allocator,
        data,
        .{},
    );
    defer parsed.deinit();

    const resource = parsed.value;

    try std.testing.expectEqualSlices(u8, "macvlan-static", resource.name);
    try std.testing.expectEqualSlices(u8, "static", resource.ipam.type);
    try std.testing.expectEqualSlices(u8, "192.168.1.1", resource.ipam.gateway.?);
    try std.testing.expectEqualSlices(u8, "192.168.1.0/24", resource.ipam.subnet.?);
    try std.testing.expectEqual(@as(usize, 2), resource.acl.len);

    const alice_grant = resource.acl[0];
    try std.testing.expectEqualSlices(u8, "alice", alice_grant.user.?);
    try std.testing.expect(alice_grant.ips != null);
    try std.testing.expectEqual(@as(usize, 1), alice_grant.ips.?.len);
    try std.testing.expectEqualSlices(u8, "192.168.1.10-192.168.1.20", alice_grant.ips.?[0]);
}

test "Resource with all optional fields populated" {
    const allocator = std.testing.allocator;
    const json = std.json;

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
        \\        "gateway": "10.0.0.1",
        \\        "subnet": "10.0.0.0/16",
        \\        "routes": [
        \\            { "dst": "0.0.0.0/0" },
        \\            { "dst": "10.0.0.0/8" }
        \\        ]
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
    try std.testing.expectEqualSlices(u8, "10.0.0.1", r.ipam.gateway.?);
    try std.testing.expectEqual(@as(usize, 2), r.ipam.routes.?.len);
    try std.testing.expectEqualSlices(u8, "0.0.0.0/0", r.ipam.routes.?[0].dst);
    try std.testing.expectEqualSlices(u8, "10.0.0.0/8", r.ipam.routes.?[1].dst);
    // Multiple ips in a single grant
    try std.testing.expectEqual(@as(usize, 2), r.acl[0].ips.?.len);
}

test "Resource with minimal fields - optional fields default to null" {
    const allocator = std.testing.allocator;
    const json = std.json;

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
    try std.testing.expect(r.ipam.gateway == null);
    try std.testing.expect(r.ipam.subnet == null);
    try std.testing.expect(r.ipam.routes == null);
    try std.testing.expect(r.acl[0].ips == null);
    try std.testing.expect(r.acl[0].group == null);
}

test "Resource with grant having both user and group" {
    const allocator = std.testing.allocator;
    const json = std.json;

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
    const json = std.json;

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
    const json = std.json;

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
