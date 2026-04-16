const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.cni_loader);
const CniConfig = @import("Cni.zig").CniConfig;

pub const CniLoader = struct {
    io: std.Io,
    allocator: Allocator,
    cni_dir: []const u8,
    cni_plugin_dir: []const u8,

    pub fn init(io: std.Io, allocator: Allocator, cni_dir: []const u8, cni_plugin_dir: []const u8) CniLoader {
        return CniLoader{
            .io = io,
            .allocator = allocator,
            .cni_dir = cni_dir,
            .cni_plugin_dir = cni_plugin_dir,
        };
    }

    /// Load all valid CNI configurations from cni_dir
    /// Returns a map of network name to CniConfig
    pub fn loadAll(self: CniLoader) !std.StringHashMap(CniConfig) {
        var configs = std.StringHashMap(CniConfig).init(self.allocator);
        errdefer {
            // All memory is owned by arena, will be freed automatically
            configs.deinit();
        }

        // Ensure cni_dir exists
        var dir = std.Io.Dir.cwd().openDir(self.io, self.cni_dir, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                log.warn("CNI directory {s} does not exist, no networks loaded", .{self.cni_dir});
                return configs;
            }
            return err;
        };
        defer dir.close(self.io);

        var iter = dir.iterate();
        while (try iter.next(self.io)) |entry| {
            // Skip directories and non-config files
            if (entry.kind == .directory) continue;
            if (!std.mem.endsWith(u8, entry.name, ".conf") and !std.mem.endsWith(u8, entry.name, ".conflist")) continue;

            const path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.cni_dir, entry.name });
            defer self.allocator.free(path);

            log.debug("Loading CNI config: {s}", .{path});
            const config = self.loadConfig(path) catch |err| {
                log.err("Failed to load CNI config {s}: {}", .{ path, err });
                continue;
            };

            // Check for duplicate network names
            if (configs.contains(config.name)) {
                log.err("Duplicate network name '{s}' in config {s}, skipping", .{ config.name, path });
                // All memory is owned by arena, will be freed automatically
                continue;
            }

            try configs.put(config.name, config);
            log.info("Loaded network '{s}' from {s}", .{ config.name, path });
        }

        log.info("Loaded {d} CNI network(s) from {s}", .{ configs.count(), self.cni_dir });
        return configs;
    }

    /// Load and parse a single CNI configuration file
    fn loadConfig(self: CniLoader, path: []const u8) !CniConfig {
        const content = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .unlimited); // Max 1MB per config
        defer self.allocator.free(content);

        const parsed = try json.parseFromSlice(json.Value, self.allocator, content, .{ .ignore_unknown_fields = true });
        // All JSON memory is allocated on self.allocator (which is an arena owned by CniManager)
        // The arena will free all memory when CniManager.deinit() is called, so no need to deinit parsed here
        // The CniConfig returned will reference memory owned by this arena

        if (parsed.value != .object) return error.InvalidConfig;
        const obj = parsed.value.object;

        // Parse base config
        const cni_version = obj.get("cniVersion") orelse return error.MissingCniVersion;
        if (cni_version != .string) return error.InvalidCniVersion;

        const name = obj.get("name") orelse return error.MissingNetworkName;
        if (name != .string) return error.InvalidNetworkName;

        // Handle both single-plugin .conf and multi-plugin .conflist formats
        var plugins: json.Array = undefined;
        if (obj.get("plugins")) |plugins_val| {
            if (plugins_val != .array) return error.InvalidPlugins;
            plugins = plugins_val.array;
        } else if (obj.get("type")) |_| {
            // Single-plugin config (.conf format) - wrap entire object into plugins array
            // Redundant cniVersion/name fields will be overridden in PluginConf.init
            plugins = try json.Array.initCapacity(self.allocator, 1);
            try plugins.append(parsed.value);
        } else {
            return error.MissingPlugins;
        }
        errdefer plugins.deinit();

        // Validate all plugins exist in cni_plugin_dir
        for (plugins.items) |plugin| {
            if (plugin != .object) return error.InvalidPlugin;
            const plugin_obj = plugin.object;
            const plugin_type = plugin_obj.get("type") orelse return error.MissingPluginType;
            if (plugin_type != .string) return error.InvalidPluginType;

            // Check plugin binary exists
            const plugin_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.cni_plugin_dir, plugin_type.string });
            defer self.allocator.free(plugin_path);

            std.Io.Dir.cwd().access(self.io, plugin_path, .{ .execute = true }) catch |err| {
                log.err("Plugin '{s}' not found or not executable at {s}", .{ plugin_type.string, plugin_path });
                return err;
            };
        }

        // Construct CniConfig
        const config = CniConfig{
            .cniVersion = try self.allocator.dupe(u8, cni_version.string),
            .name = try self.allocator.dupe(u8, name.string),
            .plugins = json.Value{ .array = plugins },
        };

        // Validate config
        try config.validate();
        return config;
    }
};

