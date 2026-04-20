const std = @import("std");
const json = std.json;
const log = std.log.scoped(.cni);
const Allocator = std.mem.Allocator;
const ArenaAllocator = @import("../utils/ArenaAllocator.zig");
const plugin = @import("../plugin.zig");
const Responser = @import("../worker/Responser.zig");
const managed_type = @import("managed_type.zig");
const StateFile = @import("StateFile.zig");

const Cni = @This();

const max_plugin_output: usize = 4 * 1024 * 1024; // 4 MB

arena: ArenaAllocator,
io: std.Io,
cni_plugin_dir: []const u8,
config: CniConfig,
mutex: std.Io.Mutex = .init,

/// Initialize from standard CNI config.
/// Validates that the first plugin has a valid ipam configuration.
pub fn initFromConfig(io: std.Io, root_allocator: Allocator, config: CniConfig, cni_plugin_dir: []const u8) !*Cni {
    var arena = try ArenaAllocator.init(root_allocator);
    errdefer arena.deinit();

    // Validate ipam config in first plugin
    if (config.plugins.array.items.len == 0) {
        log.err("CNI config '{s}' has no plugins configured", .{config.name});
        return error.PluginsIsEmpty;
    }
    const first_plugin = config.plugins.array.items[0];
    const ipam = first_plugin.object.get("ipam") orelse {
        log.err("CNI config '{s}' missing ipam field in first plugin", .{config.name});
        return error.MissingIpamConfig;
    };
    if (ipam != .object) return error.InvalidIpamConfig;
    const ipam_type = ipam.object.get("type") orelse return error.MissingIpamType;
    if (ipam_type != .string) return error.InvalidIpamType;

    // Validate ipam type is supported (dhcp or static)
    if (!std.mem.eql(u8, ipam_type.string, "dhcp") and !std.mem.eql(u8, ipam_type.string, "static")) {
        log.err("Unsupported ipam type '{s}' in config '{s}'", .{ ipam_type.string, config.name });
        return error.UnsupportedIpamType;
    }

    const cni = try arena.allocator().create(Cni);
    cni.* = Cni{
        .io = io,
        .arena = arena,
        .cni_plugin_dir = cni_plugin_dir,
        .config = config,
    };
    return cni;
}

pub fn deinit(self: *Cni) void {
    const allocator = self.arena.childAllocator();
    self.arena.deinit();
    allocator.destroy(self);
}

pub fn create(self: *Cni, tentative_allocator: Allocator, request: plugin.Request, responser: *Responser) !void {
    _ = self;
    _ = tentative_allocator;
    const raw = request.raw_request orelse return error.MissingRawRequest;
    responser.write(raw);
}

const CniCommand = enum {
    ADD,
    DEL,
    GET,
    VERSION,
};

pub fn setup(self: *Cni, tentative_allocator: Allocator, request: plugin.Request, responser: *Responser, caller_uid: std.posix.uid_t) !void {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);

    const exec_request = request.requestExec();
    const container_id = exec_request.container_id;
    const ifname = exec_request.network_options.interface_name;

    // Check if state file already exists (attachment already set up)
    if (StateFile.exists(tentative_allocator, caller_uid, container_id, ifname)) {
        responser.writeError("The setup has been executed, teardown first", .{});
        return;
    }

    // Create transient attachment for executing CNI plugins
    var attachment = try Attachment.init(tentative_allocator, self.config, self.cni_plugin_dir);
    defer attachment.deinit();

    // Execute CNI ADD chain with prevResult chaining between plugins
    try attachment.setup(self.io, tentative_allocator, request, responser);

    // Persist state on success: store the attachment's exec configs and final result
    const state_json = try attachment.serializeState(tentative_allocator);
    defer tentative_allocator.free(state_json);

    StateFile.write(self.io, tentative_allocator, caller_uid, container_id, ifname, state_json) catch |err| {
        log.warn("Failed to persist state for uid={d}, container_id={s}: {s}", .{ caller_uid, container_id, @errorName(err) });
        // State file write failed, but CNI setup succeeded — log warning and continue
    };
}

pub fn teardown(self: *Cni, tentative_allocator: Allocator, request: plugin.Request, responser: *Responser, caller_uid: std.posix.uid_t) !void {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);

    const exec_request = request.requestExec();
    const container_id = exec_request.container_id;
    const ifname = exec_request.network_options.interface_name;

    // Read state file
    const state_json = StateFile.read(self.io, tentative_allocator, caller_uid, container_id, ifname) catch |err| {
        if (err == error.FileNotFound) {
            log.warn(
                "No state file found for uid={d}, container_id={s}, ifname={s}, skipping CNI DEL. This can happen if the server was restarted.",
                .{ caller_uid, container_id, ifname },
            );
            log.info("Teardown {s} is complete", .{request.request.exec.container_name});
            return;
        }
        log.warn("Failed to read state for uid={d}, container_id={s}: {s}", .{ caller_uid, container_id, @errorName(err) });
        return err;
    };
    defer tentative_allocator.free(state_json);

    // Deserialize state into transient attachment
    var attachment = try Attachment.deserializeState(tentative_allocator, state_json, self.cni_plugin_dir);
    defer attachment.deinit();

    // Execute CNI DEL chain (reverse order, all plugins get final ADD result as prevResult)
    try attachment.teardown(self.io, tentative_allocator, request, responser);

    // Remove state file
    StateFile.remove(self.io, tentative_allocator, caller_uid, container_id, ifname) catch |err| {
        log.warn("Failed to remove state file for uid={d}, container_id={s}: {s}", .{ caller_uid, container_id, @errorName(err) });
    };

    log.info("Teardown {s} for uid={d} is complete", .{ request.request.exec.container_name, caller_uid });
}

