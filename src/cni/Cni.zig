const std = @import("std");
const json = std.json;
const log = std.log.scoped(.cni);
const Allocator = std.mem.Allocator;
const ArenaAllocator = @import("../utils/ArenaAllocator.zig");
const config_mod = @import("../config.zig");
const plugin = @import("../plugin.zig");
const Responser = plugin.Responser;
const managed_type = @import("managed_type.zig");
const Cni = @This();

arena: ArenaAllocator,
cni_plugin_dir: []const u8,
config: CniConfig,
ipam_config: config_mod.IpamConfig,

mutex: std.Thread.Mutex = std.Thread.Mutex{},
user_sessions: UserAttachmentMap,

pub fn init(root_allocator: Allocator, resource: config_mod.Resource, cni_plugin_dir: []const u8) !*Cni {
    var arena = try ArenaAllocator.init(root_allocator);
    errdefer arena.deinit();

    const allocator = arena.allocator();

    const cni_config = try buildCniConfigFromResource(allocator, resource);
    try cni_config.validate();

    const cni = try allocator.create(Cni);
    cni.* = Cni{
        .arena = arena,
        .cni_plugin_dir = cni_plugin_dir,
        .config = cni_config,
        .ipam_config = resource.ipam,
        .user_sessions = UserAttachmentMap.init(allocator),
    };
    return cni;
}

fn buildCniConfigFromResource(allocator: Allocator, resource: config_mod.Resource) !CniConfig {
    // Build ipam object — only "type" field; addresses/routes injected at runtime
    var ipam_obj = json.ObjectMap.init(allocator);
    switch (resource.ipam) {
        .static => try ipam_obj.put("type", .{ .string = "static" }),
        .dhcp => try ipam_obj.put("type", .{ .string = "dhcp" }),
    }

    // Build plugin object
    var plugin_obj = json.ObjectMap.init(allocator);
    try plugin_obj.put("type", .{ .string = resource.interface.type });
    try plugin_obj.put("master", .{ .string = resource.interface.master });

    if (resource.interface.mode) |mode| {
        try plugin_obj.put("mode", .{ .string = mode });
    }
    if (resource.interface.mtu) |mtu| {
        try plugin_obj.put("mtu", .{ .integer = @intCast(mtu) });
    }

    try plugin_obj.put("ipam", .{ .object = ipam_obj });

    // Build plugins array
    var plugins = json.Array.initCapacity(allocator, 1) catch unreachable;
    plugins.appendAssumeCapacity(.{ .object = plugin_obj });

    return CniConfig{
        .cniVersion = "1.0.0",
        .name = resource.name,
        .plugins = .{ .array = plugins },
    };
}

pub fn deinit(self: *Cni) void {
    var session_it = self.user_sessions.iterator();
    while (session_it.next()) |entry| {
        entry.value_ptr.*.deinit();
    }
    self.user_sessions.deinit();

    const allocator = self.arena.childAllocator();
    self.arena.deinit();
    allocator.destroy(self);
}

pub fn create(self: *Cni, tentative_allocator: Allocator, request: plugin.Request, responser: *Responser) !void {
    _ = self;
    _ = tentative_allocator;
    responser.write(request.raw_request.?);
}

const CniCommand = enum {
    ADD,
    DEL,
    GET,
    VERSION,
};

fn loadAttachment(self: *Cni, session: *UserSession, request: plugin.Request) !*Attachment {
    // ensure that the mutex is already locked outside
    const exec_request = request.requestExec();
    const allocator = session.arena.allocator();
    const attachment_key = try AttachmentKey.init(
        allocator,
        exec_request.container_id,
        exec_request.network_options.interface_name,
    );

    const result = try session.attachments.getOrPut(attachment_key);
    if (!result.found_existing) {
        result.value_ptr.* = try Attachment.init(
            allocator,
            self.config,
            self.cni_plugin_dir,
            self.ipam_config,
        );
    }
    return result.value_ptr;
}

fn getOrCreateUserSession(self: *Cni, uid: std.posix.uid_t) !*UserSession {
    const result = try self.user_sessions.getOrPut(uid);
    if (!result.found_existing) {
        const session = try UserSession.init(self.arena.childAllocator());
        result.value_ptr.* = session;
    }
    return result.value_ptr.*;
}