// ============================================================
// Tests
// ============================================================
test "CniLoader loads single-plugin config" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Create temp directories under /tmp with absolute paths
    const cni_dir_path = try std.fmt.allocPrint(arena_alloc, "/tmp/cni_loader_test_{d}", .{std.os.linux.getpid()});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, cni_dir_path);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, cni_dir_path) catch {};
    const cni_dir = try std.Io.Dir.cwd().openDir(std.testing.io, cni_dir_path, .{});
    defer cni_dir.close(std.testing.io);

    // Create test config
    const test_config =
        \\{
        \\    "cniVersion": "1.0.0",
        \\    "name": "test-net",
        \\    "type": "macvlan",
        \\    "master": "eth0",
        \\    "ipam": {"type": "dhcp"}
        \\}
    ;
    try cni_dir.writeFile(std.testing.io, .{ .sub_path = "test.conf", .data = test_config });

    // Mock plugin directory with dummy executable
    const plugin_dir_path = try std.fmt.allocPrint(arena_alloc, "/tmp/cni_loader_plugin_test_{d}", .{std.os.linux.getpid()});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, plugin_dir_path);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, plugin_dir_path) catch {};
    const plugin_dir = try std.Io.Dir.cwd().openDir(std.testing.io, plugin_dir_path, .{});
    defer plugin_dir.close(std.testing.io);
    try plugin_dir.writeFile(std.testing.io, .{ .sub_path = "macvlan", .data = "#!/bin/sh\nexit 0" });
    // Make plugin executable (chmod 0755)
    const macvlan_path = try std.fmt.allocPrint(arena_alloc, "{s}/macvlan\x00", .{plugin_dir_path});
    const macvlan_z: [:0]const u8 = macvlan_path[0 .. macvlan_path.len - 1 :0];
    _ = std.os.linux.fchmodat(std.posix.AT.FDCWD, macvlan_z, 0o755);

    // Load config using arena allocator (all memory freed when arena deinit)
    var loader = CniLoader.init(std.testing.io, arena_alloc, cni_dir_path, plugin_dir_path);
    var configs = try loader.loadAll();
    defer configs.deinit();

    try std.testing.expectEqual(@as(usize, 1), configs.count());
    const config = configs.get("test-net").?;
    try std.testing.expectEqualStrings("1.0.0", config.cniVersion);
    try std.testing.expectEqualStrings("test-net", config.name);
    try std.testing.expectEqual(@as(usize, 1), config.plugins.array.items.len);
}

test "CniLoader loads multi-plugin conflist" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Create temp directories under /tmp with absolute paths
    const cni_dir_path = try std.fmt.allocPrint(arena_alloc, "/tmp/cni_loader_conflist_test_{d}", .{std.os.linux.getpid()});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, cni_dir_path);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, cni_dir_path) catch {};
    const cni_dir = try std.Io.Dir.cwd().openDir(std.testing.io, cni_dir_path, .{});
    defer cni_dir.close(std.testing.io);

    // Create test conflist
    const test_config =
        \\{
        \\    "cniVersion": "1.0.0",
        \\    "name": "test-net",
        \\    "plugins": [
        \\        {"type": "macvlan", "master": "eth0", "ipam": {"type": "dhcp"}},
        \\        {"type": "firewall", "allowed_ports": ["80/tcp"]}
        \\    ]
        \\}
    ;
    try cni_dir.writeFile(std.testing.io, .{ .sub_path = "test.conflist", .data = test_config });

    // Mock plugin directory
    const plugin_dir_path = try std.fmt.allocPrint(arena_alloc, "/tmp/cni_loader_conflist_plugin_test_{d}", .{std.os.linux.getpid()});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, plugin_dir_path);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, plugin_dir_path) catch {};
    const plugin_dir = try std.Io.Dir.cwd().openDir(std.testing.io, plugin_dir_path, .{});
    defer plugin_dir.close(std.testing.io);
    try plugin_dir.writeFile(std.testing.io, .{ .sub_path = "macvlan", .data = "#!/bin/sh\nexit 0" });
    try plugin_dir.writeFile(std.testing.io, .{ .sub_path = "firewall", .data = "#!/bin/sh\nexit 0" });
    // Make plugins executable (chmod 0755)
    const macvlan_path = try std.fmt.allocPrint(arena_alloc, "{s}/macvlan\x00", .{plugin_dir_path});
    const macvlan_z: [:0]const u8 = macvlan_path[0 .. macvlan_path.len - 1 :0];
    _ = std.os.linux.fchmodat(std.posix.AT.FDCWD, macvlan_z, 0o755);
    const firewall_path = try std.fmt.allocPrint(arena_alloc, "{s}/firewall\x00", .{plugin_dir_path});
    const firewall_z: [:0]const u8 = firewall_path[0 .. firewall_path.len - 1 :0];
    _ = std.os.linux.fchmodat(std.posix.AT.FDCWD, firewall_z, 0o755);

    // Load config using arena allocator (all memory freed when arena deinit)
    var loader = CniLoader.init(std.testing.io, arena_alloc, cni_dir_path, plugin_dir_path);
    var configs = try loader.loadAll();
    defer configs.deinit();

    try std.testing.expectEqual(@as(usize, 1), configs.count());
    const config = configs.get("test-net").?;
    try std.testing.expectEqual(@as(usize, 2), config.plugins.array.items.len);
}