const CniErrorMsg = struct {
    code: u32,
    msg: []const u8,
};

const ManagedResponse = managed_type.ManagedType(plugin.Response);

const CniResult = struct {
    cniVersion: []const u8,
    interfaces: []Interface,
    ips: []IpConfig,
    routes: ?[]RouteConfig = null,
    dns: ?DNSConfig = null,

    fn toNetavarkResponse(self: CniResult, root_allocator: Allocator) !ManagedResponse {
        var response = ManagedResponse{
            .v = plugin.Response{
                .dns_search_domains = if (self.dns) |dns| dns.search else null,
                .dns_server_ips = if (self.dns) |dns| dns.nameservers else null,
                .interfaces = .{},
            },
            .arena = try ArenaAllocator.init(root_allocator),
        };
        errdefer response.deinit();
        const allocator = response.arena.?.allocator();

        for (self.interfaces, 0..) |iface, index| {
            var subnets = std.ArrayList(plugin.Subnet).empty;
            for (self.ips) |ip| {
                if (ip.interface != index) {
                    continue;
                }
                try subnets.append(allocator, .{
                    .ipnet = ip.address,
                    .gateway = ip.gateway,
                });
            }

            try response.v.interfaces.map.put(
                allocator,
                iface.name,
                .{
                    .mac_address = iface.mac,
                    .subnets = try subnets.toOwnedSlice(allocator),
                },
            );
        }

        return response;
    }
};

const Interface = struct {
    name: []const u8,
    mac: []const u8,
    sandbox: ?[]const u8 = null,
};

const IpConfig = struct {
    // index of interface in interfaces field
    interface: u32,
    // ip address with prefix length
    address: []const u8,
    gateway: ?[]const u8 = null,
};

const RouteConfig = struct {
    dst: []const u8,
    gw: ?[]const u8 = null,
};

const DNSConfig = struct {
    nameservers: ?[]const []const u8 = null,
    domain: ?[]const u8 = null,
    search: ?[]const []const u8 = null,
    options: ?[]const []const u8 = null,
};