pub fn setup(self: *Cni, tentative_allocator: Allocator, request: plugin.Request, responser: *Responser, caller_uid: std.posix.uid_t) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    const session = try self.getOrCreateUserSession(caller_uid);
    const attachment = try self.loadAttachment(session, request);
    if (attachment.isExecuted()) {
        responser.writeError("The setup has been executed, teardown first", .{});
        return;
    }

    try attachment.setup(tentative_allocator, request, responser);
}

pub fn teardown(self: *Cni, tentative_allocator: Allocator, request: plugin.Request, responser: *Responser, caller_uid: std.posix.uid_t) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    const exec_request = request.requestExec();
    const attachment_key = AttachmentKey{
        .container_id = exec_request.container_id,
        .ifname = exec_request.network_options.interface_name,
    };

    const session = self.user_sessions.get(caller_uid) orelse {
        log.warn(
            "No session found for uid={d}, container_id={s}, skipping CNI DEL. This can happen if the server was restarted.",
            .{ caller_uid, exec_request.container_id },
        );
        log.info("Teardown {s} is complete", .{request.request.exec.container_name});
        return;
    };

    if (session.attachments.fetchRemove(attachment_key)) |kv| {
        var key = kv.key;
        var value = kv.value;
        defer {
            key.deinit();
            value.deinit();
        }

        try value.teardown(tentative_allocator, request, responser);
    } else {
        log.warn(
            "Attachment not found for uid={d}, container_id={s}, ifname={s}, skipping CNI DEL. This can happen if the server was restarted.",
            .{ caller_uid, exec_request.container_id, exec_request.network_options.interface_name },
        );
    }

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
    arena: ?ArenaAllocator = null,
    result: ?std.ArrayList(u8) = null,

    const ValidateError = error{
        PluginTypeMissing,
        PluginTypeNotString,
        PluginTypeUnsupported,
    };

    pub fn init(root_allocator: Allocator, cni_config: CniConfig, obj: json.ObjectMap) !PluginConf {
        var arena = try ArenaAllocator.init(root_allocator);

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
        self.conf.deinit();

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

        const path = try std.fmt.allocPrint(
            allocator,
            "/run/user/{d}/net-porter-dhcp.sock",
            .{uid},
        );

        // Build a fresh ipam ObjectMap to avoid mutating the shared original
        var new_ipam = json.ObjectMap.init(allocator);
        try new_ipam.put("type", .{ .string = type_str });
        try new_ipam.put("daemonSocketPath", .{ .string = path });

        try self.conf.put("ipam", .{ .object = new_ipam });
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

    fn setStaticIp(self: *PluginConf, ip: []const u8, ipam_config: config_mod.IpamConfig) !void {
        const allocator = self.arena.?.allocator();

        // Only applicable to static IPAM
        const static_conf = switch (ipam_config) {
            .static => |s| s,
            .dhcp => return,
        };

        // Read original ipam type (read-only, shared)
        const ipam = self.conf.get("ipam") orelse return;
        const ipam_obj = switch (ipam) {
            .object => |obj| obj,
            else => return,
        };
        const ipam_type = ipam_obj.get("type") orelse return;
        const type_str = switch (ipam_type) {
            .string => |s| s,
            else => return,
        };

        // Extract prefix length from subnet (e.g., "192.168.1.0/24" -> "24")
        // Uses first address entry as the subnet template
        if (static_conf.addresses.len == 0) return error.InvalidSubnet;
        const subnet = static_conf.addresses[0].address;
        const slash_pos = std.mem.lastIndexOf(u8, subnet, "/") orelse return error.InvalidSubnet;
        const prefix = subnet[slash_pos + 1 ..];

        // Build address string with prefix (replace subnet with actual IP)
        const address = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ip, prefix });

        // Build address object
        var addr_obj = json.ObjectMap.init(allocator);
        try addr_obj.put("address", .{ .string = address });
        if (static_conf.addresses[0].gateway) |gw| {
            try addr_obj.put("gateway", .{ .string = gw });
        }

        // Build a fresh ipam ObjectMap to avoid mutating the shared original
        var new_ipam = json.ObjectMap.init(allocator);
        try new_ipam.put("type", .{ .string = type_str });

        // Set addresses
        var addresses = json.Array.initCapacity(allocator, 1) catch unreachable;
        addresses.appendAssumeCapacity(.{ .object = addr_obj });
        try new_ipam.put("addresses", .{ .array = addresses });

        // Set routes if present
        if (static_conf.routes) |rts| {
            var routes_arr = json.Array.initCapacity(allocator, rts.len) catch unreachable;
            for (rts) |r| {
                var route_obj = json.ObjectMap.init(allocator);
                try route_obj.put("dst", .{ .string = r.dst });
                if (r.gw) |gw| {
                    try route_obj.put("gw", .{ .string = gw });
                }
                if (r.priority) |p| {
                    try route_obj.put("priority", .{ .integer = @as(i64, @intCast(p)) });
                }
                routes_arr.appendAssumeCapacity(.{ .object = route_obj });
            }
            try new_ipam.put("routes", .{ .array = routes_arr });
        }

        // Set dns if present
        if (static_conf.dns) |dns_conf| {
            var dns_obj = json.ObjectMap.init(allocator);
            if (dns_conf.nameservers) |ns| {
                var ns_arr = json.Array.initCapacity(allocator, ns.len) catch unreachable;
                for (ns) |n| {
                    ns_arr.appendAssumeCapacity(.{ .string = n });
                }
                try dns_obj.put("nameservers", .{ .array = ns_arr });
            }
            if (dns_conf.domain) |d| {
                try dns_obj.put("domain", .{ .string = d });
            }
            if (dns_conf.search) |s| {
                var s_arr = json.Array.initCapacity(allocator, s.len) catch unreachable;
                for (s) |item| {
                    s_arr.appendAssumeCapacity(.{ .string = item });
                }
                try dns_obj.put("search", .{ .array = s_arr });
            }
            if (dns_conf.options) |o| {
                var o_arr = json.Array.initCapacity(allocator, o.len) catch unreachable;
                for (o) |item| {
                    o_arr.appendAssumeCapacity(.{ .string = item });
                }
                try dns_obj.put("options", .{ .array = o_arr });
            }
            try new_ipam.put("dns", .{ .object = dns_obj });
        }

        try self.conf.put("ipam", .{ .object = new_ipam });
    }

    test "isDhcp() will return false if the ipam type is not dhcp" {
        const root_allocator = std.testing.allocator;
        var arena = try ArenaAllocator.init(root_allocator);
        const allocator = arena.allocator();
        defer arena.deinit();

        // No ipam field
        var plugin_conf = PluginConf{ .conf = json.ObjectMap.init(allocator) };
        try std.testing.expect(!plugin_conf.isDhcp());

        // Ipam field is not object type
        try plugin_conf.conf.put("ipam", json.Value{ .bool = true });
        try std.testing.expect(!plugin_conf.isDhcp());

        // Have ipam field but no type field
        try plugin_conf.conf.put("ipam", json.Value{ .object = json.ObjectMap.init(allocator) });
        try std.testing.expect(!plugin_conf.isDhcp());

        // Ipam type field is not string type
        try plugin_conf.conf.getPtr("ipam").?.object.put("type", json.Value{ .bool = true });
        try std.testing.expect(!plugin_conf.isDhcp());

        // Ipam type field is not 'dhcp'
        try plugin_conf.conf.getPtr("ipam").?.object.put("type", json.Value{ .string = "static" });
        try std.testing.expect(!plugin_conf.isDhcp());
    }

    test "isDhcp() will return true if the type is dhcp" {
        const root_allocator = std.testing.allocator;
        var arena = try ArenaAllocator.init(root_allocator);
        const allocator = arena.allocator();
        defer arena.deinit();

        var plugin_conf = PluginConf{ .conf = json.ObjectMap.init(allocator) };
        try plugin_conf.conf.put("ipam", json.Value{ .object = json.ObjectMap.init(allocator) });
        try plugin_conf.conf.getPtr("ipam").?.object.put("type", json.Value{ .string = "dhcp" });

        try std.testing.expect(plugin_conf.isDhcp());
    }

    test "isStatic() will return true if the type is static" {
        const root_allocator = std.testing.allocator;
        var arena = try ArenaAllocator.init(root_allocator);
        const allocator = arena.allocator();
        defer arena.deinit();

        var plugin_conf = PluginConf{ .conf = json.ObjectMap.init(allocator) };
        try plugin_conf.conf.put("ipam", json.Value{ .object = json.ObjectMap.init(allocator) });
        try plugin_conf.conf.getPtr("ipam").?.object.put("type", json.Value{ .string = "static" });

        try std.testing.expect(plugin_conf.isStatic());
    }

    test "isStatic() will return false if the type is dhcp" {
        const root_allocator = std.testing.allocator;
        var arena = try ArenaAllocator.init(root_allocator);
        const allocator = arena.allocator();
        defer arena.deinit();

        var plugin_conf = PluginConf{ .conf = json.ObjectMap.init(allocator) };
        try plugin_conf.conf.put("ipam", json.Value{ .object = json.ObjectMap.init(allocator) });
        try plugin_conf.conf.getPtr("ipam").?.object.put("type", json.Value{ .string = "dhcp" });

        try std.testing.expect(!plugin_conf.isStatic());
    }

    fn stringify(self: PluginConf, stream: std.fs.File) !void {
        var write_buffer: [4096]u8 = undefined;
        var file_writer = stream.writer(&write_buffer);
        try json.Stringify.value(
            json.Value{ .object = self.conf },
            .{ .whitespace = .indent_2 },
            &file_writer.interface,
        );
        try file_writer.end();
    }

    test "stringify() will success" {
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

        const fds = try std.posix.pipe();
        var in = std.fs.File{ .handle = fds[0] };
        defer in.close();

        var out = std.fs.File{ .handle = fds[1] };
        try exec_config.stringify(out);
        out.close();

        const buf = blk: {
            var read_buffer: [1024]u8 = undefined;
            var file_reader = in.reader(&read_buffer);
            break :blk try file_reader.interface.allocRemaining(allocator, .limited(1024));
        };
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

    fn isExecuted(self: PluginConf) bool {
        return self.result != null;
    }

    fn exec(self: *PluginConf, tentative_allocator: Allocator, cmd: []const u8, pid: []const u8, env_map: std.process.EnvMap) !std.process.Child.Term {
        const allocator = self.arena.?.allocator();

        var process = std.process.Child.init(
            &[_][]const u8{ "nsenter", "-t", pid, "--mount", cmd },
            tentative_allocator,
        );
        process.stdin_behavior = .Pipe;
        process.stdout_behavior = .Pipe;
        process.stderr_behavior = .Pipe;
        process.env_map = &env_map;

        var stdout = std.ArrayListUnmanaged(u8){};
        var stderr = std.ArrayListUnmanaged(u8){};
        defer stderr.deinit(allocator);

        try process.spawn();

        try self.stringify(process.stdin.?);
        process.stdin.?.close();
        process.stdin = null;

        try process.collectOutput(allocator, &stdout, &stderr, 4096);
        const result = try process.wait();

        self.result = std.ArrayList(u8).fromOwnedSlice(try stdout.toOwnedSlice(allocator));
        return result;
    }
};

