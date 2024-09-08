const std = @import("std");
const json = std.json;
const log = std.log.scoped(.cni);
const Allocator = std.mem.Allocator;
const ArenaAllocator = @import("../ArenaAllocator.zig");
const plugin = @import("../plugin.zig");
const Responser = @import("Responser.zig");
const DhcpService = @import("DhcpService.zig");
const managed_type = @import("../managed_type.zig");
const Cni = @This();

const max_cni_config_size = 16 * 1024;

arena: ArenaAllocator,
cni_plugin_dir: []const u8,
config: ?json.Parsed(CniConfig) = null,

mutex: std.Thread.Mutex = std.Thread.Mutex{},
attachments: AttachmentMap,

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
        .attachments = AttachmentMap.init(allocator),
    };
    return cni;
}

pub fn deinit(self: Cni) void {
    var it = self.attachments.iterator();
    while (it.next()) |entry| {
        entry.key_ptr.*.deinit();
        entry.value_ptr.*.deinit();
    }
    @constCast(&self.attachments).deinit();

    if (self.config) |parsed| {
        parsed.deinit();
    }

    const allocator = self.arena.childAllocator();
    self.arena.deinit();
    allocator.destroy(&self);
}

pub fn create(self: *Cni, tentative_allocator: Allocator, request: plugin.Request, responser: *Responser) !void {
    const dhcp_service = try DhcpService.init(
        tentative_allocator,
        request.user_id.?,
    );
    defer dhcp_service.deinit();
    _ = try dhcp_service.start(
        request.process_id.?,
        self.cni_plugin_dir,
    );

    responser.write(request.raw_request.?);
}

const CniCommand = enum {
    ADD,
    DEL,
    GET,
    VERSION,
};

fn loadAttachment(self: *Cni, request: plugin.Request) !*Attachment {
    // ensure that the mutex is already locked outside
    const exec_request = request.requestExec();
    const attachment_key = try AttachmentKey.init(
        self.attachments.allocator,
        exec_request.container_id,
        exec_request.network_options.interface_name,
    );

    const result = try self.attachments.getOrPut(attachment_key);
    if (!result.found_existing) {
        result.value_ptr.* = try Attachment.init(
            self.attachments.allocator,
            self.config.?.value,
            self.cni_plugin_dir,
        );
    }
    return result.value_ptr;
}

pub fn setup(self: *Cni, tentative_allocator: Allocator, request: plugin.Request, responser: *Responser) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    const attachment = try self.loadAttachment(request);
    if (attachment.isExecuted()) {
        responser.writeError("The setup has been executed, teardown first", .{});
        return;
    }

    try attachment.setup(tentative_allocator, request, responser);
}

