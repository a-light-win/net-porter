const std = @import("std");
const json = std.json;
const log = std.log.scoped(.cni);
const Allocator = std.mem.Allocator;
const ArenaAllocator = @import("../ArenaAllocator.zig");
const plugin = @import("../plugin.zig");
const Responser = @import("Responser.zig");
const Cni = @This();

const max_cni_config_size = 16 * 1024;

arena: ArenaAllocator,
cni_plugin_dir: []const u8,
config: json.Parsed(CniConfig),

mutex: std.Thread.Mutex = std.Thread.Mutex{},
attachments: ?AttachmentMap = null,

const AttachmentKey = struct {
    container_id: []const u8,
    ifname: []const u8,
};
const AttachmentMap = std.HashMap(AttachmentKey, Attachment, AttachmentKeyContext, 80);

pub fn load(root_allocator: Allocator, path: []const u8, cni_plugin_dir: []const u8) !*Cni {
    var arena = try ArenaAllocator.init(root_allocator);
    errdefer arena.deinit();

    const file = try std.fs.cwd().openFile(path, .{});

    const allocator = arena.allocator();
    const buf = try file.readToEndAlloc(allocator, max_cni_config_size);

    const parsed = try json.parseFromSlice(CniConfig, allocator, buf, .{});
    errdefer parsed.deinit();

    try parsed.value.validate();

    const cni = try allocator.create(Cni);
    cni.* = Cni{
        .arena = arena,
        .cni_plugin_dir = cni_plugin_dir,
        .config = parsed,
    };
    return cni;
}

pub fn deinit(self: Cni) void {
    if (self.attachments) |attachments| {
        var it = attachments.valueIterator();
        while (it.next()) |attachment| {
            attachment.deinit();
        }
        @constCast(&attachments).deinit();
    }

    self.config.deinit();

    const allocator = self.arena.childAllocator();
    self.arena.deinit();
    allocator.destroy(&self);
}

pub fn create(self: Cni, request: plugin.Request, responser: *Responser) !void {
    _ = self;
    responser.write(request);
}

pub fn setup(self: Cni, request: plugin.Request, responser: *Responser) !void {
    var arena = try ArenaAllocator.init(self.arena.childAllocator());
    defer arena.deinit();

    const allocator = arena.allocator();

    const parsed_exec_request = json.parseFromValue(
        plugin.NetworkPluginExec,
        allocator,
        request.request,
        .{},
    ) catch |err| {
        responser.writeError("Can not parse request: {s}", .{@errorName(err)});
        return;
    };
    defer parsed_exec_request.deinit();
    const exec_request = parsed_exec_request.value;

    var env_map = std.process.EnvMap.init(allocator);
    try env_map.put("CNI_COMMAND", "ADD");
    try env_map.put("CNI_CONTAINERID", exec_request.container_id);
    try env_map.put("CNI_NETNS", request.netns.?);
    try env_map.put("CNI_IFNAME", exec_request.network_options.interface_name);
    try env_map.put("CNI_PATH", self.cni_plugin_dir);

    var args = std.ArrayList(u8).init(allocator);
    try args.appendSlice("K8S_POD_NAME=");
    try args.appendSlice(exec_request.container_name);
    try env_map.put("CNI_ARGS", args.items);

    // for (self.config.value.plugins) |cni| {}
}

pub fn teardown(self: Cni, request: plugin.Request, responser: *Responser) !void {
    _ = self;
    // TODO:
    responser.write(request);
}

const AttachmentKeyContext = struct {
    pub fn hash(self: AttachmentKeyContext, key: AttachmentKey) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHashStrat(&hasher, key.container_id, .Shallow);
        std.hash.autoHashStrat(&hasher, key.ifname, .Shallow);
        return hasher.final();
    }

    pub fn eql(self: AttachmentKeyContext, one: AttachmentKey, other: AttachmentKey) bool {
        _ = self;
        return std.mem.eql(u8, one.container_id, other.container_id) and
            std.mem.eql(u8, one.ifname, other.ifname);
    }
};

