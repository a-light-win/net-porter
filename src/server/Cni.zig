const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const ArenaAllocator = @import("../ArenaAllocator.zig");
const Cni = @This();

const Attachment = json.Value;
const AttachmentKey = struct {
    container_id: []const u8,
    ifname: []const u8,
};
const AttachmentMap = std.HashMap(AttachmentKey, Attachment, AttachmentKeyContext, 80);

const max_cni_config_size = 16 * 1024;

arena: ArenaAllocator,
config: json.Parsed(json.Value),

mutex: std.Thread.Mutex = std.Thread.Mutex{},
attachments: ?AttachmentMap = null,

pub fn load(root_allocator: Allocator, path: []const u8) !*Cni {
    var arena = try ArenaAllocator.init(root_allocator);
    errdefer arena.deinit();

    const file = try std.fs.cwd().openFile(path, .{});

    const allocator = arena.allocator();
    const buf = try file.readToEndAlloc(allocator, max_cni_config_size);

    const parsed = try json.parseFromSlice(json.Value, allocator, buf, .{});
    errdefer parsed.deinit();

    const cni = try allocator.create(Cni);
    cni.* = Cni{
        .arena = arena,
        .config = parsed,
    };
    return cni;
}

pub fn deinit(self: Cni) void {
    if (self.attachments) |attachments| {
        var it = attachments.valueIterator();
        while (it.next()) |attachment| {
            attachment.*.object.deinit();
        }
        @constCast(&attachments).deinit();
    }

    self.config.deinit();

    const allocator = self.arena.childAllocator();
    self.arena.deinit();
    allocator.destroy(&self);
}

const AttachmentKeyContext = struct {
    pub fn hash(self: AttachmentKeyContext, key: AttachmentKey) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHashStrat(&hasher, key.container_id, .Shallow);
        std.hash.autoHashStrat(&hasher, key.ifname, .Shallow);
        return hasher.final();
    }

    pub fn eql(self: AttachmentKeyContext, one: AttachmentKey, other: AttachmentKey) bool {
        _ = self;
        return std.mem.eql(u8, one.container_id, other.container_id) and
            std.mem.eql(u8, one.ifname, other.ifname);
    }
};

test "AttachmentKey can be use in AttachmentMap" {
    const test_allocator = std.testing.allocator;
    var map = AttachmentMap.init(test_allocator);
    defer map.deinit();

    const key1 = AttachmentKey{ .container_id = "container1", .ifname = "eth0" };
    const key2 = AttachmentKey{ .container_id = "container2", .ifname = "eth0" };
    try map.put(key1, json.Value{ .bool = true });
    try map.put(key2, json.Value{ .bool = false });

    try std.testing.expect(map.get(key1).?.bool == true);
    try std.testing.expect(map.get(key2).?.bool == false);
}
