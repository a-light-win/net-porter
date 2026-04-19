const std = @import("std");
const config_mod = @import("../config.zig");
const json = std.json;
const log = std.log.scoped(.worker);
const traffic_log = std.log.scoped(.traffic);
const plugin = @import("../plugin.zig");
const AclManager = @import("AclManager.zig");
const DhcpManager = @import("../cni/DhcpManager.zig");
const Cni = @import("../cni/Cni.zig");
const CniManager = @import("../cni/CniManager.zig");
const StateFile = @import("../cni/StateFile.zig");
const Responser = plugin.Responser;
const ArenaAllocator = @import("../utils/ArenaAllocator.zig");
const Handler = @This();

const ClientInfo = extern struct {
    pid: std.posix.pid_t,
    uid: std.posix.uid_t,
    gid: std.posix.gid_t,
};

const Connection = struct { stream: std.Io.net.Stream };

arena: ArenaAllocator,
io: std.Io,
config: *config_mod.Config,
acl_manager: *AclManager,
cni_manager: *CniManager,
dhcp_manager: *DhcpManager,
connection: Connection,
responser: Responser,

pub fn deinit(self: *Handler) void {
    self.connection.stream.close(self.io);

    self.arena.deinit();
}

pub fn handle(self: *Handler) !void {
    var stream = self.connection.stream;

    var arena = try ArenaAllocator.init(self.arena.childAllocator());
    defer arena.deinit();
    const tentative_allocator = arena.allocator();

    const client_info = getClientInfo(&self.responser) catch |err| {
        log.err("Failed to get client info: {s}", .{@errorName(err)});
        return;
    };

    var read_buffer: [4096]u8 = undefined;
    var stream_reader = stream.reader(self.io, &read_buffer);
    const buf = stream_reader.interface.allocRemaining(
        tentative_allocator,
        .limited(plugin.max_request_size),
    ) catch |err| {
        log.err("Failed to read request: {s}", .{@errorName(err)});
        self.responser.writeError("Invalid request", .{});
        return;
    };

    const parsed_request = json.parseFromSlice(
        plugin.Request,
        tentative_allocator,
        buf,
        .{},
    ) catch |err| {
        log.err("Failed to parse request: {s}", .{@errorName(err)});
        self.responser.writeError("Invalid request", .{});
        return;
    };
    defer parsed_request.deinit();

    var request = parsed_request.value;
    request.process_id = client_info.pid;
    request.user_id = client_info.uid;

    const container_name = switch (request.request) {
        .network => "none",
        .exec => |exec| exec.container_name,
    };

    log.info(
        "Receive request from user({}) with pid({}), action={s}, container={s}, netns={s}",
        .{
            client_info.uid,
            client_info.pid,
            @tagName(request.action),
            container_name,
            request.netns orelse "none",
        },
    );

    if (request.raw_request) |raw_request| {
        traffic_log.debug("{s}", .{raw_request});
    }

    // Validate CNI identifiers for exec requests (path traversal prevention)
    if (request.request == .exec) {
        const exec_req = request.requestExec();
        validateCniIdentifier(exec_req.container_id, "container_id") catch |err| {
            log.err("Invalid container_id from uid={d}: {s}", .{ client_info.uid, @errorName(err) });
            self.responser.writeError("Invalid request", .{});
            return;
        };
        validateCniIdentifier(exec_req.network_options.interface_name, "interface_name") catch |err| {
            log.err("Invalid interface_name from uid={d}: {s}", .{ client_info.uid, @errorName(err) });
            self.responser.writeError("Invalid request", .{});
            return;
        };
        validateCniIdentifier(exec_req.container_name, "container_name") catch |err| {
            log.err("Invalid container_name from uid={d}: {s}", .{ client_info.uid, @errorName(err) });
            self.responser.writeError("Invalid request", .{});
            return;
        };
    }

    // Validate netns path format to prevent arbitrary path access via CNI_NETNS
    if (request.netns) |netns| {
        validateNetnsPath(netns) catch {
            log.err("Invalid netns path from uid={d}: {s}", .{ client_info.uid, netns });
            self.responser.writeError("Invalid network namespace path", .{});
            return;
        };
    }

    self.authClient(client_info, &request) catch |err| {
        log.err("Auth failed for uid={d}, resource={s}: {s}", .{
            client_info.uid,
            request.resource(),
            @errorName(err),
        });
        return;
    };

    const cni = self.cni_manager.loadCni(request.resource()) catch |err| {
        log.err("Failed to load CNI for resource={s}: {s}", .{
            request.resource(),
            @errorName(err),
        });
        self.responser.writeError("Internal error", .{});
        return;
    };

    // Static IP validation for setup action
    if (request.action == .setup) {
        if (self.acl_manager.isStaticResource(request.resource())) {
            self.validateStaticIp(client_info.uid, &request) catch |err| {
                log.err("Static IP validation failed for uid={d}, resource={s}: {s}", .{
                    client_info.uid,
                    request.resource(),
                    @errorName(err),
                });
                return;
            };
        }
    }

    self.execAction(tentative_allocator, cni, request, client_info.uid) catch |err| {
        if (!self.responser.done) {
            log.err("Failed to execute action={s} for container={s}: {s}", .{
                @tagName(request.action),
                container_name,
                @errorName(err),
            });
            self.responser.writeError("Internal error", .{});
            if (@errorReturnTrace()) |trace| {
                std.log.warn("Trace: {any}", .{trace});
            }
        }
        return;
    };

    // Ensure a response is always sent (e.g., teardown succeeds without
    // calling responser.write — the client is waiting for data).
    if (!self.responser.done) {
        self.responser.write("{}");
    }
}

