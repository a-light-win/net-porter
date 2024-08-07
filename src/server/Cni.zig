const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const Cni = @This();

const max_cni_config_size = 16 * 1024;

allocator: Allocator,
config: json.Parsed(json.Value),

pub fn load(allocator: Allocator, path: []const u8) !*Cni {
    const file = try std.fs.cwd().openFile(path, .{});

    const buf = try file.readToEndAlloc(allocator, max_cni_config_size);
    errdefer allocator.free(buf);

    const parsed = try json.parseFromSlice(json.Value, allocator, buf, .{});
    errdefer parsed.deinit();

    const cni = try allocator.create(Cni);
    cni.* = Cni{
        .allocator = allocator,
        .config = parsed,
    };
    return cni;
}

fn deinit(self: Cni) void {
    self.config.deinit();
}

pub fn destroy(self: *Cni) void {
    self.deinit();

    const allocator = self.allocator;
    allocator.destroy(self);
}