fn responseError(allocator: Allocator, responser: *Responser, stdout: std.ArrayList(u8)) !void {
    var parsed_error_msg = try json.parseFromSlice(
        CniErrorMsg,
        allocator,
        stdout.items,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed_error_msg.deinit();

    const error_msg = parsed_error_msg.value;
    responser.writeError(
        "{s}({d})",
        .{ error_msg.msg, error_msg.code },
    );
}

fn responseResult(allocator: Allocator, responser: *Responser, stdout: std.ArrayList(u8)) !void {
    var parsed_result = try json.parseFromSlice(
        CniResult,
        allocator,
        stdout.items,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed_result.deinit();
    const result = parsed_result.value;

    var managed_response = try result.toNetavarkResponse(allocator);
    defer managed_response.deinit();

    responser.write(managed_response.v);
}

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

const PluginConf = struct {
    conf: json.ObjectMap,
    arena: ?ArenaAllocator = null,
    result: ?std.ArrayList(u8) = null,

    const ValidateError = error{
        PluginTypeMissing,
        PluginTypeNotString,
    };

    pub fn init(root_allocator: Allocator, cni_config: CniConfig, obj: json.ObjectMap) !PluginConf {
        var arena = try ArenaAllocator.init(root_allocator);
        errdefer arena.deinit();

        const allocator = arena.allocator();
        const conf = try shadowCopy(allocator, obj);

        var plugin_conf = PluginConf{
            .arena = arena,
            .conf = conf,
        };

        try plugin_conf.setName(cni_config.name);
        try plugin_conf.setCniVersion(cni_config.cniVersion);

        return plugin_conf;
    }

    pub fn deinit(self: *PluginConf) void {
        const alloc = self.arena.?.allocator();
        self.conf.deinit(alloc);

        if (self.result) |*result| {
            const allocator = self.arena.?.allocator();
            result.deinit(allocator);
        }

        if (self.arena) |*arena| {
            arena.deinit();
        }
    }

    pub fn validate(self: PluginConf, cni_name: []const u8) ValidateError!void {
        const type_value = self.conf.get("type") orelse {
            log.warn(
                "The plugin type in cni config '{s}' is missing",
                .{cni_name},
            );
            return error.PluginTypeMissing;
        };

        switch (type_value) {
            .string => {},
            else => {
                log.warn(
                    "The plugin type in cni config '{s}' is not string",
                    .{cni_name},
                );
                return error.PluginTypeNotString;
            },
        }
    }

    pub fn getName(self: PluginConf) []const u8 {
        const name = self.conf.get("name");
        return if (name) |v| switch (v) {
            .string => |v_str| v_str,
            else => unreachable,
        } else unreachable;
    }

    pub fn getCniVersion(self: PluginConf) []const u8 {
        const version = self.conf.get("cniVersion");
        return if (version) |v| switch (v) {
            .string => |v_str| v_str,
            else => unreachable,
        } else unreachable;
    }

    pub fn getType(self: PluginConf) []const u8 {
        const plugin_type = self.conf.get("type");
        return if (plugin_type) |v| switch (v) {
            .string => |v_str| v_str,
            else => unreachable,
        } else unreachable;
    }

    pub fn getDhcpSocketPath(self: PluginConf) []const u8 {
        if (self.conf.get("ipam")) |ipam| {
            switch (ipam) {
                .object => |ipam_obj| {
                    if (ipam_obj.get("daemonSocketPath")) |socket| {
                        switch (socket) {
                            .string => |socket_str| return socket_str,
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
        return "/run/cni/dhcp.sock";
    }

    fn setDhcpSocketPath(self: *PluginConf, uid: u32) !void {
        const allocator = self.arena.?.allocator();

        const ipam = self.conf.get("ipam") orelse return;
        const ipam_obj = switch (ipam) {
            .object => |obj| obj,
            else => return,
        };

        if (ipam_obj.get("daemonSocketPath")) |_| {
            return;
        }

        const ipam_type = ipam_obj.get("type") orelse return;
        const type_str = switch (ipam_type) {
            .string => |s| s,
            else => return,
        };

        // /run/net-porter/workers/<uid>/ is root-owned.
        // Both DHCP daemon and CNI dhcp plugin run as root children of the worker.
        const path = try std.fmt.allocPrint(
            allocator,
            "/run/net-porter/workers/{d}/dhcp.sock",
            .{uid},
        );

        // Build a fresh ipam ObjectMap to avoid mutating the shared original
        var new_ipam = try json.ObjectMap.init(allocator, &.{}, &.{});
        try new_ipam.put(allocator, "type", .{ .string = type_str });
        try new_ipam.put(allocator, "daemonSocketPath", .{ .string = path });

        try self.conf.put(allocator, "ipam", .{ .object = new_ipam });
    }

    pub fn isDhcp(self: PluginConf) bool {
        if (self.conf.get("ipam")) |ipam| {
            switch (ipam) {
                .object => |ipam_obj| {
                    if (ipam_obj.get("type")) |ipam_type| {
                        switch (ipam_type) {
                            .string => |type_str| {
                                return std.mem.eql(u8, "dhcp", type_str);
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
        return false;
    }

    pub fn isStatic(self: PluginConf) bool {
        if (self.conf.get("ipam")) |ipam| {
            switch (ipam) {
                .object => |ipam_obj| {
                    if (ipam_obj.get("type")) |ipam_type| {
                        switch (ipam_type) {
                            .string => |type_str| {
                                return std.mem.eql(u8, "static", type_str);
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
        return false;
    }

    fn isIpv6(addr: []const u8) bool {
        return std.mem.indexOf(u8, addr, ":") != null;
    }

    /// Find the index of a template address entry matching the given IP's address family.
    fn findMatchingSubnet(ip: []const u8, template_addrs: []const json.Value) ?usize {
        const ip_v6 = isIpv6(ip);
        for (template_addrs, 0..) |addr_val, i| {
            const addr_obj = switch (addr_val) {
                .object => |o| o,
                else => continue,
            };
            const addr_str = switch (addr_obj.get("address") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            if (isIpv6(addr_str) == ip_v6) return i;
        }
        return null;
    }

    /// Replace template addresses in the ipam config with actual IPs.
    /// Routes, DNS, and other ipam fields are preserved from the CNI config as-is.
    fn patchAddresses(self: *PluginConf, ips: []const []const u8) !void {
        const allocator = self.arena.?.allocator();

        // Read ipam from this plugin's own config JSON
        const ipam = self.conf.get("ipam") orelse return;
        const ipam_obj = switch (ipam) {
            .object => |obj| obj,
            else => return,
        };

        // Only applicable to static IPAM
        const ipam_type = ipam_obj.get("type") orelse return;
        if (ipam_type != .string or !std.mem.eql(u8, "static", ipam_type.string)) return;

        // Get template addresses from the CNI config's ipam
        const template_addrs = switch (ipam_obj.get("addresses") orelse return) {
            .array => |a| a.items,
            else => return,
        };

        // Build actual addresses by matching requested IPs to template subnets by address family
        var new_addrs = try json.Array.initCapacity(allocator, ips.len);
        for (ips) |ip| {
            const idx = findMatchingSubnet(ip, template_addrs) orelse continue;
            const tmpl_obj = template_addrs[idx].object;
            const tmpl_addr = switch (tmpl_obj.get("address") orelse continue) {
                .string => |s| s,
                else => continue,
            };

            // Extract prefix from template address (e.g. "192.168.1.0/24" → "24")
            const slash_pos = std.mem.lastIndexOf(u8, tmpl_addr, "/") orelse continue;
            const prefix = tmpl_addr[slash_pos + 1 ..];

            // Build actual address: "192.168.1.15/24"
            const actual_addr = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ip, prefix });

            var addr_obj = try json.ObjectMap.init(allocator, &.{}, &.{});
            try addr_obj.put(allocator, "address", .{ .string = actual_addr });
            // Copy gateway from template if present
            if (tmpl_obj.get("gateway")) |gw| {
                try addr_obj.put(allocator, "gateway", gw);
            }
            new_addrs.appendAssumeCapacity(.{ .object = addr_obj });
        }

        // Build new ipam: shadow-copy existing fields, replace only addresses
        var new_ipam = try shadowCopy(allocator, ipam_obj);
        try new_ipam.put(allocator, "addresses", .{ .array = new_addrs });
        try self.conf.put(allocator, "ipam", .{ .object = new_ipam });
    }

    test "isDhcp() will return false if the ipam type is not dhcp" {
        const root_allocator = std.testing.allocator;
        var arena = try ArenaAllocator.init(root_allocator);
        const allocator = arena.allocator();
        defer arena.deinit();

        // No ipam field
        var plugin_conf = PluginConf{ .conf = try json.ObjectMap.init(allocator, &.{}, &.{}) };
        try std.testing.expect(!plugin_conf.isDhcp());

        // Ipam field is not object type
        try plugin_conf.conf.put(allocator, "ipam", json.Value{ .bool = true });
        try std.testing.expect(!plugin_conf.isDhcp());

        // Have ipam field but no type field
        try plugin_conf.conf.put(allocator, "ipam", json.Value{ .object = try json.ObjectMap.init(allocator, &.{}, &.{}) });
        try std.testing.expect(!plugin_conf.isDhcp());

        // Ipam type field is not string type
        try plugin_conf.conf.getPtr("ipam").?.object.put(allocator, "type", json.Value{ .bool = true });
        try std.testing.expect(!plugin_conf.isDhcp());

        // Ipam type field is not 'dhcp'
        try plugin_conf.conf.getPtr("ipam").?.object.put(allocator, "type", json.Value{ .string = "static" });
        try std.testing.expect(!plugin_conf.isDhcp());
    }

    test "isDhcp() will return true if the type is dhcp" {
        const root_allocator = std.testing.allocator;
        var arena = try ArenaAllocator.init(root_allocator);
        const allocator = arena.allocator();
        defer arena.deinit();

        var plugin_conf = PluginConf{ .conf = try json.ObjectMap.init(allocator, &.{}, &.{}) };
        try plugin_conf.conf.put(allocator, "ipam", json.Value{ .object = try json.ObjectMap.init(allocator, &.{}, &.{}) });
        try plugin_conf.conf.getPtr("ipam").?.object.put(allocator, "type", json.Value{ .string = "dhcp" });

        try std.testing.expect(plugin_conf.isDhcp());
    }

    test "isStatic() will return true if the type is static" {
        const root_allocator = std.testing.allocator;
        var arena = try ArenaAllocator.init(root_allocator);
        const allocator = arena.allocator();
        defer arena.deinit();

        var plugin_conf = PluginConf{ .conf = try json.ObjectMap.init(allocator, &.{}, &.{}) };
        try plugin_conf.conf.put(allocator, "ipam", json.Value{ .object = try json.ObjectMap.init(allocator, &.{}, &.{}) });
        try plugin_conf.conf.getPtr("ipam").?.object.put(allocator, "type", json.Value{ .string = "static" });

        try std.testing.expect(plugin_conf.isStatic());
    }

    test "isStatic() will return false if the type is dhcp" {
        const root_allocator = std.testing.allocator;
        var arena = try ArenaAllocator.init(root_allocator);
        const allocator = arena.allocator();
        defer arena.deinit();

        var plugin_conf = PluginConf{ .conf = try json.ObjectMap.init(allocator, &.{}, &.{}) };
        try plugin_conf.conf.put(allocator, "ipam", json.Value{ .object = try json.ObjectMap.init(allocator, &.{}, &.{}) });
        try plugin_conf.conf.getPtr("ipam").?.object.put(allocator, "type", json.Value{ .string = "dhcp" });

        try std.testing.expect(!plugin_conf.isStatic());
    }

    fn stringify(self: PluginConf, io: std.Io, stream: std.Io.File) !void {
        var write_buffer: [4096]u8 = undefined;
        var file_writer = stream.writer(io, &write_buffer);
        try json.Stringify.value(
            json.Value{ .object = self.conf },
            .{ .whitespace = .indent_2 },
            &file_writer.interface,
        );
        try file_writer.end();
    }

    test "stringify() will success" {
        const allocator = std.testing.allocator;
        const io = std.testing.io;
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

        var fds: [2]i32 = undefined;
        const rc = std.os.linux.pipe(&fds);
        if (rc != 0) return error.Unexpected;
        var in = std.Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } };
        defer in.close(io);

        var out = std.Io.File{ .handle = fds[1], .flags = .{ .nonblocking = false } };
        try exec_config.stringify(io, out);
        out.close(io);

        const buf = blk: {
            var read_buffer: [1024]u8 = undefined;
            var file_reader = in.reader(io, &read_buffer);
            break :blk try file_reader.interface.allocRemaining(allocator, .limited(1024));
        };
        defer allocator.free(buf);

        std.debug.print("{s}\n", .{buf});
        try std.testing.expect(buf.len > 0);
    }

    fn setName(self: *PluginConf, name: []const u8) !void {
        try self.conf.put(self.arena.?.allocator(), "name", json.Value{ .string = name });
    }

    fn setCniVersion(self: *PluginConf, version: []const u8) !void {
        try self.conf.put(self.arena.?.allocator(), "cniVersion", json.Value{ .string = version });
    }

    /// Inject a prevResult into the plugin config from a CNI result JSON string.
    /// The result is parsed into a proper json.Value so it serializes as a nested JSON object.
    pub fn setPrevResult(self: *PluginConf, result: []const u8) !void {
        const allocator = self.arena.?.allocator();
        // Parse the result JSON string into a json.Value
        const parsed = try json.parseFromSlice(json.Value, allocator, result, .{
            .ignore_unknown_fields = true,
        });
        // Insert parsed value into conf. Memory lives in the arena; no need to deinit parsed.
        try self.conf.put(allocator, "prevResult", parsed.value);
    }

    fn shadowCopy(allocator: Allocator, src: json.ObjectMap) !json.ObjectMap {
        var new_obj = try json.ObjectMap.init(allocator, &.{}, &.{});
        var it = src.iterator();
        while (it.next()) |entry| {
            try new_obj.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), entry.value_ptr.*);
        }
        return new_obj;
    }

    fn exec(self: *PluginConf, io: std.Io, tentative_allocator: Allocator, cmd: []const u8, env_map: std.process.Environ.Map) !std.process.Child.Term {
        _ = tentative_allocator;
        const allocator = self.arena.?.allocator();

        // Execute CNI plugin directly in host namespace.
        // No nsenter — the binary path is resolved from the host filesystem,
        // and CNI_NETNS has been resolved to a host-valid path via NetnsResolver.
        var process = try std.process.spawn(io, .{
            .argv = &[_][]const u8{cmd},
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .environ_map = &env_map,
        });
        // Ensure child process is cleaned up on any error between spawn and wait.
        // Without this, pipe fds leak and the child becomes a zombie process.
        errdefer {
            if (process.stdin) |f| f.close(io);
            if (process.stdout) |f| f.close(io);
            if (process.stderr) |f| f.close(io);
            if (process.wait(io)) |_| {} else |_| {} // reap zombie
        }

        var stdout = std.ArrayListUnmanaged(u8).empty;
        defer stdout.deinit(allocator);
        var stderr = std.ArrayListUnmanaged(u8).empty;
        defer stderr.deinit(allocator);

        try self.stringify(io, process.stdin.?);
        process.stdin.?.close(io);
        process.stdin = null;

        // Read stdout and stderr into buffers
        if (process.stdout) |out_file| {
            var read_buffer: [4096]u8 = undefined;
            var file_reader = out_file.reader(io, &read_buffer);
            const data = try file_reader.interface.allocRemaining(allocator, .limited(max_plugin_output));
            stdout = std.ArrayListUnmanaged(u8).fromOwnedSlice(data);
        }
        if (process.stderr) |err_file| {
            var read_buffer: [4096]u8 = undefined;
            var file_reader = err_file.reader(io, &read_buffer);
            const data = try file_reader.interface.allocRemaining(allocator, .limited(max_plugin_output));
            stderr = std.ArrayListUnmanaged(u8).fromOwnedSlice(data);
        }

        const result = try process.wait(io);

        self.result = std.ArrayList(u8).fromOwnedSlice(try stdout.toOwnedSlice(allocator));
        return result;
    }
};

/// Transient attachment — created per request, not stored in memory.
/// State is persisted to disk via StateFile.
const Attachment = struct {
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
    fn serializeState(self: Attachment, allocator: Allocator) ![]const u8 {
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
    fn deserializeState(allocator: Allocator, state_json: []const u8, cni_plugin_dir: []const u8) !Attachment {
        const parsed = try json.parseFromSlice(struct {
            version: i64,
            exec_configs: []const struct {
                conf: json.Value,
                result: ?json.Value = null,
            },
        }, allocator, state_json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        defer parsed.deinit();

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
            const conf_copy = try PluginConf.shadowCopy(arena_alloc, conf_obj);
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

    fn setup(self: *Attachment, io: std.Io, tentative_allocator: Allocator, request: plugin.Request, responser: *Responser) !void {
        // In the per-user daemon architecture, the worker runs inside the
        // container's mount namespace. The netns path from the request is
        // directly usable — no fd passing or resolution needed.
        const netns: []const u8 = request.netns orelse "/proc/self/ns/net";

        const env_map = try self.envMap(tentative_allocator, .ADD, request, netns);

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

    fn teardown(self: *Attachment, io: std.Io, tentative_allocator: Allocator, request: plugin.Request, responser: *Responser) !void {
        _ = responser;
        // Response is sent by Handler.handle() after this returns.
        const netns: []const u8 = request.netns orelse "/proc/self/ns/net";

        const env_map = try self.envMap(tentative_allocator, .DEL, request, netns);

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

    test "setPrevResult + stringify produces JSON with embedded prevResult object" {
        const allocator = std.testing.allocator;
        const io = std.testing.io;

        // Create a PluginConf with basic config
        var arena = try ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var conf = try json.ObjectMap.init(a, &.{}, &.{});
        try conf.put(a, "cniVersion", json.Value{ .string = "1.0.0" });
        try conf.put(a, "name", json.Value{ .string = "test" });
        try conf.put(a, "type", json.Value{ .string = "macvlan" });

        var plugin_conf = PluginConf{
            .arena = arena,
            .conf = conf,
        };

        // Set prevResult from a CNI result JSON string
        const result_json =
            \\{"cniVersion":"1.0.0","interfaces":[{"name":"eth0","mac":"aa:bb:cc:dd:ee:ff"}],"ips":[{"version":"4","address":"10.0.0.5/24","interface":0}]}
        ;
        try plugin_conf.setPrevResult(result_json);

        // Stringify to pipe and verify prevResult appears as a JSON object
        var fds: [2]i32 = undefined;
        const rc = std.os.linux.pipe(&fds);
        try std.testing.expect(rc == 0);
        var in_file = std.Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } };
        defer in_file.close(io);
        var out_file = std.Io.File{ .handle = fds[1], .flags = .{ .nonblocking = false } };

        try plugin_conf.stringify(io, out_file);
        out_file.close(io);

        const buf = blk: {
            var read_buffer: [8192]u8 = undefined;
            var file_reader = in_file.reader(io, &read_buffer);
            break :blk try file_reader.interface.allocRemaining(allocator, .limited(8192));
        };
        defer allocator.free(buf);

        // Verify the output contains prevResult key
        try std.testing.expect(std.mem.indexOf(u8, buf, "\"prevResult\"") != null);
        // Verify prevResult value is a proper JSON object (not an escaped string)
        // If escaped, we'd see: "{\\\"cniVersion\\\":\\\"1.0.0\\\"...}"
        // As a proper object, we see nested interfaces and ips
        try std.testing.expect(std.mem.indexOf(u8, buf, "\"interfaces\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, buf, "\"eth0\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, buf, "10.0.0.5") != null);
    }
};

test {
    _ = CniConfig;
    _ = Attachment;
    _ = PluginConf;
}

// -- Tests for patchAddresses --

test "patchAddresses injects address with subnet prefix" {
    const allocator = std.testing.allocator;
    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Build ipam with template address + routes
    var addr_obj = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try addr_obj.put(arena_alloc, "address", .{ .string = "192.168.1.0/24" });
    try addr_obj.put(arena_alloc, "gateway", .{ .string = "192.168.1.1" });

    var addrs = try json.Array.initCapacity(arena_alloc, 1);
    addrs.appendAssumeCapacity(.{ .object = addr_obj });

    var route_obj = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try route_obj.put(arena_alloc, "dst", .{ .string = "0.0.0.0/0" });
    var routes = try json.Array.initCapacity(arena_alloc, 1);
    routes.appendAssumeCapacity(.{ .object = route_obj });

    var ipam_obj = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try ipam_obj.put(arena_alloc, "type", .{ .string = "static" });
    try ipam_obj.put(arena_alloc, "addresses", .{ .array = addrs });
    try ipam_obj.put(arena_alloc, "routes", .{ .array = routes });

    var conf = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try conf.put(arena_alloc, "type", .{ .string = "macvlan" });
    try conf.put(arena_alloc, "name", .{ .string = "test" });
    try conf.put(arena_alloc, "cniVersion", .{ .string = "1.0.0" });
    try conf.put(arena_alloc, "ipam", .{ .object = ipam_obj });

    var plugin_conf = PluginConf{ .arena = arena, .conf = conf };

    const ips = &[_][]const u8{"192.168.1.15"};
    try plugin_conf.patchAddresses(ips);

    // Verify addresses were patched
    const result_ipam = plugin_conf.conf.get("ipam").?.object;
    const addresses = result_ipam.get("addresses").?.array;
    try std.testing.expectEqual(@as(usize, 1), addresses.items.len);

    const result_addr = addresses.items[0].object;
    try std.testing.expectEqualSlices(u8, "192.168.1.15/24", result_addr.get("address").?.string);
    try std.testing.expectEqualSlices(u8, "192.168.1.1", result_addr.get("gateway").?.string);

    // Verify routes were preserved by shadowCopy
    const result_routes = result_ipam.get("routes").?.array;
    try std.testing.expectEqual(@as(usize, 1), result_routes.items.len);
    try std.testing.expectEqualSlices(u8, "0.0.0.0/0", result_routes.items[0].object.get("dst").?.string);
}

test "patchAddresses with no gateway omits gateway field" {
    const allocator = std.testing.allocator;
    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var addr_obj = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try addr_obj.put(arena_alloc, "address", .{ .string = "10.0.0.0/8" });

    var addrs = try json.Array.initCapacity(arena_alloc, 1);
    addrs.appendAssumeCapacity(.{ .object = addr_obj });

    var ipam_obj = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try ipam_obj.put(arena_alloc, "type", .{ .string = "static" });
    try ipam_obj.put(arena_alloc, "addresses", .{ .array = addrs });

    var conf = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try conf.put(arena_alloc, "type", .{ .string = "macvlan" });
    try conf.put(arena_alloc, "name", .{ .string = "test" });
    try conf.put(arena_alloc, "cniVersion", .{ .string = "1.0.0" });
    try conf.put(arena_alloc, "ipam", .{ .object = ipam_obj });

    var plugin_conf = PluginConf{ .arena = arena, .conf = conf };

    const ips = &[_][]const u8{"10.0.0.5"};
    try plugin_conf.patchAddresses(ips);

    const result_ipam = plugin_conf.conf.get("ipam").?.object;
    const result_addr = result_ipam.get("addresses").?.array.items[0].object;
    try std.testing.expectEqualSlices(u8, "10.0.0.5/8", result_addr.get("address").?.string);
    try std.testing.expect(result_addr.get("gateway") == null);

    // No routes configured — routes key should not exist
    try std.testing.expect(result_ipam.get("routes") == null);
}

test "patchAddresses preserves multiple routes via shadowCopy" {
    const allocator = std.testing.allocator;
    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var addr_obj = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try addr_obj.put(arena_alloc, "address", .{ .string = "192.168.1.0/24" });
    try addr_obj.put(arena_alloc, "gateway", .{ .string = "192.168.1.1" });
    var addrs = try json.Array.initCapacity(arena_alloc, 1);
    addrs.appendAssumeCapacity(.{ .object = addr_obj });

    var route1 = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try route1.put(arena_alloc, "dst", .{ .string = "0.0.0.0/0" });
    var route2 = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try route2.put(arena_alloc, "dst", .{ .string = "10.0.0.0/8" });
    var routes = try json.Array.initCapacity(arena_alloc, 2);
    routes.appendAssumeCapacity(.{ .object = route1 });
    routes.appendAssumeCapacity(.{ .object = route2 });

    var ipam_obj = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try ipam_obj.put(arena_alloc, "type", .{ .string = "static" });
    try ipam_obj.put(arena_alloc, "addresses", .{ .array = addrs });
    try ipam_obj.put(arena_alloc, "routes", .{ .array = routes });

    var conf = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try conf.put(arena_alloc, "type", .{ .string = "macvlan" });
    try conf.put(arena_alloc, "name", .{ .string = "test" });
    try conf.put(arena_alloc, "cniVersion", .{ .string = "1.0.0" });
    try conf.put(arena_alloc, "ipam", .{ .object = ipam_obj });

    var plugin_conf = PluginConf{ .arena = arena, .conf = conf };

    const ips = &[_][]const u8{"192.168.1.50"};
    try plugin_conf.patchAddresses(ips);

    const result_ipam = plugin_conf.conf.get("ipam").?.object;
    const result_routes = result_ipam.get("routes").?.array;
    try std.testing.expectEqual(@as(usize, 2), result_routes.items.len);
    try std.testing.expectEqualSlices(u8, "0.0.0.0/0", result_routes.items[0].object.get("dst").?.string);
    try std.testing.expectEqualSlices(u8, "10.0.0.0/8", result_routes.items[1].object.get("dst").?.string);
}

test "patchAddresses with empty template addresses does nothing" {
    const allocator = std.testing.allocator;
    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var ipam_obj = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try ipam_obj.put(arena_alloc, "type", .{ .string = "static" });
    // No addresses key

    var conf = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try conf.put(arena_alloc, "type", .{ .string = "macvlan" });
    try conf.put(arena_alloc, "name", .{ .string = "test" });
    try conf.put(arena_alloc, "cniVersion", .{ .string = "1.0.0" });
    try conf.put(arena_alloc, "ipam", .{ .object = ipam_obj });

    var plugin_conf = PluginConf{ .arena = arena, .conf = conf };

    const ips = &[_][]const u8{"192.168.1.50"};
    // No matching subnet — no addresses injected, no crash
    try plugin_conf.patchAddresses(ips);

    const result_ipam = plugin_conf.conf.get("ipam").?.object;
    // addresses should not exist (no template, no match)
    try std.testing.expect(result_ipam.get("addresses") == null);
}

test "patchAddresses with dual-stack IPv4 and IPv6" {
    const allocator = std.testing.allocator;
    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var addr4 = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try addr4.put(arena_alloc, "address", .{ .string = "192.168.1.0/24" });
    try addr4.put(arena_alloc, "gateway", .{ .string = "192.168.1.1" });

    var addr6 = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try addr6.put(arena_alloc, "address", .{ .string = "2001:db8::/64" });
    try addr6.put(arena_alloc, "gateway", .{ .string = "2001:db8::1" });

    var addrs = try json.Array.initCapacity(arena_alloc, 2);
    addrs.appendAssumeCapacity(.{ .object = addr4 });
    addrs.appendAssumeCapacity(.{ .object = addr6 });

    var route1 = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try route1.put(arena_alloc, "dst", .{ .string = "0.0.0.0/0" });
    var route2 = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try route2.put(arena_alloc, "dst", .{ .string = "::/0" });
    var routes = try json.Array.initCapacity(arena_alloc, 2);
    routes.appendAssumeCapacity(.{ .object = route1 });
    routes.appendAssumeCapacity(.{ .object = route2 });

    var ipam_obj = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try ipam_obj.put(arena_alloc, "type", .{ .string = "static" });
    try ipam_obj.put(arena_alloc, "addresses", .{ .array = addrs });
    try ipam_obj.put(arena_alloc, "routes", .{ .array = routes });

    var conf = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try conf.put(arena_alloc, "type", .{ .string = "macvlan" });
    try conf.put(arena_alloc, "name", .{ .string = "test" });
    try conf.put(arena_alloc, "cniVersion", .{ .string = "1.0.0" });
    try conf.put(arena_alloc, "ipam", .{ .object = ipam_obj });

    var plugin_conf = PluginConf{ .arena = arena, .conf = conf };

    const ips = &[_][]const u8{ "192.168.1.15", "2001:db8::10" };
    try plugin_conf.patchAddresses(ips);

    const result_ipam = plugin_conf.conf.get("ipam").?.object;
    const addresses = result_ipam.get("addresses").?.array;
    try std.testing.expectEqual(@as(usize, 2), addresses.items.len);

    // IPv4 address
    try std.testing.expectEqualSlices(u8, "192.168.1.15/24", addresses.items[0].object.get("address").?.string);
    try std.testing.expectEqualSlices(u8, "192.168.1.1", addresses.items[0].object.get("gateway").?.string);

    // IPv6 address
    try std.testing.expectEqualSlices(u8, "2001:db8::10/64", addresses.items[1].object.get("address").?.string);
    try std.testing.expectEqualSlices(u8, "2001:db8::1", addresses.items[1].object.get("gateway").?.string);

    // Routes preserved
    const result_routes = result_ipam.get("routes").?.array;
    try std.testing.expectEqual(@as(usize, 2), result_routes.items.len);
    try std.testing.expectEqualSlices(u8, "0.0.0.0/0", result_routes.items[0].object.get("dst").?.string);
    try std.testing.expectEqualSlices(u8, "::/0", result_routes.items[1].object.get("dst").?.string);
}

test "patchAddresses skips IP with no matching subnet family" {
    const allocator = std.testing.allocator;
    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Only IPv4 subnet configured
    var addr4 = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try addr4.put(arena_alloc, "address", .{ .string = "192.168.1.0/24" });
    try addr4.put(arena_alloc, "gateway", .{ .string = "192.168.1.1" });
    var addrs = try json.Array.initCapacity(arena_alloc, 1);
    addrs.appendAssumeCapacity(.{ .object = addr4 });

    var ipam_obj = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try ipam_obj.put(arena_alloc, "type", .{ .string = "static" });
    try ipam_obj.put(arena_alloc, "addresses", .{ .array = addrs });

    var conf = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try conf.put(arena_alloc, "type", .{ .string = "macvlan" });
    try conf.put(arena_alloc, "name", .{ .string = "test" });
    try conf.put(arena_alloc, "cniVersion", .{ .string = "1.0.0" });
    try conf.put(arena_alloc, "ipam", .{ .object = ipam_obj });

    var plugin_conf = PluginConf{ .arena = arena, .conf = conf };

    // Request both IPv4 and IPv6, but only IPv4 has a matching subnet
    const ips = &[_][]const u8{ "192.168.1.15", "2001:db8::10" };
    try plugin_conf.patchAddresses(ips);

    const result_ipam = plugin_conf.conf.get("ipam").?.object;
    const addresses = result_ipam.get("addresses").?.array;
    // Only IPv4 address should be injected
    try std.testing.expectEqual(@as(usize, 1), addresses.items.len);
    try std.testing.expectEqualSlices(u8, "192.168.1.15/24", addresses.items[0].object.get("address").?.string);
}

test "patchAddresses with IPv6 only" {
    const allocator = std.testing.allocator;
    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var addr6 = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try addr6.put(arena_alloc, "address", .{ .string = "2001:db8::/64" });
    try addr6.put(arena_alloc, "gateway", .{ .string = "2001:db8::1" });
    var addrs = try json.Array.initCapacity(arena_alloc, 1);
    addrs.appendAssumeCapacity(.{ .object = addr6 });

    var ipam_obj = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try ipam_obj.put(arena_alloc, "type", .{ .string = "static" });
    try ipam_obj.put(arena_alloc, "addresses", .{ .array = addrs });

    var conf = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try conf.put(arena_alloc, "type", .{ .string = "macvlan" });
    try conf.put(arena_alloc, "name", .{ .string = "test" });
    try conf.put(arena_alloc, "cniVersion", .{ .string = "1.0.0" });
    try conf.put(arena_alloc, "ipam", .{ .object = ipam_obj });

    var plugin_conf = PluginConf{ .arena = arena, .conf = conf };

    const ips = &[_][]const u8{"2001:db8::42"};
    try plugin_conf.patchAddresses(ips);

    const result_ipam = plugin_conf.conf.get("ipam").?.object;
    const addresses = result_ipam.get("addresses").?.array;
    try std.testing.expectEqual(@as(usize, 1), addresses.items.len);
    try std.testing.expectEqualSlices(u8, "2001:db8::42/64", addresses.items[0].object.get("address").?.string);
    try std.testing.expectEqualSlices(u8, "2001:db8::1", addresses.items[0].object.get("gateway").?.string);
}