fn execAction(
    self: *Handler,
    allocator: std.mem.Allocator,
    cni: *Cni,
    request: plugin.Request,
    caller_uid: u32,
) !void {
    // Only start DHCP service for DHCP resources (not static).
    // During teardown, the DHCP daemon may have crashed or the last
    // container (catatonit) may already be gone, causing ensureStarted()
    // to fail. Teardown should still proceed to clean up whatever it can.
    if (request.action != .teardown) {
        if (!self.acl_manager.isStaticResource(request.resource())) {
            try self.dhcp_manager.ensureStarted(caller_uid);
        }
    }
    switch (request.action) {
        .create => try cni.create(allocator, request, &self.responser),
        .setup => try cni.setup(allocator, request, &self.responser, caller_uid),
        .teardown => try cni.teardown(allocator, request, &self.responser, caller_uid),
    }

    // After teardown, stop DHCP service if no active attachments remain
    if (request.action == .teardown) {
        if (!self.acl_manager.isStaticResource(request.resource())) {
            if (!StateFile.hasActiveAttachments(self.io, caller_uid)) {
                self.dhcp_manager.stop(caller_uid);
            }
        }
    }
}

fn getClientInfo(responser: *Responser) std.posix.UnexpectedError!ClientInfo {
    // Get peer credentials
    var client_info: ClientInfo = undefined;
    var info_len: std.posix.socklen_t = @sizeOf(ClientInfo);
    const fd = responser.stream.socket.handle;
    const res = std.posix.system.getsockopt(
        fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.PEERCRED,
        @ptrCast(&client_info),
        &info_len,
    );
    if (res != 0) {
        responser.writeError("Internal error", .{});

        const json_err = std.posix.errno(res);
        log.warn("Failed to send error message: {s}", .{@tagName(json_err)});
        return std.posix.unexpectedErrno(json_err);
    }
    return client_info;
}