const AttachmentKey = struct {
    container_id: []const u8,
    ifname: []const u8,
    allocator: ?Allocator = null,

    pub fn init(allocator: Allocator, container_id: []const u8, ifname: []const u8) !AttachmentKey {
        return AttachmentKey{
            .container_id = try allocator.dupe(u8, container_id),
            .ifname = try allocator.dupe(u8, ifname),
            .allocator = allocator,
        };
    }

    pub fn copy(self: AttachmentKey, allocator: Allocator) !AttachmentKey {
        return try AttachmentKey.init(allocator, self.container_id, self.ifname);
    }

    pub fn deinit(self: AttachmentKey) void {
        if (self.allocator) |alloc| {
            alloc.free(self.container_id);
            alloc.free(self.ifname);
        }
    }

    test "copy() will success" {
        const allocator = std.testing.allocator;
        const key = AttachmentKey{
            .container_id = "test",
            .ifname = "eth0",
        };
        const copied_key = try key.copy(allocator);
        defer copied_key.deinit();
        try std.testing.expectEqualSlices(u8, "test", copied_key.container_id);
        try std.testing.expectEqualSlices(u8, "eth0", copied_key.ifname);
    }
};

const AttachmentKeyContext = struct {
    pub fn hash(self: AttachmentKeyContext, key: AttachmentKey) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHashStrat(&hasher, key.container_id, .Deep);
        std.hash.autoHashStrat(&hasher, key.ifname, .Deep);
        return hasher.final();
    }

    test "the copy key have the same hash" {
        const context = AttachmentKeyContext{};
        const key = AttachmentKey{
            .container_id = "test",
            .ifname = "eth0",
        };
        const copied_key = try key.copy(std.testing.allocator);
        defer copied_key.deinit();
        try std.testing.expectEqual(context.hash(key), context.hash(copied_key));
    }

    pub fn eql(self: AttachmentKeyContext, one: AttachmentKey, other: AttachmentKey) bool {
        _ = self;
        return std.mem.eql(u8, one.container_id, other.container_id) and
            std.mem.eql(u8, one.ifname, other.ifname);
    }

    test "the copy key is equal to the original key" {
        const context = AttachmentKeyContext{};
        const key = AttachmentKey{
            .container_id = "test",
            .ifname = "eth0",
        };
        const copied_key = try key.copy(std.testing.allocator);
        defer copied_key.deinit();
        try std.testing.expect(context.eql(key, copied_key));
    }
};

