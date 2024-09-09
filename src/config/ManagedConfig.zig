const std = @import("std");
const json = std.json;
const Config = @import("Config.zig");
const ManagedConfig = @This();
const ArenaAllocator = @import("../ArenaAllocator.zig");

const default_config_path = "/etc/net-porter/config.json";
const max_config_size = 1024 * 1024;

config: Config,
arena: ?ArenaAllocator = null,

pub fn deinit(self: ManagedConfig) void {
    if (self.arena) |arena| {
        arena.deinit();
    }
}

pub fn load(root_allocator: std.mem.Allocator, config_path: ?[]const u8, accepted_uid: std.posix.uid_t) !ManagedConfig {
    var arena = try ArenaAllocator.init(root_allocator);
    errdefer arena.deinit();

    const allocator = arena.allocator();
    const path = if (config_path) |value| value else default_config_path;

    const parsed_config = parseConfig(allocator, path) catch |err| switch (err) {
        error.FileNotFound => {
            var managed_config = ManagedConfig{ .config = Config{}, .arena = arena };
            try managed_config.config.postInit(allocator, path, accepted_uid);
            return managed_config;
        },
        else => return err,
    };
    errdefer parsed_config.deinit();

    var config = parsed_config.value;
    try config.postInit(allocator, path, accepted_uid);

    return ManagedConfig{
        .config = config,
        .arena = arena,
    };
}

test "load() should return InvalidPath if the config path is invalid" {
    const allocator = std.testing.allocator;
    _ = ManagedConfig.load(allocator, "config.json", 0) catch |err| switch (err) {
        error.InvalidPath => ManagedConfig{ .config = Config{} },
        else => unreachable,
    };
}

test "load() should return error if the config file is invalid" {
    const allocator = std.testing.allocator;
    _ = ManagedConfig.load(allocator, "src/config/tests/invalid-config.json", 0) catch |err| switch (err) {
        error.InvalidCharacter => ManagedConfig{ .config = Config{} },
        else => unreachable,
    };
}

test "load() should return default config if the config file does not exist" {
    const allocator = std.testing.allocator;
    const managed_config = try ManagedConfig.load(
        allocator,
        "src/config/tests/config-not-exists.json",
        0,
    );
    defer managed_config.deinit();

    try std.testing.expectEqualSlices(u8, "/run/user/0/net-porter.sock", managed_config.config.domain_socket.path);
    try std.testing.expectEqualSlices(u8, "src/config/tests", managed_config.config.config_dir);
    try std.testing.expectEqualSlices(u8, "src/config/tests/config-not-exists.json", managed_config.config.config_path);
}

test "load() should return config if the config file exists" {
    const allocator = std.testing.allocator;

    const managed_config = try ManagedConfig.load(
        allocator,
        "src/config/tests/config.json",
        0,
    );
    defer managed_config.deinit();

    try std.testing.expectEqual(1000, managed_config.config.domain_socket.uid);
    try std.testing.expectEqualSlices(u8, "/run/test.sock", managed_config.config.domain_socket.path);
    try std.testing.expectEqualSlices(u8, "src/config/tests", managed_config.config.config_dir);
    try std.testing.expectEqualSlices(u8, "src/config/tests/config.json", managed_config.config.config_path);
}

fn parseConfig(allocator: std.mem.Allocator, config_path: []const u8) !json.Parsed(Config) {
    const config_file = try std.fs.cwd().openFile(config_path, .{});
    defer config_file.close();

    const buf = try config_file.readToEndAlloc(allocator, max_config_size);
    defer allocator.free(buf);

    return try json.parseFromSlice(
        Config,
        allocator,
        buf,
        .{
            .ignore_unknown_fields = false,
            .max_value_len = max_config_size,
            .allocate = .alloc_always,
        },
    );
}

test "parseConfig() should return an error if the config file does not exist" {
    const allocator = std.testing.allocator;
    const config = parseConfig(allocator, "src/config/tests/config-not-exists.json");

    if (config) |_| {
        unreachable;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => unreachable,
    }
}

test "parseConfig() should return an error if the config file is not valid JSON" {
    const allocator = std.testing.allocator;
    const config = parseConfig(allocator, "src/config/tests/invalid-config.json");

    if (config) |_| {
        unreachable;
    } else |err| switch (err) {
        error.InvalidCharacter => {},
        else => unreachable,
    }
}

test "parseConfig() should successfully parse a valid config file" {
    const allocator = std.testing.allocator;
    const config = try parseConfig(allocator, "src/config/tests/config.json");
    defer config.deinit();

    try std.testing.expectEqual(1000, config.value.domain_socket.uid);
    try std.testing.expectEqualSlices(u8, "/run/test.sock", config.value.domain_socket.path);
}
