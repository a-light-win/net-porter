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

            const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.cni_dir, entry.name });
            defer self.allocator.free(path);

            log.debug("Loading CNI config: {s}", .{path});
            const config = self.loadConfig(path) catch |err| {
                log.warn("Failed to load CNI config {s}: {}", .{ path, err });
                continue;
            };

            // Check for duplicate network names
            if (configs.contains(config.name)) {
                log.warn("Duplicate network name '{s}' in config {s}, skipping", .{ config.name, path });
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
        // Limit config file size to 1 MB — CNI configs are typically small (<10 KB)
        const content = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(1024 * 1024));
        defer self.allocator.free(content);

        const parsed = try json.parseFromSlice(json.Value, self.allocator, content, .{ .ignore_unknown_fields = true });
        // NOTE: parsed is intentionally not deinited here.
        // All JSON memory (including parsed metadata) is allocated on self.allocator,
        // which is an arena owned by CniManager. The arena frees everything on deinit().
        // The returned CniConfig references memory owned by this arena.

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

            // Validate plugin type identifier (whitelist + length + prefix)
            if (!isValidPluginType(plugin_type.string)) {
                log.err("Invalid plugin type '{s}' (must be alphanumeric, dash, underscore, dot; max 64 chars; cannot start with - or .)", .{plugin_type.string});
                return error.InvalidPluginType;
            }

            const plugin_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.cni_plugin_dir, plugin_type.string });
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

/// Validate CNI plugin type identifier against a safe whitelist.
/// Allows: [a-zA-Z0-9\-_.], max 64 chars, must not start with '-' or '.'.
/// Rejects path traversal, leading-dash flag injection, whitespace, and oversized names.
pub fn isValidPluginType(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (name[0] == '-' or name[0] == '.') return false;
    for (name) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
            else => return false,
        }
    }
    return true;
}

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

test "CniLoader returns empty map for non-existent directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var loader = CniLoader.init(std.testing.io, arena_alloc, "/tmp/nonexistent_cni_dir_xyz", "/usr/lib/cni");
    var configs = try loader.loadAll();
    defer configs.deinit();

    try std.testing.expectEqual(@as(usize, 0), configs.count());
}

test "CniLoader returns empty map for directory with no config files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const cni_dir_path = try std.fmt.allocPrint(arena_alloc, "/tmp/cni_loader_empty_test_{d}", .{std.os.linux.getpid()});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, cni_dir_path);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, cni_dir_path) catch {};

    // Write a non-config file that should be skipped
    const cni_dir = try std.Io.Dir.cwd().openDir(std.testing.io, cni_dir_path, .{});
    defer cni_dir.close(std.testing.io);
    try cni_dir.writeFile(std.testing.io, .{ .sub_path = "readme.txt", .data = "not a config" });

    var loader = CniLoader.init(std.testing.io, arena_alloc, cni_dir_path, "/usr/lib/cni");
    var configs = try loader.loadAll();
    defer configs.deinit();

    try std.testing.expectEqual(@as(usize, 0), configs.count());
}

test "CniLoader skips invalid config and loads valid one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const cni_dir_path = try std.fmt.allocPrint(arena_alloc, "/tmp/cni_loader_mixed_test_{d}", .{std.os.linux.getpid()});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, cni_dir_path);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, cni_dir_path) catch {};
    const cni_dir = try std.Io.Dir.cwd().openDir(std.testing.io, cni_dir_path, .{});
    defer cni_dir.close(std.testing.io);

    // Invalid config: missing required fields
    try cni_dir.writeFile(std.testing.io, .{ .sub_path = "invalid.conf", .data = "{}" });

    // Valid config
    const valid_config =
        \\{
        \\    "cniVersion": "1.0.0",
        \\    "name": "valid-net",
        \\    "type": "macvlan",
        \\    "master": "eth0",
        \\    "ipam": {"type": "dhcp"}
        \\}
    ;
    try cni_dir.writeFile(std.testing.io, .{ .sub_path = "valid.conf", .data = valid_config });

    // Mock plugin directory
    const plugin_dir_path = try std.fmt.allocPrint(arena_alloc, "/tmp/cni_loader_mixed_plugin_test_{d}", .{std.os.linux.getpid()});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, plugin_dir_path);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, plugin_dir_path) catch {};
    const plugin_dir = try std.Io.Dir.cwd().openDir(std.testing.io, plugin_dir_path, .{});
    defer plugin_dir.close(std.testing.io);
    try plugin_dir.writeFile(std.testing.io, .{ .sub_path = "macvlan", .data = "#!/bin/sh\nexit 0" });
    const macvlan_path = try std.fmt.allocPrint(arena_alloc, "{s}/macvlan\x00", .{plugin_dir_path});
    const macvlan_z: [:0]const u8 = macvlan_path[0 .. macvlan_path.len - 1 :0];
    _ = std.os.linux.fchmodat(std.posix.AT.FDCWD, macvlan_z, 0o755);

    var loader = CniLoader.init(std.testing.io, arena_alloc, cni_dir_path, plugin_dir_path);
    var configs = try loader.loadAll();
    defer configs.deinit();

    // Only the valid config should be loaded
    try std.testing.expectEqual(@as(usize, 1), configs.count());
    try std.testing.expect(configs.contains("valid-net"));
}

