const std = @import("std");
const log = std.log.scoped(.cni_manager);
const Cni = @import("Cni.zig");
const CniConfig = @import("Cni.zig").CniConfig;
const CniLoader = @import("loader.zig").CniLoader;
const Config = @import("../config.zig").Config;
const Allocator = std.mem.Allocator;
const ArenaAllocator = @import("../utils/ArenaAllocator.zig");

const CniMap = std.StringHashMap(*Cni);
const CniConfigMap = std.StringHashMap(CniConfig);
const CniManager = @This();

arena: ArenaAllocator,
io: std.Io,
cni_plugin_dir: []const u8,
cni_configs: CniConfigMap,
cni_plugins: CniMap,

mutex: std.Io.Mutex = .init,

pub fn init(io: std.Io, root_allocator: Allocator, config: Config) !CniManager {
    var arena = try ArenaAllocator.init(root_allocator);
    errdefer arena.deinit();

    // Load all CNI configurations from cni.d directory
    var loader = CniLoader.init(io, arena.allocator(), config.cni_dir, config.cni_plugin_dir);
    var cni_configs = try loader.loadAll();
    errdefer cni_configs.deinit();

    return CniManager{
        .arena = arena,
        .io = io,
        .cni_plugin_dir = config.cni_plugin_dir,
        .cni_configs = cni_configs,
        .cni_plugins = CniMap.init(arena.allocator()),
    };
}

pub fn deinit(self: *CniManager) void {
    // Release CNI instances
    var plugin_it = self.cni_plugins.valueIterator();
    while (plugin_it.next()) |plugin| {
        plugin.*.deinit();
    }
    self.cni_plugins.deinit();
    // Release CNI configs map (all value memory is owned by arena, will be freed automatically)
    self.cni_configs.deinit();
    // Release arena (frees all allocated memory including configs and parsed JSON)
    self.arena.deinit();
}

pub fn loadCni(self: *CniManager, name: []const u8) !*Cni {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);

    if (self.cni_plugins.get(name)) |plugin| {
        return plugin;
    }

    // Find config by name
    const cni_config = self.cni_configs.get(name) orelse {
        std.log.warn("Network '{s}' not found in CNI configs", .{name});
        return error.NetworkNotFound;
    };

    const allocator = self.arena.allocator();

    const cni = try Cni.initFromConfig(self.io, self.arena.childAllocator(), cni_config, self.cni_plugin_dir);
    errdefer cni.deinit();

    try self.cni_plugins.put(try allocator.dupe(u8, name), cni);
    return cni;
}

/// Get all loaded network names
/// Returned slice is owned by CniManager arena, valid until CniManager.deinit()
pub fn listNetworks(self: *CniManager) ![]const []const u8 {
    const allocator = self.arena.allocator();
    var names = std.ArrayList([]const u8).empty;
    errdefer names.deinit(allocator);
    var it = self.cni_configs.keyIterator();
    while (it.next()) |name| {
        try names.append(allocator, name.*);
    }
    return try names.toOwnedSlice(allocator);
}

test "CniManager: loadCni returns NetworkNotFound for unknown network" {
    const allocator = std.testing.allocator;

    // Create temp directory under /tmp with absolute path
    const cni_dir_path = try std.fmt.allocPrint(allocator, "/tmp/cni_mgr_test_{d}", .{std.os.linux.getpid()});
    defer allocator.free(cni_dir_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, cni_dir_path);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, cni_dir_path) catch {};

    const config = Config{
        .cni_dir = cni_dir_path,
        .cni_plugin_dir = "/usr/lib/cni",
    };

    var manager = try init(std.testing.io, allocator, config);
    defer manager.deinit();

    const result = manager.loadCni("not-exists");
    try std.testing.expectError(error.NetworkNotFound, result);
}

test "CniManager: loadCni loads from cni.d and caches instance" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Create cni.d with a test config
    const cni_dir_path = try std.fmt.allocPrint(arena_alloc, "/tmp/cni_mgr_load_test_{d}", .{std.os.linux.getpid()});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, cni_dir_path);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, cni_dir_path) catch {};
    const cni_dir = try std.Io.Dir.cwd().openDir(std.testing.io, cni_dir_path, .{});
    defer cni_dir.close(std.testing.io);

    const test_config =
        \\{
        \\    "cniVersion": "1.0.0",
        \\    "name": "test-load",
        \\    "type": "macvlan",
        \\    "master": "eth0",
        \\    "ipam": {"type": "dhcp"}
        \\}
    ;
    try cni_dir.writeFile(std.testing.io, .{ .sub_path = "test.conf", .data = test_config });

    // Mock plugin directory
    const plugin_dir_path = try std.fmt.allocPrint(arena_alloc, "/tmp/cni_mgr_load_plugin_test_{d}", .{std.os.linux.getpid()});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, plugin_dir_path);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, plugin_dir_path) catch {};
    const plugin_dir = try std.Io.Dir.cwd().openDir(std.testing.io, plugin_dir_path, .{});
    defer plugin_dir.close(std.testing.io);
    try plugin_dir.writeFile(std.testing.io, .{ .sub_path = "macvlan", .data = "#!/bin/sh\nexit 0" });
    const macvlan_path = try std.fmt.allocPrint(arena_alloc, "{s}/macvlan\x00", .{plugin_dir_path});
    const macvlan_z: [:0]const u8 = macvlan_path[0 .. macvlan_path.len - 1 :0];
    _ = std.os.linux.fchmodat(std.posix.AT.FDCWD, macvlan_z, 0o755);

    const config = Config{
        .cni_dir = cni_dir_path,
        .cni_plugin_dir = plugin_dir_path,
    };

    var manager = try init(std.testing.io, arena_alloc, config);
    defer manager.deinit();

    // First load creates a new instance
    const cni1 = try manager.loadCni("test-load");
    try std.testing.expectEqualStrings("test-load", cni1.config.name);

    // Second load returns the cached instance
    const cni2 = try manager.loadCni("test-load");
    try std.testing.expect(cni1 == cni2);
}

test "CniManager: listNetworks returns all loaded network names" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const cni_dir_path = try std.fmt.allocPrint(arena_alloc, "/tmp/cni_mgr_list_test_{d}", .{std.os.linux.getpid()});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, cni_dir_path);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, cni_dir_path) catch {};

    const config = Config{
        .cni_dir = cni_dir_path,
        .cni_plugin_dir = "/usr/lib/cni",
    };

    var manager = try init(std.testing.io, arena_alloc, config);
    defer manager.deinit();

    // Empty directory → no networks
    const names = try manager.listNetworks();
    try std.testing.expectEqual(@as(usize, 0), names.len);
}
