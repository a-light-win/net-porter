const std = @import("std");
const json = std.json;
const Config = @import("Config.zig");
const ManagedConfig = @This();

const default_config_path = "/etc/net-porter/config.json";
const max_config_size = 1024 * 1024;

config: Config,
arena: ?*std.heap.ArenaAllocator = null,

pub fn deinit(self: ManagedConfig) void {
    if (self.arena) |arena| {
        const child_allocator = arena.child_allocator;
        arena.deinit();
        child_allocator.destroy(arena);
    }
}

pub fn load(allocator: std.mem.Allocator, config_path: ?[]const u8) !ManagedConfig {
    const path = if (config_path) |value| value else default_config_path;
    const dir = std.fs.path.dirname(path);
    if (dir == null) {
        std.log.warn("Can not get config directory from path: {s}", .{path});
        return error.InvalidPath;
    }

    const parsed_config = parseConfig(allocator, path) catch |err| switch (err) {
        error.FileNotFound => {
            return ManagedConfig{ .config = Config{
                .config_dir = dir.?,
                .config_path = path,
            } };
        },
        else => return err,
    };

    var config = parsed_config.value;
    config.config_dir = dir.?;
    config.config_path = path;

    return ManagedConfig{
        .config = config,
        .arena = parsed_config.arena,
    };
}

test "load() should return InvalidPath if the config path is invalid" {
    const allocator = std.testing.allocator;
    _ = ManagedConfig.load(allocator, "config.json") catch |err| switch (err) {
        error.InvalidPath => ManagedConfig{ .config = Config{} },
        else => unreachable,
    };
}

test "load() should return error if the config file is invalid" {
    const allocator = std.testing.allocator;
    _ = ManagedConfig.load(allocator, "src/config/tests/invalid-config.json") catch |err| switch (err) {
        error.InvalidCharacter => ManagedConfig{ .config = Config{} },
        else => unreachable,
    };
}

test "load() should return default config if the config file does not exist" {
    const allocator = std.testing.allocator;
    const managed_config = try ManagedConfig.load(allocator, "src/config/tests/config-not-exists.json");
    defer managed_config.deinit();

    try std.testing.expectEqualSlices(u8, "/run/net-porter.sock", managed_config.config.domain_socket.path);
    try std.testing.expectEqualSlices(u8, "src/config/tests", managed_config.config.config_dir);
    try std.testing.expectEqualSlices(u8, "src/config/tests/config-not-exists.json", managed_config.config.config_path);
}

test "load() should return config if the config file exists" {
    const allocator = std.testing.allocator;

    const managed_config = try ManagedConfig.load(allocator, "src/config/tests/config.json");
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

test {
    _ = @import("user.zig");
    _ = @import("DomainSocket.zig");
    _ = @import("Config.zig");
}
