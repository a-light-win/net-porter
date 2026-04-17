const std = @import("std");
const json = std.json;
const Config = @import("Config.zig");
const ManagedConfig = @This();
const ArenaAllocator = @import("../utils/ArenaAllocator.zig");

const default_config_path = "/etc/net-porter/config.json";
const max_config_size = 1024 * 1024;

config: Config,
arena: ?ArenaAllocator = null,

pub fn deinit(self: ManagedConfig) void {
    if (self.arena) |arena| {
        arena.deinit();
    }
}

pub fn load(io: std.Io, root_allocator: std.mem.Allocator, config_path: ?[]const u8) !ManagedConfig {
    var arena = try ArenaAllocator.init(root_allocator);
    errdefer arena.deinit();

    const allocator = arena.allocator();
    const path = if (config_path) |value| value else default_config_path;

    const parsed_config = parseConfig(io, allocator, path) catch |err| switch (err) {
        error.FileNotFound => {
            var managed_config = ManagedConfig{ .config = Config{}, .arena = arena };
            try managed_config.config.postInit(io, allocator, path);
            return managed_config;
        },
        else => return err,
    };
    errdefer parsed_config.deinit();

    var config = parsed_config.value;
    try config.postInit(io, allocator, path);

    return ManagedConfig{
        .config = config,
        .arena = arena,
    };
}

test "load() should return InvalidPath if the config path is invalid" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    _ = ManagedConfig.load(io, allocator, "config.json") catch |err| switch (err) {
        error.InvalidPath => ManagedConfig{ .config = Config{} },
        else => unreachable,
    };
}

test "load() should return error if the config file is invalid" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    _ = ManagedConfig.load(io, allocator, "src/config/tests/invalid-config.json") catch |err| switch (err) {
        error.SyntaxError => ManagedConfig{ .config = Config{} },
        else => unreachable,
    };
}

test "load() should return default config if the config file does not exist" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const managed_config = try ManagedConfig.load(
        io,
        allocator,
        "src/config/tests/config-not-exists.json",
    );
    defer managed_config.deinit();

    try std.testing.expectEqualSlices(u8, "src/config/tests", managed_config.config.config_dir);
    try std.testing.expectEqualSlices(u8, "src/config/tests/config-not-exists.json", managed_config.config.config_path);
}

test "load() should return config if the config file exists" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const managed_config = try ManagedConfig.load(
        io,
        allocator,
        "src/config/tests/config.json",
    );
    defer managed_config.deinit();

    try std.testing.expectEqualSlices(u8, "src/config/tests", managed_config.config.config_dir);
    try std.testing.expectEqualSlices(u8, "src/config/tests/config.json", managed_config.config.config_path);
}

fn parseConfig(io: std.Io, allocator: std.mem.Allocator, config_path: []const u8) !json.Parsed(Config) {
    var config_file = try std.Io.Dir.cwd().openFile(io, config_path, .{});
    defer config_file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var file_reader = config_file.reader(io, &read_buffer);
    const buf = try file_reader.interface.allocRemaining(allocator, .limited(max_config_size));
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
    const io = std.testing.io;
    const config = parseConfig(io, allocator, "src/config/tests/config-not-exists.json");

    if (config) |_| {
        unreachable;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => unreachable,
    }
}

test "parseConfig() should return an error if the config file is not valid JSON" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const config = parseConfig(io, allocator, "src/config/tests/invalid-config.json");

    if (config) |_| {
        unreachable;
    } else |err| switch (err) {
        error.SyntaxError => {},
        else => unreachable,
    }
}

test "parseConfig() should successfully parse a valid config file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const config = try parseConfig(io, allocator, "src/config/tests/config.json");
    defer config.deinit();

    // Config parsed successfully with default values
    try std.testing.expectEqualSlices(u8, "", config.value.cni_dir);
}
