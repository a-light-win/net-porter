const std = @import("std");
const Cni = @import("Cni.zig");
const Config = @import("../config.zig").Config;
const Allocator = std.mem.Allocator;
const ArenaAllocator = @import("../ArenaAllocator.zig");

const CniMap = std.StringHashMap(*Cni);
const CniManager = @This();

arena: ArenaAllocator,
cni_dir: []const u8,
cni_plugins: CniMap,

mutex: std.Thread.Mutex = std.Thread.Mutex{},

pub fn init(root_allocator: Allocator, config: Config) Allocator.Error!CniManager {
    var arena = try ArenaAllocator.init(root_allocator);
    errdefer arena.deinit();

    const allocator = arena.allocator();
    return CniManager{
        .arena = arena,
        .cni_dir = try genCniDir(allocator, config),
        .cni_plugins = CniMap.init(allocator),
    };
}

pub fn deinit(self: CniManager) void {
    var plugin_it = self.cni_plugins.valueIterator();
    while (plugin_it.next()) |plugin| {
        plugin.*.deinit();
    }
    @constCast(&self.cni_plugins).deinit();

    self.arena.deinit();
}

fn genCniDir(allocator: std.mem.Allocator, config: Config) Allocator.Error![]const u8 {
    if (config.cni_dir) |dir| {
        return dir;
    }

    const buf = try allocator.alloc(u8, config.config_dir.len + 6);
    return std.fmt.bufPrint(buf, "{s}/cni.d", .{config.config_dir}) catch unreachable;
}

pub fn loadCni(self: *CniManager, name: []const u8) !*Cni {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.cni_plugins.get(name)) |plugin| {
        return plugin;
    }

    const allocator = self.arena.allocator();

    const path = try self.getCniPath(allocator, name);
    defer allocator.free(path);

    const plugin = try Cni.load(self.arena.childAllocator(), path);
    errdefer plugin.deinit();

    try self.cni_plugins.put(name, plugin);
    return plugin;
}

fn getCniPath(self: *CniManager, allocator: Allocator, name: []const u8) Allocator.Error![]const u8 {
    const buf = try allocator.alloc(u8, self.cni_dir.len + 1 + name.len + 5);
    return std.fmt.bufPrint(buf, "{s}/{s}.json", .{ self.cni_dir, name }) catch unreachable;
}
