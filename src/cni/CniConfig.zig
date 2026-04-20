const std = @import("std");
const json = std.json;
const log = std.log.scoped(.cni);
const PluginConf = @import("PluginConf.zig").PluginConf;

pub const CniConfig = struct {
    cniVersion: []const u8,
    name: []const u8,
    disableCheck: bool = false,
    plugins: json.Value,

    const ValidateError = error{
        PluginsIsEmpty,
        PluginsIsNotArray,
        PluginIsNotMap,
        MissingIpamConfig,
        InvalidIpamConfig,
        MissingIpamType,
        InvalidIpamType,
        UnsupportedIpamType,
    } || PluginConf.ValidateError;

    pub fn validate(self: CniConfig) ValidateError!void {
        return switch (self.plugins) {
            .array => |arr| blk: {
                if (arr.items.len == 0) {
                    log.warn("No plugins in cni config '{s}'", .{self.name});
                    break :blk ValidateError.PluginsIsEmpty;
                }
                for (arr.items) |v| {
                    try self.validatePlugin(v);
                }
            },
            else => blk: {
                log.warn(
                    "The plugins field in cni config '{s}' is not an array",
                    .{self.name},
                );
                break :blk ValidateError.PluginsIsNotArray;
            },
        };
    }

    test "validate() will fail if plugins is not an array" {
        const allocator = std.testing.allocator;
        const data =
            \\{
            \\    "cniVersion": "0.3.1",
            \\    "name": "test",
            \\    "plugins": true
            \\}
        ;
        const parsed_config = try json.parseFromSlice(
            CniConfig,
            allocator,
            data,
            .{},
        );
        defer parsed_config.deinit();

        try std.testing.expectError(error.PluginsIsNotArray, parsed_config.value.validate());
    }

    test "validate() will fail if plugins is empty" {
        const allocator = std.testing.allocator;
        const data =
            \\{
            \\    "cniVersion": "0.3.1",
            \\    "name": "test",
            \\    "plugins": []
            \\}
        ;
        const parsed_config = try json.parseFromSlice(
            CniConfig,
            allocator,
            data,
            .{},
        );
        defer parsed_config.deinit();
        try std.testing.expectError(error.PluginsIsEmpty, parsed_config.value.validate());
    }

    fn validatePlugin(self: CniConfig, p: json.Value) ValidateError!void {
        return switch (p) {
            .object => |obj| {
                const plugin_conf = PluginConf{ .conf = obj };
                try plugin_conf.validate(self.name);
            },
            else => {
                log.warn(
                    "The plugin in cni config '{s}' is not a map",
                    .{self.name},
                );
                return error.PluginIsNotMap;
            },
        };
    }

    test "validate() will fail if the plugin is not a map" {
        const allocator = std.testing.allocator;
        const data =
            \\{
            \\    "cniVersion": "0.3.1",
            \\    "name": "test",
            \\    "plugins": [
            \\        true
            \\    ]
            \\}
        ;
        const parsed_config = try json.parseFromSlice(
            CniConfig,
            allocator,
            data,
            .{},
        );
        defer parsed_config.deinit();
        try std.testing.expectError(error.PluginIsNotMap, parsed_config.value.validate());
    }

    test "validate() will fail if the plugin type is missing" {
        const allocator = std.testing.allocator;
        const data =
            \\{
            \\    "cniVersion": "0.3.1",
            \\    "name": "test",
            \\    "plugins": [
            \\        {}
            \\    ]
            \\}
        ;
        const parsed_config = try json.parseFromSlice(
            CniConfig,
            allocator,
            data,
            .{},
        );
        defer parsed_config.deinit();
        try std.testing.expectError(error.PluginTypeMissing, parsed_config.value.validate());
    }

    test "validate() will fail if the plugin type is not string" {
        const allocator = std.testing.allocator;
        const data =
            \\{
            \\    "cniVersion": "0.3.1",
            \\    "name": "test",
            \\    "plugins": [
            \\        {
            \\            "type": true
            \\        }
            \\    ]
            \\}
        ;
        const parsed_config = try json.parseFromSlice(
            CniConfig,
            allocator,
            data,
            .{},
        );
        defer parsed_config.deinit();
        try std.testing.expectError(error.PluginTypeNotString, parsed_config.value.validate());
    }

    test "validate() will success if the plugin type is a string" {
        const allocator = std.testing.allocator;
        const data =
            \\{
            \\    "cniVersion": "0.3.1",
            \\    "name": "test-supported-plugin-type",
            \\    "plugins": [
            \\        {
            \\            "type": "macvlan"
            \\        }
            \\    ]
            \\}
        ;
        const parsed_config = try json.parseFromSlice(
            CniConfig,
            allocator,
            data,
            .{},
        );
        defer parsed_config.deinit();
        const config = parsed_config.value;
        config.validate() catch unreachable;
    }
};
