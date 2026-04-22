const std = @import("std");
const json = std.json;
const log = std.log.scoped(.cni);
const Allocator = std.mem.Allocator;
const ArenaAllocator = @import("../utils/ArenaAllocator.zig");
const plugin = @import("../plugin.zig");
const Responser = @import("../common/Responser.zig");
const managed_type = @import("../common/ManagedType.zig");
const StateFile = @import("StateFile.zig");

pub const CniConfig = @import("CniConfig.zig").CniConfig;
pub const PluginConf = @import("PluginConf.zig").PluginConf;

const Cni = @This();

// Types needed by Attachment.zig — declared before the circular import
pub const CniCommand = enum {
    ADD,
    DEL,
    GET,
    VERSION,
};

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

pub fn responseError(allocator: Allocator, responser: *Responser, stdout: std.ArrayList(u8)) !void {
    var parsed_error_msg = try json.parseFromSlice(
        CniErrorMsg,
        allocator,
        stdout.items,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed_error_msg.deinit();

    const error_msg = parsed_error_msg.value;
    log.warn("CNI plugin error: {s} (code={d})", .{ error_msg.msg, error_msg.code });
    responser.writeError("CNI plugin error", .{});
}

pub fn responseResult(allocator: Allocator, responser: *Responser, stdout: std.ArrayList(u8)) !void {
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

// Import Attachment after all types it depends on are declared above
const Attachment = @import("Attachment.zig").Attachment;

// -- Cni struct fields --

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

test {
    _ = CniConfig;
    _ = Attachment;
    _ = PluginConf;
}
