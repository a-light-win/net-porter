const std = @import("std");
const json = std.json;
const log = std.log.scoped(.cni);
const Allocator = std.mem.Allocator;
const ArenaAllocator = @import("../utils/ArenaAllocator.zig");
const plugin = @import("../plugin.zig");
const Responser = @import("../common/Responser.zig");
const CniConfig = @import("CniConfig.zig").CniConfig;
const PluginConf = @import("PluginConf.zig").PluginConf;
const CNI_PLUGIN_TIMEOUT_MS = @import("PluginConf.zig").CNI_PLUGIN_TIMEOUT_MS;
const shadowCopy = @import("PluginConf.zig").shadowCopy;
const CniCommand = @import("Cni.zig").CniCommand;
const responseError = @import("Cni.zig").responseError;
const responseResult = @import("Cni.zig").responseResult;
const isValidPluginType = @import("CniLoader.zig").isValidPluginType;
const SlaacDetector = @import("SlaacDetector.zig");

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
        try std.testing.expectEqualSlices(u8, "test", exec_config.getName().?);
        try std.testing.expectEqualSlices(u8, "0.3.1", exec_config.getCniVersion().?);
        try std.testing.expectEqualSlices(u8, "macvlan", exec_config.getType().?);
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
                var exec_config = try PluginConf.init(allocator, cni_config, obj);
                errdefer exec_config.deinit();
                try self.exec_configs.append(allocator, exec_config);
            },
            else => return,
        }
    }

    /// Serialize the attachment state to JSON for disk persistence.
    /// Stores each plugin's config and its result (if executed).
    pub fn serializeState(self: Attachment, allocator: Allocator) ![]const u8 {
        var configs = try std.ArrayList(json.Value).initCapacity(allocator, self.exec_configs.items.len);
        errdefer configs.deinit(allocator);

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

            const exec_request = try request.requestExec();

            if (exec_config.isDhcp()) {
                try exec_config.setDhcpSocketPath(request.user_id.?);
            } else if (exec_config.isStatic()) {
                if (exec_request.network_options.static_ips) |static_ips| {
                    if (static_ips.len > 0) {
                        try exec_config.patchAddresses(static_ips);
                    }
                }
            }

            // Inject MAC address only into macvlan plugin config.
            // Strict CNI plugins may reject unknown keys; limit injection to
            // macvlan which natively reads the "mac" key.
            if (exec_config.isMacvlan()) {
                if (exec_request.network_options.static_mac) |mac| {
                    try exec_config.patchMacAddress(mac);
                }
            }
            const cmd = try self.cni_plugin_binary(tentative_allocator, exec_config.getType() orelse return error.InvalidConfig);
            const result = exec_config.exec(io, tentative_allocator, cmd, env_map, CNI_PLUGIN_TIMEOUT_MS) catch |err| switch (err) {
                error.CniPluginTimeout => {
                    log.warn(
                        "Setup {s} timed out after {d}ms on plugin {s}",
                        .{ request.request.exec.container_name, CNI_PLUGIN_TIMEOUT_MS, exec_config.getType() orelse "unknown" },
                    );
                    responser.writeError("CNI plugin timed out", .{});
                    return error.UnexpectedError;
                },
                else => return err,
            };
            if (result != .exited or result.exited != 0) {
                log.warn("Setup {s} failed", .{request.request.exec.container_name});
                try responseError(tentative_allocator, responser, exec_config.result.?);
                return error.UnexpectedError;
            }
        }

        // SLAAC IPv6 detection: when macvlan with a static MAC is used,
        // the kernel may auto-assign an IPv6 address via SLAAC that is
        // NOT reported by the CNI macvlan plugin's ADD response.
        if (self.exec_configs.items.len > 0) {
            const exec_request = try request.requestExec();
            const first_config = self.exec_configs.items[0];
            if (first_config.isMacvlan() and exec_request.network_options.static_mac != null) {
                self.detectAndInjectSlaacIpv6(
                    tentative_allocator,
                    netns,
                    exec_request.network_options.interface_name,
                ) catch |err| {
                    log.warn("SLAAC detection failed: {s}", .{@errorName(err)});
                };
            }
        }

        log.info("Setup {s} success", .{request.request.exec.container_name});
        try responseResult(
            tentative_allocator,
            responser,
            self.finalResult(.last) orelse return error.NoExecConfigs,
        );
    }

    pub fn teardown(self: *Attachment, io: std.Io, tentative_allocator: Allocator, request: plugin.Request, responser: *Responser) !void {
        _ = responser;
        // Response is sent by Handler.handle() after this returns.
        // Per netavark semantics, teardown must always report success to
        // the caller; CNI DEL failures are logged at error level so
        // operators can detect stale interfaces, leaked IPs, and orphaned
        // firewall rules that may need manual cleanup.
        const netns: []const u8 = request.netns orelse "/proc/self/ns/net";

        var env_map = try self.envMap(tentative_allocator, .DEL, request, netns);
        defer env_map.deinit();

        // Inject prevResult into ALL plugins (CNI spec: final ADD result)
        const final_add_result = self.finalResult(.last);

        var any_del_failed = false;
        var i: usize = 0;
        const len = self.exec_configs.items.len;
        while (i < len) : (i += 1) {
            var exec_config = &self.exec_configs.items[len - (i + 1)];

            // Inject prevResult for DEL (CNI spec requirement since v0.4.0)
            if (final_add_result) |prev_result| {
                try exec_config.setPrevResult(prev_result.items);
            }

            const cmd = try self.cni_plugin_binary(tentative_allocator, exec_config.getType() orelse return error.InvalidConfig);
            const result = exec_config.exec(io, tentative_allocator, cmd, env_map, CNI_PLUGIN_TIMEOUT_MS) catch |err| switch (err) {
                error.CniPluginTimeout => {
                    any_del_failed = true;
                    log.err(
                        "Teardown of plugin '{s}' timed out after {d}ms for container '{s}'; resources may need manual cleanup",
                        .{ exec_config.getType() orelse "unknown", CNI_PLUGIN_TIMEOUT_MS, request.request.exec.container_name },
                    );
                    continue;
                },
                else => return err,
            };

            if (result != .exited or result.exited != 0) {
                any_del_failed = true;
                log.err(
                    "Teardown of plugin '{s}' failed for container '{s}'; resources may need manual cleanup. detail: {s}",
                    .{
                        exec_config.getType() orelse "unknown",
                        request.request.exec.container_name,
                        exec_config.result.?.items,
                    },
                );
            }
        }

        if (any_del_failed) {
            log.warn(
                "Teardown completed with partial failures for container '{s}'; some network resources may need manual cleanup",
                .{request.request.exec.container_name},
            );
        }
    }

    /// Detect SLAAC IPv6 addresses on a macvlan interface and inject them
    /// into the last CNI plugin result. Non-fatal: failures are logged but
    /// do not prevent the setup from succeeding.
    fn detectAndInjectSlaacIpv6(
        self: *Attachment,
        allocator: std.mem.Allocator,
        netns: []const u8,
        ifname: []const u8,
    ) !void {
        const slaac_addrs = SlaacDetector.detect(
            allocator,
            netns,
            ifname,
            SlaacDetector.SLAAC_POLL_INTERVAL_MS,
            SlaacDetector.SLAAC_MAX_WAIT_MS,
        ) catch |err| {
            log.warn("SLAAC detect: {s}", .{@errorName(err)});
            return;
        };
        defer {
            for (slaac_addrs) |addr| allocator.free(addr.address);
            allocator.free(slaac_addrs);
        }

        if (slaac_addrs.len == 0) return;
        try self.injectSlaacIpv6(allocator, slaac_addrs, ifname);
    }

    /// Inject pre-detected SLAAC IPv6 addresses into the last CNI plugin result.
    /// Skips addresses already present (dedup). Non-fatal on parse/serialize errors.
    fn injectSlaacIpv6(
        self: *Attachment,
        allocator: std.mem.Allocator,
        slaac_addrs: []const SlaacDetector.Ipv6Addr,
        ifname: []const u8,
    ) !void {
        const last_config = &self.exec_configs.items[self.exec_configs.items.len - 1];
        const last_result = last_config.result orelse return;

        var parsed = json.parseFromSlice(json.Value, allocator, last_result.items, .{}) catch |err| {
            log.warn("SLAAC: failed to parse CNI result: {s}", .{@errorName(err)});
            return;
        };
        defer parsed.deinit();

        var result_obj = switch (parsed.value) {
            .object => |obj| obj,
            else => return,
        };

        // Find the interface index for the target ifname
        const interfaces_val = result_obj.get("interfaces") orelse return;
        const interfaces = switch (interfaces_val) {
            .array => |arr| arr.items,
            else => return,
        };

        var iface_index: u32 = 0;
        var found_iface = false;
        for (interfaces, 0..) |iface, i| {
            if (iface == .object) {
                if (iface.object.get("name")) |name| {
                    if (name == .string and std.mem.eql(u8, name.string, ifname)) {
                        iface_index = @intCast(i);
                        found_iface = true;
                        break;
                    }
                }
            }
        }
        if (!found_iface) return;

        // Collect existing IP addresses for deduplication
        const ips_val = result_obj.get("ips") orelse return;
        const existing_ips = switch (ips_val) {
            .array => |arr| arr.items,
            else => &[_]json.Value{},
        };

        // Build the new ips array with SLAAC addresses appended
        var new_ips = try std.ArrayList(json.Value).initCapacity(allocator, existing_ips.len + slaac_addrs.len);
        for (existing_ips) |ip| {
            try new_ips.append(allocator, ip);
        }

        var added_count: usize = 0;
        for (slaac_addrs) |slaac_addr| {
            const slaac_u128 = SlaacDetector.ipv6ToU128(slaac_addr.address);

            // Check for duplicates against existing IPs
            var is_duplicate = false;
            if (slaac_u128) |target| {
                for (existing_ips) |existing_ip| {
                    if (existing_ip == .object) {
                        if (existing_ip.object.get("address")) |addr_val| {
                            if (addr_val == .string) {
                                if (SlaacDetector.ipv6ToU128(addr_val.string)) |existing_u128| {
                                    if (existing_u128 == target) {
                                        is_duplicate = true;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if (!is_duplicate) {
                var ip_obj = try json.ObjectMap.init(allocator, &.{}, &.{});
                try ip_obj.put(allocator, "version", json.Value{ .string = "6" });
                try ip_obj.put(allocator, "interface", json.Value{ .integer = @intCast(iface_index) });
                try ip_obj.put(allocator, "address", json.Value{ .string = slaac_addr.address });
                try new_ips.append(allocator, .{ .object = ip_obj });
                added_count += 1;
            }
        }

        if (added_count == 0) {
            new_ips.deinit(allocator);
            return;
        }

        // Replace the ips array in the parsed result
        try result_obj.put(allocator, "ips", json.Value{ .array = json.Array.fromOwnedSlice(allocator, new_ips.items) });

        // Re-serialize using the plugin's arena allocator
        const plugin_alloc = last_config.arena.?.allocator();
        const new_result_str = json.Stringify.valueAlloc(plugin_alloc, parsed.value, .{}) catch |err| {
            log.warn("SLAAC: failed to serialize result: {s}", .{@errorName(err)});
            return;
        };

        // Free the old result and replace
        if (last_config.result) |*old| {
            old.deinit(plugin_alloc);
        }
        last_config.result = std.ArrayList(u8).fromOwnedSlice(new_result_str);
        log.info("Injected {d} SLAAC IPv6 address(es) into CNI result", .{added_count});
    }

    /// Build the CNI environment map for plugin execution.
    /// `netns` is the netns path — directly usable in the worker's namespace.
    fn envMap(self: Attachment, allocator: Allocator, cni_command: CniCommand, request: plugin.Request, netns: []const u8) !std.process.Environ.Map {
        const exec_request = try request.requestExec();

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
        // Validate plugin type identifier (whitelist + length + prefix)
        if (!isValidPluginType(plugin_type)) return error.InvalidPluginType;
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

    test "envMap omits MAC from CNI_ARGS (MAC is injected via JSON config)" {
        const allocator = std.testing.allocator;
        var test_arena = try ArenaAllocator.init(allocator);
        defer test_arena.deinit();

        var attachment = Attachment{
            .arena = try ArenaAllocator.init(allocator),
            .cni_plugin_dir = "/cni/bin",
            .exec_configs = std.ArrayList(PluginConf).empty,
        };
        defer attachment.deinit();

        const request = plugin.Request{
            .action = .setup,
            .request = .{
                .exec = .{
                    .container_name = "test-container",
                    .container_id = "test-id",
                    .network = .{
                        .driver = "net-porter",
                        .options = .{ .socket = "test-socket", .resource = "test-resource" },
                    },
                    .network_options = .{
                        .interface_name = "eth0",
                        .static_mac = "02:42:c0:a8:01:64",
                    },
                },
            },
        };

        var env_map = try attachment.envMap(test_arena.allocator(), .ADD, request, "/proc/self/ns/net");
        defer env_map.deinit();

        const cni_args = env_map.get("CNI_ARGS").?;
        try std.testing.expect(std.mem.indexOf(u8, cni_args, "MAC=") == null);
    }

    // --- injectSlaacIpv6 tests ---

    /// Helper: build an Attachment with one PluginConf carrying a given CNI result string.
    /// Each PluginConf gets its own arena, mirroring the real PluginConf.init() behavior.
    fn initTestAttachment(allocator: std.mem.Allocator, cni_result: []const u8) !Attachment {
        var arena = try ArenaAllocator.init(allocator);
        const arena_alloc = arena.allocator();

        var plugin_arena = try ArenaAllocator.init(allocator);
        const plugin_alloc = plugin_arena.allocator();

        var conf = try json.ObjectMap.init(plugin_alloc, &.{}, &.{});
        try conf.put(plugin_alloc, "type", json.Value{ .string = "macvlan" });
        try conf.put(plugin_alloc, "name", json.Value{ .string = "test" });
        try conf.put(plugin_alloc, "cniVersion", json.Value{ .string = "0.3.1" });

        const result_copy = try plugin_alloc.dupe(u8, cni_result);

        const plugin_conf = PluginConf{
            .arena = plugin_arena,
            .conf = conf,
            .result = std.ArrayList(u8).fromOwnedSlice(result_copy),
        };

        var attachment = Attachment{
            .arena = arena,
            .cni_plugin_dir = "/cni/bin",
            .exec_configs = std.ArrayList(PluginConf).empty,
        };
        try attachment.exec_configs.append(arena_alloc, plugin_conf);
        return attachment;
    }

    /// Helper: read the result JSON from the last exec_config and parse it.
    fn getLastResultJson(attachment: Attachment, allocator: std.mem.Allocator) ?json.Parsed(json.Value) {
        const last = attachment.exec_configs.items[attachment.exec_configs.items.len - 1];
        const result = last.result orelse return null;
        return json.parseFromSlice(json.Value, allocator, result.items, .{}) catch return null;
    }

    test "injectSlaacIpv6 adds new SLAAC addresses to CNI result" {
        const allocator = std.testing.allocator;

        const cni_result =
            \\{"interfaces":[{"name":"eth0"}],"ips":[{"version":"4","address":"10.0.0.1/24","interface":0}]}
        ;

        var attachment = try initTestAttachment(allocator, cni_result);
        defer attachment.deinit();

        // injectSlaacIpv6 allocates intermediates on the given allocator.
        // Use an arena so they are freed in bulk, matching production where
        // the tentative_allocator is freed after the request.
        var inject_arena = std.heap.ArenaAllocator.init(allocator);
        defer inject_arena.deinit();

        const addr_copy = try allocator.dupe(u8, "2001:db8::1/64");
        defer allocator.free(addr_copy);
        const slaac_addrs = [_]SlaacDetector.Ipv6Addr{
            .{ .address = addr_copy },
        };

        try attachment.injectSlaacIpv6(inject_arena.allocator(), &slaac_addrs, "eth0");

        const parsed = getLastResultJson(attachment, allocator) orelse unreachable;
        defer parsed.deinit();

        const ips = parsed.value.object.get("ips").?.array.items;
        try std.testing.expectEqual(@as(usize, 2), ips.len);

        // Original IPv4 entry
        try std.testing.expectEqualStrings("4", ips[0].object.get("version").?.string);

        // Injected SLAAC entry
        try std.testing.expectEqualStrings("6", ips[1].object.get("version").?.string);
        try std.testing.expectEqualStrings("2001:db8::1/64", ips[1].object.get("address").?.string);
        try std.testing.expectEqual(@as(i64, 0), ips[1].object.get("interface").?.integer);
    }

    test "injectSlaacIpv6 suppresses duplicate addresses" {
        const allocator = std.testing.allocator;

        const cni_result =
            \\{"interfaces":[{"name":"eth0"}],"ips":[{"version":"6","address":"2001:db8::1/64","interface":0}]}
        ;

        var attachment = try initTestAttachment(allocator, cni_result);
        defer attachment.deinit();

        var inject_arena = std.heap.ArenaAllocator.init(allocator);
        defer inject_arena.deinit();

        // Same address in expanded form — dedup should match by u128 value
        const addr_copy = try allocator.dupe(u8, "2001:0db8:0000:0000:0000:0000:0000:0001/64");
        defer allocator.free(addr_copy);
        const slaac_addrs = [_]SlaacDetector.Ipv6Addr{
            .{ .address = addr_copy },
        };

        try attachment.injectSlaacIpv6(inject_arena.allocator(), &slaac_addrs, "eth0");

        const last = attachment.exec_configs.items[0];
        const parsed = try json.parseFromSlice(json.Value, allocator, last.result.?.items, .{});
        defer parsed.deinit();

        const ips = parsed.value.object.get("ips").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), ips.len);
    }

    test "injectSlaacIpv6 skips gracefully when interfaces array missing" {
        const allocator = std.testing.allocator;

        const cni_result =
            \\{"ips":[]}
        ;

        var attachment = try initTestAttachment(allocator, cni_result);
        defer attachment.deinit();

        var inject_arena = std.heap.ArenaAllocator.init(allocator);
        defer inject_arena.deinit();

        const addr_copy = try allocator.dupe(u8, "2001:db8::1/64");
        defer allocator.free(addr_copy);
        const slaac_addrs = [_]SlaacDetector.Ipv6Addr{
            .{ .address = addr_copy },
        };

        try attachment.injectSlaacIpv6(inject_arena.allocator(), &slaac_addrs, "eth0");

        const last = attachment.exec_configs.items[0];
        const parsed = try json.parseFromSlice(json.Value, allocator, last.result.?.items, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("interfaces") == null);
    }

    test "injectSlaacIpv6 skips gracefully when ips array missing" {
        const allocator = std.testing.allocator;

        const cni_result =
            \\{"interfaces":[{"name":"eth0"}]}
        ;

        var attachment = try initTestAttachment(allocator, cni_result);
        defer attachment.deinit();

        var inject_arena = std.heap.ArenaAllocator.init(allocator);
        defer inject_arena.deinit();

        const addr_copy = try allocator.dupe(u8, "2001:db8::1/64");
        defer allocator.free(addr_copy);
        const slaac_addrs = [_]SlaacDetector.Ipv6Addr{
            .{ .address = addr_copy },
        };

        try attachment.injectSlaacIpv6(inject_arena.allocator(), &slaac_addrs, "eth0");

        const last = attachment.exec_configs.items[0];
        const parsed = try json.parseFromSlice(json.Value, allocator, last.result.?.items, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("ips") == null);
    }

    test "injectSlaacIpv6 is no-op with empty SLAAC list" {
        const allocator = std.testing.allocator;

        const cni_result =
            \\{"interfaces":[{"name":"eth0"}],"ips":[{"version":"4","address":"10.0.0.1/24","interface":0}]}
        ;

        var attachment = try initTestAttachment(allocator, cni_result);
        defer attachment.deinit();

        var inject_arena = std.heap.ArenaAllocator.init(allocator);
        defer inject_arena.deinit();

        const slaac_addrs = [_]SlaacDetector.Ipv6Addr{};
        try attachment.injectSlaacIpv6(inject_arena.allocator(), &slaac_addrs, "eth0");

        const last = attachment.exec_configs.items[0];
        const parsed = try json.parseFromSlice(json.Value, allocator, last.result.?.items, .{});
        defer parsed.deinit();

        const ips = parsed.value.object.get("ips").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), ips.len);
    }
};