const CniConfig = struct {
    cniVersion: []const u8,
    name: []const u8,
    disableCheck: bool = false,
    plugins: json.Value,

    const ValidateError = error{
        PluginsIsEmpty,
        PluginsIsNotArray,
        PluginIsNotMap,
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

        const config = parsed_config.value;

        config.validate() catch |err| {
            try std.testing.expect(err == error.PluginsIsNotArray);
        };
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
        const config = parsed_config.value;
        config.validate() catch |err| {
            try std.testing.expect(err == error.PluginsIsEmpty);
        };
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
        const config = parsed_config.value;
        config.validate() catch |err| {
            try std.testing.expect(err == error.PluginIsNotMap);
        };
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
        const config = parsed_config.value;
        config.validate() catch |err| {
            try std.testing.expect(err == error.PluginTypeMissing);
        };
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
        const config = parsed_config.value;
        config.validate() catch |err| {
            try std.testing.expect(err == error.PluginTypeNotString);
        };
    }

    test "validate() will fail if the plugin type is not supported" {
        const allocator = std.testing.allocator;
        const data =
            \\{
            \\    "cniVersion": "0.3.1",
            \\    "name": "test",
            \\    "plugins": [
            \\        {
            \\            "type": "unsupported"
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
        config.validate() catch |err| {
            try std.testing.expect(err == error.PluginTypeUnsupported);
        };
    }

    test "validate() will success if the plugin type is supported" {
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

const PluginConf = struct {
    conf: json.ObjectMap,

    const ValidateError = error{
        PluginTypeMissing,
        PluginTypeNotString,
        PluginTypeUnsupported,
    };

    pub fn init(allocator: Allocator, cni_config: CniConfig, obj: json.ObjectMap) !PluginConf {
        const conf = try shadowCopy(allocator, obj);
        var plugin_conf = PluginConf{ .conf = conf };

        try plugin_conf.setName(cni_config.name);
        try plugin_conf.setCniVersion(cni_config.cniVersion);

        return plugin_conf;
    }

    pub fn validate(self: PluginConf, cni_name: []const u8) ValidateError!void {
        const type_value = self.conf.get("type") orelse {
            log.warn(
                "The plugin type in cni config '{s}' is missing",
                .{cni_name},
            );
            return error.PluginTypeMissing;
        };

        const plugin_type = switch (type_value) {
            .string => |s| s,
            else => {
                log.warn(
                    "The plugin type in cni config '{s}' is not string",
                    .{cni_name},
                );
                return error.PluginTypeNotString;
            },
        };

        if (!isSupportedPlugin(plugin_type)) {
            log.warn(
                "The plugin type '{s}' in cni config '{s}' is unsupported",
                .{ plugin_type, cni_name },
            );
            return error.PluginTypeUnsupported;
        }
    }

    pub fn getName(self: PluginConf) []const u8 {
        const name = self.conf.get("name");
        return if (name) |v| v.string else unreachable;
    }

    pub fn getCniVersion(self: PluginConf) []const u8 {
        const version = self.conf.get("cniVersion");
        return if (version) |v| v.string else unreachable;
    }

    pub fn getType(self: PluginConf) []const u8 {
        const plugin_type = self.conf.get("type");
        return if (plugin_type) |v| v.string else unreachable;
    }

    fn stringifyToPipe(self: PluginConf) !std.fs.File {
        const fds = try std.posix.pipe();

        const in = std.fs.File{ .handle = fds[0] };
        errdefer in.close();

        var out = std.fs.File{ .handle = fds[1] };
        defer out.close();

        try json.stringify(
            json.Value{ .object = self.conf },
            .{ .whitespace = .indent_2 },
            out.writer(),
        );

        return in;
    }

    test "stringifyToPipe() will success" {
        const allocator = std.testing.allocator;
        const raw_data =
            \\{
            \\    "cniVersion": "1.0.0",
            \\    "name": "test",
            \\    "type": "macvlan"
            \\}
        ;
        const parsed_data = try json.parseFromSlice(
            json.Value,
            allocator,
            raw_data,
            .{},
        );
        defer parsed_data.deinit();

        const exec_config = PluginConf{ .conf = parsed_data.value.object };

        const in = try exec_config.stringifyToPipe();
        defer in.close();

        const buf = try in.reader().readAllAlloc(allocator, 1024);
        defer allocator.free(buf);

        std.debug.print("{s}\n", .{buf});
        try std.testing.expect(buf.len > 0);
    }

    fn setName(self: *PluginConf, name: []const u8) !void {
        try self.conf.put("name", json.Value{ .string = name });
    }

    fn setCniVersion(self: *PluginConf, version: []const u8) !void {
        try self.conf.put("cniVersion", json.Value{ .string = version });
    }

    const supported_plugins = .{
        "macvlan",
    };

    fn isSupportedPlugin(name: []const u8) bool {
        inline for (supported_plugins) |supported_plugin| {
            log.debug("Checking supported plugin {s} with {s}", .{ supported_plugin, name });
            if (std.mem.eql(u8, name, supported_plugin)) {
                return true;
            }
        }
        return false;
    }

    fn shadowCopy(allocator: Allocator, src: json.ObjectMap) !json.ObjectMap {
        var new_obj = json.ObjectMap.init(allocator);
        var it = src.iterator();
        while (it.next()) |entry| {
            try new_obj.put(try allocator.dupe(u8, entry.key_ptr.*), entry.value_ptr.*);
        }
        return new_obj;
    }
};

const Attachment = struct {
    arena: ArenaAllocator,
    exec_configs: std.ArrayList(PluginConf),
    latest_exec: usize = 0,

    pub fn init(root_allocator: Allocator, cni_config: CniConfig) !Attachment {
        var arena = try ArenaAllocator.init(root_allocator);

        var attachment = Attachment{
            .arena = arena,
            .exec_configs = std.ArrayList(PluginConf).init(arena.allocator()),
        };
        errdefer attachment.deinit();

        try attachment.initExecConfig(cni_config);
        return attachment;
    }

    pub fn deinit(self: Attachment) void {
        self.exec_configs.deinit();
        self.arena.deinit();
    }

    test "init() will append exec config" {
        const allocator = std.testing.allocator;

        const raw_cni_config =
            \\{
            \\    "cniVersion": "0.3.1",
            \\    "name": "test",
            \\    "plugins": [
            \\        {
            \\            "type": "macvlan"
            \\        }
            \\    ]
            \\}
        ;
        const parsed_cni_config = try json.parseFromSlice(
            CniConfig,
            allocator,
            raw_cni_config,
            .{},
        );
        const cni_config = parsed_cni_config.value;
        defer parsed_cni_config.deinit();

        const attachment = try Attachment.init(allocator, cni_config);
        defer attachment.deinit();

        try std.testing.expect(attachment.exec_configs.items.len == 1);

        const exec_config = attachment.exec_configs.items[0];
        try std.testing.expectEqualSlices(u8, "test", exec_config.getName());
        try std.testing.expectEqualSlices(u8, "0.3.1", exec_config.getCniVersion());
        try std.testing.expectEqualSlices(u8, "macvlan", exec_config.getType());
    }

    fn initExecConfig(self: *Attachment, cni_config: CniConfig) !void {
        const cni_plugin = cni_config.plugins;
        const allocator = self.arena.allocator();

        switch (cni_plugin) {
            .array => |plugins| {
                for (plugins.items) |p| {
                    try self.appendExecConfig(allocator, cni_config, p);
                }
            },
            else => {},
        }
    }

    fn appendExecConfig(self: *Attachment, allocator: Allocator, cni_config: CniConfig, cni_plugin: json.Value) !void {
        switch (cni_plugin) {
            .object => |obj| {
                const exec_config = try PluginConf.init(allocator, cni_config, obj);
                try self.exec_configs.append(exec_config);
            },
            else => return,
        }
    }
};

test {
    _ = CniConfig;
    _ = Attachment;
    _ = PluginConf;
}
