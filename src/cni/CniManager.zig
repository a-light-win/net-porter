const std = @import("std");
const json = std.json;
const log = std.log.scoped(.cni_manager);
const Cni = @import("Cni.zig");
const CniConfig = @import("Cni.zig").CniConfig;
const CniLoader = @import("loader.zig").CniLoader;
const buildCniConfigFromResource = @import("Cni.zig").buildCniConfigFromResource;
const Config = @import("../config.zig").Config;
const Resource = @import("../config.zig").Resource;
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

    // Load legacy resources from config.json (backward compatibility)
    if (config.resources) |resources| {
        for (resources) |resource| {
            const cni_config = try buildCniConfigFromResource(arena.allocator(), resource);
            try cni_config.validate();
            try cni_configs.put(try arena.allocator().dupe(u8, resource.name), cni_config);
            log.info("Loaded legacy resource '{s}' from config.json", .{resource.name});
        }
    }

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
    var names = std.ArrayList([]const u8).init(allocator);
    errdefer names.deinit();
    var it = self.cni_configs.keyIterator();
    while (it.next()) |name| {
        try names.append(name.*);
    }
    return try names.toOwnedSlice();
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