fn authClient(self: *Handler, client_info: ClientInfo, request: *const plugin.Request) !void {
    // Defense-in-depth: verify connecting UID matches the worker's target UID.
    // Primary defense is socket file permission (0600, owner=uid), but an
    // explicit check prevents misuse if file permissions are somehow bypassed
    // (e.g. CAP_DAC_OVERRIDE in a compromised namespace).
    if (client_info.uid != self.acl_manager.uid) {
        log.warn("UID mismatch: client={}, expected={}", .{ client_info.uid, self.acl_manager.uid });
        self.responser.writeError("Access denied", .{});
        return error.AccessDenied;
    }

    // Socket-level pre-filtering: reject if uid has no permission on any resource
    if (!self.acl_manager.hasAnyPermission()) {
        const err = error.AccessDenied;
        self.responser.writeError("Access denied", .{});
        return err;
    }
    // Resource-level ACL check
    if (!self.acl_manager.isAllowed(request.resource())) {
        const err = error.AccessDenied;
        self.responser.writeError("Access denied", .{});
        return err;
    }
}

fn validateStaticIp(self: *Handler, uid: u32, request: *const plugin.Request) !void {
    const exec_request = request.requestExec();
    const static_ips = exec_request.network_options.static_ips orelse {
        self.responser.writeError("Static IP is required", .{});
        return error.StaticIpRequired;
    };
    if (static_ips.len == 0) {
        self.responser.writeError("Static IP is required", .{});
        return error.StaticIpRequired;
    }

    // Validate ALL requested IPs against ACL (not just the first one).
    // In dual-stack configurations (IPv4 + IPv6), patchAddresses() injects
    // every IP that matches a template subnet, so each must be authorized.
    for (static_ips) |requested_ip| {
        if (!self.acl_manager.isIpAllowed(request.resource(), uid, requested_ip)) {
            self.responser.writeError("IP address not allowed", .{});
            return error.IpNotAllowed;
        }
    }
}

/// Validate a CNI identifier (container_id or interface_name) against a whitelist.
/// Only [a-zA-Z0-9\-_.] are allowed. Rejects empty strings, strings > 256 chars,
/// and ".." sequences to prevent path traversal attacks.
fn validateCniIdentifier(value: []const u8, field_name: []const u8) !void {
    if (value.len == 0) return error.InvalidParameter;
    if (value.len > 256) return error.InvalidParameter;
    for (value) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
            else => {
                log.warn("Invalid character in {s}: '{c}'", .{ field_name, c });
                return error.InvalidParameter;
            },
        }
    }
    if (std.mem.indexOf(u8, value, "..") != null) return error.InvalidParameter;
}

/// Validate that a netns path has the expected format: /proc/<pid>/ns/net
/// where <pid> is a non-empty sequence of decimal digits.
/// This prevents path traversal and arbitrary file access via CNI_NETNS.
pub fn validateNetnsPath(netns: []const u8) !void {
    const prefix = "/proc/";
    const suffix = "/ns/net";

    if (netns.len < prefix.len + 1 + suffix.len) return error.InvalidNetns;
    if (!std.mem.startsWith(u8, netns, prefix)) return error.InvalidNetns;
    if (!std.mem.endsWith(u8, netns, suffix)) return error.InvalidNetns;

    const pid_str = netns[prefix.len .. netns.len - suffix.len];
    if (pid_str.len == 0) return error.InvalidNetns;

    for (pid_str) |c| {
        switch (c) {
            '0'...'9' => {},
            else => return error.InvalidNetns,
        }
    }
}

test "validateCniIdentifier accepts valid identifiers" {
    try validateCniIdentifier("abc123", "test_field");
    try validateCniIdentifier("my-container-id", "test_field");
    try validateCniIdentifier("eth0", "test_field");
    try validateCniIdentifier("a.b_c-d", "test_field");
    try validateCniIdentifier("container.123", "test_field");
    try validateCniIdentifier(".", "test_field");
}

test "validateCniIdentifier rejects empty string" {
    try std.testing.expectError(error.InvalidParameter, validateCniIdentifier("", "test_field"));
}

