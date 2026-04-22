const std = @import("std");
const json = std.json;
const log = std.log.scoped(.cni);
const Allocator = std.mem.Allocator;
const ArenaAllocator = @import("../utils/ArenaAllocator.zig");
const plugin = @import("../plugin.zig");
const Responser = @import("../common/Responser.zig");
const CniConfig = @import("CniConfig.zig").CniConfig;
const PluginConf = @import("PluginConf.zig").PluginConf;
const shadowCopy = @import("PluginConf.zig").shadowCopy;
const CniCommand = @import("Cni.zig").CniCommand;
const responseError = @import("Cni.zig").responseError;
const responseResult = @import("Cni.zig").responseResult;

/// Transient attachment — created per request, not stored in memory.
/// State is persisted to disk via StateFile.
pub const Attachment = struct {
    arena: ArenaAllocator,
    exec_configs: std.ArrayList(PluginConf),
    cni_plugin_dir: []const u8,

    pub fn init(root_allocator: Allocator, cni_config: CniConfig, cni_plugin_dir: []const u8) !Attachment {
        const arena = try ArenaAllocator.init(root_allocator);

        var attachment = Attachment{
            .arena = arena,
            .exec_configs = std.ArrayList(PluginConf).empty,
            .cni_plugin_dir = cni_plugin_dir,
        };
        errdefer attachment.deinit();

        try attachment.initExecConfig(cni_config);
        return attachment;
    }

    pub fn deinit(self: *Attachment) void {
        for (self.exec_configs.items) |*exec_config| {
            exec_config.deinit();
        }
        const allocator = self.arena.allocator();
        self.exec_configs.deinit(allocator);
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

        var attachment = try Attachment.init(allocator, cni_config, "");
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
                try self.exec_configs.append(allocator, exec_config);
            },
            else => return,
        }
    }

    /// Serialize the attachment state to JSON for disk persistence.
    /// Stores each plugin's config and its result (if executed).
    pub fn serializeState(self: Attachment, allocator: Allocator) ![]const u8 {
        var configs = try std.ArrayList(json.Value).initCapacity(allocator, self.exec_configs.items.len);

        for (self.exec_configs.items) |exec_config| {
            const entry_obj = try json.ObjectMap.init(allocator, &.{}, &.{});
            var entry = json.Value{ .object = entry_obj };
            // Store the plugin config
            try entry.object.put(allocator, "conf", json.Value{ .object = exec_config.conf });
            // Store the result (if any — should be present after setup)
            if (exec_config.result) |result| {
                const result_parsed = try json.parseFromSlice(json.Value, allocator, result.items, .{
                    .ignore_unknown_fields = true,
                });
                try entry.object.put(allocator, "result", result_parsed.value);
            }
            configs.appendAssumeCapacity(entry);
        }

        var root = try json.ObjectMap.init(allocator, &.{}, &.{});
        try root.put(allocator, "version", json.Value{ .integer = 1 });
        try root.put(allocator, "cni_plugin_dir", json.Value{ .string = self.cni_plugin_dir });
        try root.put(allocator, "exec_configs", json.Value{ .array = json.Array.fromOwnedSlice(allocator, configs.items) });

        return try json.Stringify.valueAlloc(allocator, json.Value{ .object = root }, .{});
    }

    /// Deserialize attachment state from JSON read from disk.
    pub fn deserializeState(allocator: Allocator, state_json: []const u8, cni_plugin_dir: []const u8) !Attachment {
        const parsed = try json.parseFromSlice(struct {
            version: i64,
            exec_configs: []const struct {
                conf: json.Value,
                result: ?json.Value = null,
            },
        }, allocator, state_json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        // NOTE: parsed is intentionally not deinited here.
        // shadowCopy() performs a shallow copy of json.ObjectMap — keys are deep-copied
        // but json.Value entries are copied by value (pointer/length slices, not content).
        // Calling parsed.deinit() would free the internal ArenaAllocator that owns the
        // actual string/object/array data referenced by plugin_conf.conf, causing UAF.
        // All memory is allocated on `allocator` (an arena in all current callers),
        // so it will be reclaimed when the outer arena is deinitialized.

        var arena = try ArenaAllocator.init(allocator);
        var attachment = Attachment{
            .arena = arena,
            .exec_configs = std.ArrayList(PluginConf).empty,
            .cni_plugin_dir = cni_plugin_dir,
        };

        const arena_alloc = arena.allocator();
        for (parsed.value.exec_configs) |entry| {
            // Reconstruct PluginConf from stored config
            const conf_obj = switch (entry.conf) {
                .object => |obj| obj,
                else => continue,
            };
            const conf_copy = try shadowCopy(arena_alloc, conf_obj);
            var plugin_conf = PluginConf{
                .arena = arena,
                .conf = conf_copy,
            };

            // Restore result if present
            if (entry.result) |result_val| {
                const result_str = try json.Stringify.valueAlloc(arena_alloc, result_val, .{});
                plugin_conf.result = std.ArrayList(u8).fromOwnedSlice(result_str);
            }

            try attachment.exec_configs.append(arena_alloc, plugin_conf);
        }

        return attachment;
    }

    const FinalResultPos = enum { first, last };

    fn finalResult(self: Attachment, pos: FinalResultPos) ?std.ArrayList(u8) {
        const len = self.exec_configs.items.len;
        if (len == 0) {
            return null;
        }

        if (pos == .first) {
            return self.exec_configs.items[0].result;
        } else {
            return self.exec_configs.items[len - 1].result;
        }
    }

    pub fn setup(self: *Attachment, io: std.Io, tentative_allocator: Allocator, request: plugin.Request, responser: *Responser) !void {
        // In the per-user daemon architecture, the worker runs inside the
        // container's mount namespace. The netns path from the request is
        // directly usable — no fd passing or resolution needed.
        const netns: []const u8 = request.netns orelse "/proc/self/ns/net";

        var env_map = try self.envMap(tentative_allocator, .ADD, request, netns);
        defer env_map.deinit();

        for (self.exec_configs.items, 0..) |*exec_config, i| {
            // Inject prevResult from previous plugin's result (CNI spec chaining)
            if (i > 0) {
                const prev = self.exec_configs.items[i - 1];
                if (prev.result) |prev_result| {
                    try exec_config.setPrevResult(prev_result.items);
                }
            }

            if (exec_config.isDhcp()) {
                try exec_config.setDhcpSocketPath(request.user_id.?);
            } else if (exec_config.isStatic()) {
                const exec_request = request.requestExec();
                if (exec_request.network_options.static_ips) |static_ips| {
                    if (static_ips.len > 0) {
                        try exec_config.patchAddresses(static_ips);
                    }
                }
            }
            const cmd = try self.cni_plugin_binary(tentative_allocator, exec_config.getType());
            const result = try exec_config.exec(io, tentative_allocator, cmd, env_map);
            if (result.exited != 0) {
                log.warn("Setup {s} failed", .{request.request.exec.container_name});
                try responseError(tentative_allocator, responser, exec_config.result.?);
                return error.UnexpectedError;
            }
        }

        log.info("Setup {s} success", .{request.request.exec.container_name});
        try responseResult(
            tentative_allocator,
            responser,
            self.finalResult(.last).?,
        );
    }

    pub fn teardown(self: *Attachment, io: std.Io, tentative_allocator: Allocator, request: plugin.Request, responser: *Responser) !void {
        _ = responser;
        // Response is sent by Handler.handle() after this returns.
        const netns: []const u8 = request.netns orelse "/proc/self/ns/net";

        var env_map = try self.envMap(tentative_allocator, .DEL, request, netns);
        defer env_map.deinit();

        // Inject prevResult into ALL plugins (CNI spec: final ADD result)
        const final_add_result = self.finalResult(.last);

        var i: usize = 0;
        const len = self.exec_configs.items.len;
        while (i < len) : (i += 1) {
            var exec_config = &self.exec_configs.items[len - (i + 1)];

            // Inject prevResult for DEL (CNI spec requirement since v0.4.0)
            if (final_add_result) |prev_result| {
                try exec_config.setPrevResult(prev_result.items);
            }

            const cmd = try self.cni_plugin_binary(tentative_allocator, exec_config.getType());
            const result = try exec_config.exec(io, tentative_allocator, cmd, env_map);

            if (result.exited != 0) {
                log.warn(
                    "Teardown {s} failed on step {s}, ignore it. the detail error is {s}",
                    .{
                        request.request.exec.container_name,
                        exec_config.getType(),
                        exec_config.result.?.items,
                    },
                );
            }
        }
    }

    /// Build the CNI environment map for plugin execution.
    /// `netns` is the netns path — directly usable in the worker's namespace.
    fn envMap(self: Attachment, allocator: Allocator, cni_command: CniCommand, request: plugin.Request, netns: []const u8) !std.process.Environ.Map {
        const exec_request = request.requestExec();

        var env_map = std.process.Environ.Map.init(allocator);
        try env_map.put("CNI_COMMAND", @tagName(cni_command));
        try env_map.put("CNI_CONTAINERID", exec_request.container_id);
        try env_map.put("CNI_NETNS", netns);
        try env_map.put("CNI_IFNAME", exec_request.network_options.interface_name);
        try env_map.put("CNI_PATH", self.cni_plugin_dir);

        var args = std.ArrayList(u8).empty;
        try args.appendSlice(allocator, "IgnoreUnknown=true");
        try args.appendSlice(allocator, ";K8S_POD_NAME=");
        try args.appendSlice(allocator, exec_request.container_name);
        try env_map.put("CNI_ARGS", args.items);

        return env_map;
    }

    fn cni_plugin_binary(self: Attachment, allocator: Allocator, plugin_type: []const u8) ![]const u8 {
        // Reject path traversal characters in plugin type
        if (std.mem.indexOf(u8, plugin_type, "/") != null) return error.InvalidPluginType;
        if (std.mem.indexOf(u8, plugin_type, "..") != null) return error.InvalidPluginType;
        const total_len = self.cni_plugin_dir.len + 1 + plugin_type.len;
        var bin = try allocator.alloc(u8, total_len);
        @memcpy(bin[0..self.cni_plugin_dir.len], self.cni_plugin_dir);
        bin[self.cni_plugin_dir.len] = '/';
        @memcpy(bin[self.cni_plugin_dir.len + 1 .. total_len], plugin_type);

        return bin;
    }

    test "cni_plugin_binary() should return a valid path" {
        const allocator = std.testing.allocator;
        var attachment = Attachment{
            .arena = try ArenaAllocator.init(allocator),
            .cni_plugin_dir = "/path/to/cni/plugins",
            .exec_configs = std.ArrayList(PluginConf).empty,
        };
        defer attachment.deinit();
        const bin = try attachment.cni_plugin_binary(allocator, "macvlan");
        defer allocator.free(bin);
        try std.testing.expectEqualSlices(u8, "/path/to/cni/plugins/macvlan", bin);
    }
};