pub fn teardown(self: *Cni, tentative_allocator: Allocator, request: plugin.Request, responser: *Responser) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    const exec_request = request.requestExec();
    const attachment_key = AttachmentKey{
        .container_id = exec_request.container_id,
        .ifname = exec_request.network_options.interface_name,
    };

    if (self.attachments.fetchRemove(attachment_key)) |*kv| {
        defer {
            kv.key.deinit();
            kv.value.deinit();
        }

        var attachment = kv.value;
        try attachment.teardown(tentative_allocator, request, responser);
    }
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
            var subnets = std.ArrayList(plugin.Subnet).init(allocator);
            for (self.ips) |ip| {
                if (ip.interface != index) {
                    continue;
                }
                try subnets.append(.{
                    .ipnet = ip.address,
                    .gateway = ip.gateway,
                });
            }

            try response.v.interfaces.map.put(
                allocator,
                iface.name,
                .{
                    .mac_address = iface.mac,
                    .subnets = try subnets.toOwnedSlice(),
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

fn parseExecRequest(allocator: Allocator, request: json.Value) !json.Parsed(plugin.NetworkPluginExec) {
    return try json.parseFromValue(
        plugin.NetworkPluginExec,
        allocator,
        request,
        .{ .ignore_unknown_fields = true },
    );
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

    pub fn deinit(self: PluginConf) void {
        @constCast(&self.conf).deinit();

        if (self.result) |result| {
            result.deinit();
        }

        if (self.arena) |arena| {
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
        if (self.conf.getPtr("ipam")) |ipam| {
            switch (ipam.*) {
                .object => |ipam_obj| {
                    if (ipam_obj.get("daemonSocketPath")) |_| {
                        return;
                    }

                    const path = try std.fmt.allocPrint(
                        allocator,
                        "/run/user/{d}/net-porter-dhcp.sock",
                        .{uid},
                    );

                    try ipam.object.put("daemonSocketPath", json.Value{ .string = path });
                },
                else => {},
            }
        }
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

    fn stringify(self: PluginConf, stream: std.fs.File) !void {
        // TOTO: set
        try json.stringify(
            json.Value{ .object = self.conf },
            .{ .whitespace = .indent_2 },
            stream.writer(),
        );
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

        var stdout = std.ArrayList(u8).init(allocator);
        var stderr = std.ArrayList(u8).init(allocator);
        errdefer stdout.deinit();
        defer stderr.deinit();

        try process.spawn();

        try self.stringify(process.stdin.?);
        process.stdin.?.close();
        process.stdin = null;

        try process.collectOutput(&stdout, &stderr, 4096);
        const result = try process.wait();

        self.result = stdout;
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
        return try init(allocator, self.container_id, self.ifname);
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

const Attachment = struct {
    arena: ArenaAllocator,
    exec_configs: std.ArrayList(PluginConf),
    cni_plugin_dir: []const u8,

    pub fn init(root_allocator: Allocator, cni_config: CniConfig, cni_plugin_dir: []const u8) !Attachment {
        var arena = try ArenaAllocator.init(root_allocator);

        var attachment = Attachment{
            .arena = arena,
            .exec_configs = std.ArrayList(PluginConf).init(arena.allocator()),
            .cni_plugin_dir = cni_plugin_dir,
        };
        errdefer attachment.deinit();

        try attachment.initExecConfig(cni_config);
        return attachment;
    }

    pub fn deinit(self: Attachment) void {
        for (self.exec_configs.items) |exec_config| {
            exec_config.deinit();
        }
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

        const attachment = try Attachment.init(allocator, cni_config, "");
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
                exec_config.setDhcpSocketPath(request.user_id.?);
            }
            const cmd = try self.cni_plugin_binary(tentative_allocator, exec_config.getType());
            const result = try exec_config.exec(tentative_allocator, cmd, pid, env_map);
            if (result.Exited != 0) {
                // std.time.sleep(1 * std.time.ns_per_hour);
                try responseError(tentative_allocator, responser, exec_config.result.?);
                return error.UnexpectedError;
            }
        }

        try responseResult(
            tentative_allocator,
            responser,
            self.finalResult(.last).?,
        );
    }

    fn teardown(self: *Attachment, tentative_allocator: Allocator, request: plugin.Request, responser: *Responser) !void {
        const env_map = try self.envMap(tentative_allocator, .DEL, request);
        const pid = try std.fmt.allocPrint(tentative_allocator, "{d}", .{request.process_id.?});

        var i: usize = 0;
        const len = self.exec_configs.items.len;
        while (i < len) : (i += 1) {
            var exec_config = &self.exec_configs.items[len - (i + 1)];
            const cmd = try self.cni_plugin_binary(tentative_allocator, exec_config.getType());
            const result = try exec_config.exec(tentative_allocator, cmd, pid, env_map);

            if (result.Exited != 0) {
                try responseError(tentative_allocator, responser, exec_config.result.?);
                return error.UnexpectedError;
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

        var args = std.ArrayList(u8).init(allocator);
        try args.appendSlice("IgnoreUnknown=true");
        try args.appendSlice(";K8S_POD_NAME=");
        try args.appendSlice(exec_request.container_name);
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
        const attachment = Attachment{
            .arena = try ArenaAllocator.init(allocator),
            .cni_plugin_dir = "/path/to/cni/plugins",
            .exec_configs = std.ArrayList(PluginConf).init(allocator),
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