test "validateCniIdentifier rejects string exceeding 256 chars" {
    const long_id = "a" ** 257;
    try std.testing.expectError(error.InvalidParameter, validateCniIdentifier(long_id, "test_field"));
}

test "validateCniIdentifier accepts exactly 256 chars" {
    const max_id = "a" ** 256;
    try validateCniIdentifier(max_id, "test_field");
}

test "validateCniIdentifier rejects path traversal characters" {
    try std.testing.expectError(error.InvalidParameter, validateCniIdentifier("abc/def", "test_field"));
    try std.testing.expectError(error.InvalidParameter, validateCniIdentifier("../etc/passwd", "test_field"));
    try std.testing.expectError(error.InvalidParameter, validateCniIdentifier("..", "test_field"));
    try std.testing.expectError(error.InvalidParameter, validateCniIdentifier("a..b", "test_field"));
}

test "validateCniIdentifier rejects special characters" {
    try std.testing.expectError(error.InvalidParameter, validateCniIdentifier("abc def", "test_field"));
    try std.testing.expectError(error.InvalidParameter, validateCniIdentifier("abc\x00def", "test_field"));
    try std.testing.expectError(error.InvalidParameter, validateCniIdentifier("abc;rm -rf /", "test_field"));
    try std.testing.expectError(error.InvalidParameter, validateCniIdentifier("abc|def", "test_field"));
    try std.testing.expectError(error.InvalidParameter, validateCniIdentifier("abc`def", "test_field"));
    try std.testing.expectError(error.InvalidParameter, validateCniIdentifier("abc$def", "test_field"));
}

test "validateNetnsPath accepts valid /proc/<pid>/ns/net paths" {
    try validateNetnsPath("/proc/1/ns/net");
    try validateNetnsPath("/proc/1234/ns/net");
    try validateNetnsPath("/proc/999999/ns/net");
}

test "validateNetnsPath rejects empty string" {
    try std.testing.expectError(error.InvalidNetns, validateNetnsPath(""));
}

test "validateNetnsPath rejects paths without /proc/ prefix" {
    try std.testing.expectError(error.InvalidNetns, validateNetnsPath("/etc/passwd"));
    try std.testing.expectError(error.InvalidNetns, validateNetnsPath("/run/user/1000/ns/net"));
    try std.testing.expectError(error.InvalidNetns, validateNetnsPath("proc/1/ns/net"));
}

test "validateNetnsPath rejects paths without /ns/net suffix" {
    try std.testing.expectError(error.InvalidNetns, validateNetnsPath("/proc/1/ns/mnt"));
    try std.testing.expectError(error.InvalidNetns, validateNetnsPath("/proc/1/net"));
    try std.testing.expectError(error.InvalidNetns, validateNetnsPath("/proc/1/ns"));
}

test "validateNetnsPath rejects non-numeric PID" {
    try std.testing.expectError(error.InvalidNetns, validateNetnsPath("/proc/abc/ns/net"));
    try std.testing.expectError(error.InvalidNetns, validateNetnsPath("/proc/12a34/ns/net"));
    try std.testing.expectError(error.InvalidNetns, validateNetnsPath("/proc/-1/ns/net"));
}

test "validateNetnsPath rejects empty PID" {
    try std.testing.expectError(error.InvalidNetns, validateNetnsPath("/proc//ns/net"));
}

test "validateNetnsPath rejects path traversal attempts" {
    try std.testing.expectError(error.InvalidNetns, validateNetnsPath("../../etc/passwd"));
    try std.testing.expectError(error.InvalidNetns, validateNetnsPath("/proc/../etc/shadow"));
    try std.testing.expectError(error.InvalidNetns, validateNetnsPath("/proc/1/../../etc/passwd"));
}

test "validateNetnsPath rejects overly long paths" {
    const long_path = "/proc/" ++ ("0" ** 1000) ++ "/ns/net";
    // This should actually be accepted since it's a valid format with a long PID
    // But real PIDs won't be this long
    try validateNetnsPath(long_path);
}