const AttachmentMap = std.HashMap(
    AttachmentKey,
    Attachment,
    AttachmentKeyContext,
    80,
);

const UserSession = struct {
    arena: ArenaAllocator,
    attachments: AttachmentMap,

    pub fn init(root_allocator: Allocator) !*UserSession {
        var arena = try ArenaAllocator.init(root_allocator);
        const allocator = arena.allocator();
        const session = try allocator.create(UserSession);
        session.* = .{
            .arena = arena,
            .attachments = AttachmentMap.init(allocator),
        };
        return session;
    }

    pub fn deinit(self: *UserSession) void {
        var it = self.attachments.iterator();
        while (it.next()) |entry| {
            entry.key_ptr.*.deinit();
            entry.value_ptr.*.deinit();
        }
        self.attachments.deinit();
        const allocator = self.arena.childAllocator();
        self.arena.deinit();
        allocator.destroy(self);
    }
};

const UserAttachmentMap = std.AutoHashMap(u32, *UserSession);

const Attachment = struct {
    arena: ArenaAllocator,
    exec_configs: std.ArrayList(PluginConf),
    cni_plugin_dir: []const u8,
    ipam_config: config_mod.IpamConfig,

    pub fn init(root_allocator: Allocator, cni_config: CniConfig, cni_plugin_dir: []const u8, ipam_config: config_mod.IpamConfig) !Attachment {
        const arena = try ArenaAllocator.init(root_allocator);

        var attachment = Attachment{
            .arena = arena,
            .exec_configs = std.ArrayList(PluginConf).empty,
            .cni_plugin_dir = cni_plugin_dir,
            .ipam_config = ipam_config,
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

        const ipam: config_mod.IpamConfig = .{ .dhcp = .{} };
        var attachment = try Attachment.init(allocator, cni_config, "", ipam);
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

    fn isExecuted(self: Attachment) bool {
        return self.exec_configs.items[0].isExecuted();
    }

    fn setup(self: *Attachment, tentative_allocator: Allocator, request: plugin.Request, responser: *Responser) !void {
        const env_map = try self.envMap(tentative_allocator, .ADD, request);
        const pid = try std.fmt.allocPrint(tentative_allocator, "{d}", .{request.process_id.?});

        for (self.exec_configs.items) |*exec_config| {
            if (exec_config.isDhcp()) {
                try exec_config.setDhcpSocketPath(request.user_id.?);
            } else if (exec_config.isStatic()) {
                const exec_request = request.requestExec();
                if (exec_request.network_options.static_ips) |static_ips| {
                    if (static_ips.len > 0) {
                        try exec_config.setStaticIp(static_ips[0], self.ipam_config);
                    }
                }
            }
            const cmd = try self.cni_plugin_binary(tentative_allocator, exec_config.getType());
            const result = try exec_config.exec(tentative_allocator, cmd, pid, env_map);
            if (result.Exited != 0) {
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

    fn teardown(self: *Attachment, tentative_allocator: Allocator, request: plugin.Request, responser: *Responser) !void {
        _ = responser;
        const env_map = try self.envMap(tentative_allocator, .DEL, request);
        const pid = try std.fmt.allocPrint(tentative_allocator, "{d}", .{request.process_id.?});

        var i: usize = 0;
        const len = self.exec_configs.items.len;
        while (i < len) : (i += 1) {
            var exec_config = &self.exec_configs.items[len - (i + 1)];
            const cmd = try self.cni_plugin_binary(tentative_allocator, exec_config.getType());
            const result = try exec_config.exec(tentative_allocator, cmd, pid, env_map);

            if (result.Exited != 0) {
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

    fn envMap(self: Attachment, allocator: Allocator, cni_command: CniCommand, request: plugin.Request) !std.process.EnvMap {
        const exec_request = request.requestExec();

        var env_map = std.process.EnvMap.init(allocator);
        try env_map.put("CNI_COMMAND", @tagName(cni_command));
        try env_map.put("CNI_CONTAINERID", exec_request.container_id);
        try env_map.put("CNI_NETNS", request.netns.?);
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
            .ipam_config = .{ .dhcp = .{} },
        };
        defer attachment.deinit();
        const bin = try attachment.cni_plugin_binary(allocator, "macvlan");
        defer allocator.free(bin);
        try std.testing.expectEqualSlices(u8, "/path/to/cni/plugins/macvlan", bin);
    }
};

test {
    _ = CniConfig;
    _ = AttachmentKey;
    _ = AttachmentKeyContext;
    _ = Attachment;
    _ = PluginConf;
}

// -- Tests for buildCniConfigFromResource --

test "buildCniConfigFromResource creates correct CNI config for DHCP resource" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const resource = config_mod.Resource{
        .name = "test-dhcp",
        .interface = .{ .type = "macvlan", .master = "eth0" },
        .ipam = .{ .dhcp = .{} },
        .acl = &[_]config_mod.Resource.Grant{
            .{ .user = "1000" },
        },
    };

    const cni_config = try buildCniConfigFromResource(allocator, resource);

    try std.testing.expectEqualSlices(u8, "1.0.0", cni_config.cniVersion);
    try std.testing.expectEqualSlices(u8, "test-dhcp", cni_config.name);

    // Verify plugins structure
    const plugins = cni_config.plugins.array;
    try std.testing.expectEqual(@as(usize, 1), plugins.items.len);

    const plugin_val = plugins.items[0];
    const plugin_obj = plugin_val.object;

    try std.testing.expectEqualSlices(u8, "macvlan", plugin_obj.get("type").?.string);
    try std.testing.expectEqualSlices(u8, "eth0", plugin_obj.get("master").?.string);

    // Verify ipam
    const ipam = plugin_obj.get("ipam").?.object;
    try std.testing.expectEqualSlices(u8, "dhcp", ipam.get("type").?.string);

    // mode should not be present (was null)
    try std.testing.expect(plugin_obj.get("mode") == null);
    // mtu should not be present (was null)
    try std.testing.expect(plugin_obj.get("mtu") == null);
}

test "buildCniConfigFromResource creates correct CNI config with mode and mtu" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const resource = config_mod.Resource{
        .name = "test-mode",
        .interface = .{ .type = "macvlan", .master = "bond0", .mode = "bridge", .mtu = 9000 },
        .ipam = .{ .static = .{
            .addresses = &[_]config_mod.Resource.Address{
                .{ .address = "10.0.0.0/16" },
            },
        } },
        .acl = &[_]config_mod.Resource.Grant{
            .{ .user = "1000", .ips = &[_][:0]const u8{"10.0.0.5-10.0.0.10"} },
        },
    };

    const cni_config = try buildCniConfigFromResource(allocator, resource);
    const plugin_obj = cni_config.plugins.array.items[0].object;

    try std.testing.expectEqualSlices(u8, "bond0", plugin_obj.get("master").?.string);
    try std.testing.expectEqualSlices(u8, "bridge", plugin_obj.get("mode").?.string);
    try std.testing.expectEqual(@as(i64, 9000), plugin_obj.get("mtu").?.integer);

    // ipam should be static (no gateway/subnet at build time — injected at runtime)
    const ipam = plugin_obj.get("ipam").?.object;
    try std.testing.expectEqualSlices(u8, "static", ipam.get("type").?.string);
    try std.testing.expect(ipam.get("gateway") == null);
    try std.testing.expect(ipam.get("addresses") == null);
}

// -- Tests for setStaticIp --

test "setStaticIp injects address with subnet prefix" {
    const allocator = std.testing.allocator;
    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Build a plugin conf with static ipam
    var ipam_obj = json.ObjectMap.init(arena_alloc);
    try ipam_obj.put("type", .{ .string = "static" });

    var conf = json.ObjectMap.init(arena_alloc);
    try conf.put("type", .{ .string = "macvlan" });
    try conf.put("name", .{ .string = "test" });
    try conf.put("cniVersion", .{ .string = "1.0.0" });
    try conf.put("ipam", .{ .object = ipam_obj });

    var plugin_conf = PluginConf{ .arena = arena, .conf = conf };

    const ipam_config: config_mod.IpamConfig = .{ .static = .{
        .addresses = &[_]config_mod.Resource.Address{
            .{ .address = "192.168.1.0/24", .gateway = "192.168.1.1" },
        },
        .routes = &[_]config_mod.Resource.Route{
            .{ .dst = "0.0.0.0/0" },
        },
    } };

    try plugin_conf.setStaticIp("192.168.1.15", ipam_config);

    // Verify addresses were injected
    const result_ipam = plugin_conf.conf.get("ipam").?.object;
    const addresses = result_ipam.get("addresses").?.array;
    try std.testing.expectEqual(@as(usize, 1), addresses.items.len);

    const addr_obj = addresses.items[0].object;
    try std.testing.expectEqualSlices(u8, "192.168.1.15/24", addr_obj.get("address").?.string);
    try std.testing.expectEqualSlices(u8, "192.168.1.1", addr_obj.get("gateway").?.string);

    // Verify routes were injected
    const routes = result_ipam.get("routes").?.array;
    try std.testing.expectEqual(@as(usize, 1), routes.items.len);
    try std.testing.expectEqualSlices(u8, "0.0.0.0/0", routes.items[0].object.get("dst").?.string);
}

test "setStaticIp with no gateway omits gateway field" {
    const allocator = std.testing.allocator;
    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var ipam_obj = json.ObjectMap.init(arena_alloc);
    try ipam_obj.put("type", .{ .string = "static" });

    var conf = json.ObjectMap.init(arena_alloc);
    try conf.put("type", .{ .string = "macvlan" });
    try conf.put("name", .{ .string = "test" });
    try conf.put("cniVersion", .{ .string = "1.0.0" });
    try conf.put("ipam", .{ .object = ipam_obj });

    var plugin_conf = PluginConf{ .arena = arena, .conf = conf };

    const ipam_config: config_mod.IpamConfig = .{ .static = .{
        .addresses = &[_]config_mod.Resource.Address{
            .{ .address = "10.0.0.0/8" },
        },
    } };

    try plugin_conf.setStaticIp("10.0.0.5", ipam_config);

    const result_ipam = plugin_conf.conf.get("ipam").?.object;
    const addr_obj = result_ipam.get("addresses").?.array.items[0].object;
    try std.testing.expectEqualSlices(u8, "10.0.0.5/8", addr_obj.get("address").?.string);
    try std.testing.expect(addr_obj.get("gateway") == null);

    // No routes configured — routes key should not exist
    try std.testing.expect(result_ipam.get("routes") == null);
}

test "setStaticIp with multiple routes injects all" {
    const allocator = std.testing.allocator;
    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var ipam_obj = json.ObjectMap.init(arena_alloc);
    try ipam_obj.put("type", .{ .string = "static" });

    var conf = json.ObjectMap.init(arena_alloc);
    try conf.put("type", .{ .string = "macvlan" });
    try conf.put("name", .{ .string = "test" });
    try conf.put("cniVersion", .{ .string = "1.0.0" });
    try conf.put("ipam", .{ .object = ipam_obj });

    var plugin_conf = PluginConf{ .arena = arena, .conf = conf };

    const ipam_config: config_mod.IpamConfig = .{ .static = .{
        .addresses = &[_]config_mod.Resource.Address{
            .{ .address = "192.168.1.0/24", .gateway = "192.168.1.1" },
        },
        .routes = &[_]config_mod.Resource.Route{
            .{ .dst = "0.0.0.0/0" },
            .{ .dst = "10.0.0.0/8" },
        },
    } };

    try plugin_conf.setStaticIp("192.168.1.50", ipam_config);

    const result_ipam = plugin_conf.conf.get("ipam").?.object;
    const routes = result_ipam.get("routes").?.array;
    try std.testing.expectEqual(@as(usize, 2), routes.items.len);
    try std.testing.expectEqualSlices(u8, "0.0.0.0/0", routes.items[0].object.get("dst").?.string);
    try std.testing.expectEqualSlices(u8, "10.0.0.0/8", routes.items[1].object.get("dst").?.string);
}

test "setStaticIp returns error when subnet is null" {
    const allocator = std.testing.allocator;
    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var ipam_obj = json.ObjectMap.init(arena_alloc);
    try ipam_obj.put("type", .{ .string = "static" });

    var conf = json.ObjectMap.init(arena_alloc);
    try conf.put("type", .{ .string = "macvlan" });
    try conf.put("name", .{ .string = "test" });
    try conf.put("cniVersion", .{ .string = "1.0.0" });
    try conf.put("ipam", .{ .object = ipam_obj });

    var plugin_conf = PluginConf{ .arena = arena, .conf = conf };

    const ipam_config: config_mod.IpamConfig = .{ .static = .{
        .addresses = &[_]config_mod.Resource.Address{},
    } };

    try std.testing.expectError(error.InvalidSubnet, plugin_conf.setStaticIp("192.168.1.50", ipam_config));
}

test "setStaticIp returns error when subnet has no slash" {
    const allocator = std.testing.allocator;
    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var ipam_obj = json.ObjectMap.init(arena_alloc);
    try ipam_obj.put("type", .{ .string = "static" });

    var conf = json.ObjectMap.init(arena_alloc);
    try conf.put("type", .{ .string = "macvlan" });
    try conf.put("name", .{ .string = "test" });
    try conf.put("cniVersion", .{ .string = "1.0.0" });
    try conf.put("ipam", .{ .object = ipam_obj });

    var plugin_conf = PluginConf{ .arena = arena, .conf = conf };

    const ipam_config: config_mod.IpamConfig = .{
        .static = .{
            .addresses = &[_]config_mod.Resource.Address{
                .{ .address = "192.168.1.0" }, // no slash
            },
        },
    };

    try std.testing.expectError(error.InvalidSubnet, plugin_conf.setStaticIp("192.168.1.50", ipam_config));
}

// -- Tests for Cni.init --

test "Cni.init creates CNI from resource config" {
    // Use ArenaAllocator as root so Cni.deinit's arena.deinit() + destroy(self) is safe:
    // arena.deinit() frees all memory; subsequent destroy() is a no-op on arena allocator.
    var root_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer root_arena.deinit();
    const allocator = root_arena.allocator();
    const resource = config_mod.Resource{
        .name = "test-cni-init",
        .interface = .{ .type = "macvlan", .master = "eth0", .mode = "bridge" },
        .ipam = .{ .dhcp = .{} },
        .acl = &[_]config_mod.Resource.Grant{
            .{ .user = "1000" },
        },
    };

    var cni = try Cni.init(allocator, resource, "/usr/lib/cni");
    defer cni.deinit();

    try std.testing.expectEqualSlices(u8, "test-cni-init", cni.config.name);
    try std.testing.expect(cni.ipam_config == .dhcp);
    try std.testing.expectEqualSlices(u8, "/usr/lib/cni", cni.cni_plugin_dir);
}

test "Cni.init with static ipam stores ipam_config" {
    var root_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer root_arena.deinit();
    const allocator = root_arena.allocator();
    const resource = config_mod.Resource{
        .name = "test-static-cni",
        .interface = .{ .type = "macvlan", .master = "eth0" },
        .ipam = .{ .static = .{
            .addresses = &[_]config_mod.Resource.Address{
                .{ .address = "192.168.1.0/24", .gateway = "192.168.1.1" },
            },
            .routes = &[_]config_mod.Resource.Route{
                .{ .dst = "0.0.0.0/0" },
            },
        } },
        .acl = &[_]config_mod.Resource.Grant{
            .{ .user = "1000", .ips = &[_][:0]const u8{"192.168.1.10-192.168.1.20"} },
        },
    };

    var cni = try Cni.init(allocator, resource, "/usr/lib/cni");
    defer cni.deinit();

    try std.testing.expect(cni.ipam_config == .static);
    const s = cni.ipam_config.static;
    try std.testing.expectEqualSlices(u8, "192.168.1.1", s.addresses[0].gateway.?);
    try std.testing.expectEqualSlices(u8, "192.168.1.0/24", s.addresses[0].address);
    try std.testing.expectEqual(@as(usize, 1), s.routes.?.len);
}