test "CniLoader skips duplicate network name and keeps first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const cni_dir_path = try std.fmt.allocPrint(arena_alloc, "/tmp/cni_loader_dup_test_{d}", .{std.os.linux.getpid()});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, cni_dir_path);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, cni_dir_path) catch {};
    const cni_dir = try std.Io.Dir.cwd().openDir(std.testing.io, cni_dir_path, .{});
    defer cni_dir.close(std.testing.io);

    // Two configs with the same network name
    const config_a =
        \\{
        \\    "cniVersion": "1.0.0",
        \\    "name": "dup-net",
        \\    "type": "macvlan",
        \\    "master": "eth0",
        \\    "ipam": {"type": "dhcp"}
        \\}
    ;
    const config_b =
        \\{
        \\    "cniVersion": "1.0.0",
        \\    "name": "dup-net",
        \\    "type": "ipvlan",
        \\    "master": "eth1",
        \\    "ipam": {"type": "dhcp"}
        \\}
    ;
    try cni_dir.writeFile(std.testing.io, .{ .sub_path = "a.conf", .data = config_a });
    try cni_dir.writeFile(std.testing.io, .{ .sub_path = "b.conf", .data = config_b });

    // Mock plugin directory
    const plugin_dir_path = try std.fmt.allocPrint(arena_alloc, "/tmp/cni_loader_dup_plugin_test_{d}", .{std.os.linux.getpid()});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, plugin_dir_path);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, plugin_dir_path) catch {};
    const plugin_dir = try std.Io.Dir.cwd().openDir(std.testing.io, plugin_dir_path, .{});
    defer plugin_dir.close(std.testing.io);
    try plugin_dir.writeFile(std.testing.io, .{ .sub_path = "macvlan", .data = "#!/bin/sh\nexit 0" });
    try plugin_dir.writeFile(std.testing.io, .{ .sub_path = "ipvlan", .data = "#!/bin/sh\nexit 0" });
    const macvlan_path = try std.fmt.allocPrint(arena_alloc, "{s}/macvlan\x00", .{plugin_dir_path});
    const macvlan_z: [:0]const u8 = macvlan_path[0 .. macvlan_path.len - 1 :0];
    _ = std.os.linux.fchmodat(std.posix.AT.FDCWD, macvlan_z, 0o755);
    const ipvlan_path = try std.fmt.allocPrint(arena_alloc, "{s}/ipvlan\x00", .{plugin_dir_path});
    const ipvlan_z: [:0]const u8 = ipvlan_path[0 .. ipvlan_path.len - 1 :0];
    _ = std.os.linux.fchmodat(std.posix.AT.FDCWD, ipvlan_z, 0o755);

    var loader = CniLoader.init(std.testing.io, arena_alloc, cni_dir_path, plugin_dir_path);
    var configs = try loader.loadAll();
    defer configs.deinit();

    // Only one config should be loaded (first wins)
    try std.testing.expectEqual(@as(usize, 1), configs.count());
    try std.testing.expect(configs.contains("dup-net"));
}

test "isValidPluginType accepts valid names" {
    try std.testing.expect(isValidPluginType("bridge"));
    try std.testing.expect(isValidPluginType("firewall"));
    try std.testing.expect(isValidPluginType("dhcp-cni"));
    try std.testing.expect(isValidPluginType("my_plugin"));
    try std.testing.expect(isValidPluginType("plugin.v2"));
    try std.testing.expect(isValidPluginType("a"));
    try std.testing.expect(isValidPluginType("0leading-digit"));
    try std.testing.expect(isValidPluginType("ABC123"));
}

test "isValidPluginType rejects empty and oversized names" {
    try std.testing.expect(!isValidPluginType(""));
    // 65 chars — one beyond the 64-char limit
    const long_name = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try std.testing.expect(!isValidPluginType(long_name));
    // 64 chars — boundary, should pass
    const max_name = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try std.testing.expect(isValidPluginType(max_name));
}

test "isValidPluginType rejects path traversal characters" {
    try std.testing.expect(!isValidPluginType("/etc/passwd"));
    try std.testing.expect(!isValidPluginType(".."));
    try std.testing.expect(!isValidPluginType("foo/bar"));
    try std.testing.expect(!isValidPluginType("a/.."));
    try std.testing.expect(!isValidPluginType("."));
}

test "isValidPluginType rejects leading dash and dot" {
    try std.testing.expect(!isValidPluginType("-flag"));
    try std.testing.expect(!isValidPluginType("--verbose"));
    try std.testing.expect(!isValidPluginType(".hidden"));
    try std.testing.expect(!isValidPluginType(".config"));
}

test "isValidPluginType rejects whitespace and special characters" {
    try std.testing.expect(!isValidPluginType("name with spaces"));
    try std.testing.expect(!isValidPluginType("tab\there"));
    try std.testing.expect(!isValidPluginType("newline\n"));
    try std.testing.expect(!isValidPluginType("null\x00byte"));
    try std.testing.expect(!isValidPluginType("semi;colon"));
    try std.testing.expect(!isValidPluginType("pipe|char"));
    try std.testing.expect(!isValidPluginType("shell$(cmd)"));
    try std.testing.expect(!isValidPluginType("back\\tick"));
    try std.testing.expect(!isValidPluginType("quote\"char"));
}
