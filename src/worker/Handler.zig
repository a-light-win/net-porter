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

    // Validate action/request type consistency.
    // Normal flow: create→network, setup/teardown→exec.
    // A client bypassing the plugin could send mismatched types,
    // which would trigger unreachable in requestExec() downstream.
    switch (request.action) {
        .create => {
            if (request.request != .network) {
                log.err("Invalid request: create action with non-network type from uid={d}", .{client_info.uid});
                self.responser.writeError("Invalid request", .{});
                return;
            }
        },
        .setup, .teardown => {
            if (request.request != .exec) {
                log.err("Invalid request: {s} action with non-exec type from uid={d}", .{@tagName(request.action), client_info.uid});
                self.responser.writeError("Invalid request", .{});
                return;
            }
        },
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

    // Validate netns path: must be under /run/user/<uid>/netns/ with safe filename.
    // CNI plugins verify the file is a network namespace; this is a pre-filter
    // to reject obviously invalid paths before reaching the plugin.
    if (request.netns) |netns| {
        validateNetnsPath(netns, client_info.uid) catch |err| {
            log.err("Invalid netns path from uid={d}: {s} ({s})", .{ client_info.uid, netns, @errorName(err) });
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

/// Validate netns path: must reside under /run/user/<uid>/netns/ with a safe filename.
///
/// `uid` is the authenticated caller's uid (known from socket credentials).
/// The prefix `/run/user/<uid>/netns/` is constructed from this uid — we do not
/// parse or trust the uid embedded in the path.
///
/// The filename must be non-empty, contain only [a-zA-Z0-9\-_.], and have no
/// ".." sequences. This prevents path traversal and arbitrary file pointing.
///
/// File type verification (is this actually a network namespace?) is handled
/// by the CNI plugin itself via setns() — our job is just a pre-filter.
fn validateNetnsPath(netns: []const u8, uid: u32) !void {
    var prefix_buf: [32]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "/run/user/{d}/netns/", .{uid}) catch unreachable;

    if (!std.mem.startsWith(u8, netns, prefix)) return error.NetnsPathInvalidFormat;

    const name = netns[prefix.len..];
    if (name.len == 0) return error.NetnsPathInvalidFormat;
    if (std.mem.indexOf(u8, name, "..") != null) return error.NetnsPathInvalidFormat;
    for (name) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
            else => return error.NetnsPathInvalidFormat,
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

test "validateNetnsPath accepts valid paths" {
    try validateNetnsPath("/run/user/1000/netns/netns-df0ba9a2-dde1-ca4f-6efe-c96c4f9a353d", 1000);
    try validateNetnsPath("/run/user/0/netns/test", 0);
    try validateNetnsPath("/run/user/1000/netns/my-ns_name.1", 1000);
}

test "validateNetnsPath rejects wrong prefix or uid mismatch" {
    try std.testing.expectError(error.NetnsPathInvalidFormat, validateNetnsPath("/proc/1/ns/net", 1000));
    try std.testing.expectError(error.NetnsPathInvalidFormat, validateNetnsPath("/run/user/999/netns/test", 1000));
    try std.testing.expectError(error.NetnsPathInvalidFormat, validateNetnsPath("relative/path", 1000));
    try std.testing.expectError(error.NetnsPathInvalidFormat, validateNetnsPath("", 1000));
}

test "validateNetnsPath rejects empty filename" {
    try std.testing.expectError(error.NetnsPathInvalidFormat, validateNetnsPath("/run/user/1000/netns/", 1000));
}

test "validateNetnsPath rejects unsafe filename" {
    try std.testing.expectError(error.NetnsPathInvalidFormat, validateNetnsPath("/run/user/1000/netns/bad name", 1000));
    try std.testing.expectError(error.NetnsPathInvalidFormat, validateNetnsPath("/run/user/1000/netns/bad/name", 1000));
    try std.testing.expectError(error.NetnsPathInvalidFormat, validateNetnsPath("/run/user/1000/netns/..", 1000));
    try std.testing.expectError(error.NetnsPathInvalidFormat, validateNetnsPath("/run/user/1000/netns/../etc/passwd", 1000));
}

// ─── Action/Request consistency tests ──────────────────────────────────
//
// The consistency check in handle() exists because a malicious client
// can craft JSON that the plugin would never produce: e.g. action=setup
// with request=.network. Without the guard, this reaches requestExec()
// which hits `unreachable` and crashes the worker.
//
// These tests verify the dangerous state is parseable from JSON (the
// attack vector) and document the invariant the guard protects.

test "action/request consistency: setup+network is parseable from JSON" {
    const allocator = std.testing.allocator;

    // Malicious JSON: setup action paired with network type
    const malicious_json =
        \\{"action":"setup","request":{"network":{"driver":"net-porter","options":{"net_porter_socket":"/run/user/1000/net-porter.sock","net_porter_resource":"test-resource"}}}}
    ;

    const parsed = std.json.parseFromSlice(plugin.Request, allocator, malicious_json, .{}) catch |err| {
        // If parsing fails, the attack vector is already blocked by the parser
        std.debug.print("Parser rejected mismatched JSON: {s}\n", .{@errorName(err)});
        return;
    };
    defer parsed.deinit();

    const request = parsed.value;
    // Verify the dangerous state exists after parsing
    try std.testing.expect(request.action == .setup);
    try std.testing.expect(request.request == .network);
    // requestExec() on this would hit unreachable — handle() guards against it.
}

test "action/request consistency: teardown+network is parseable from JSON" {
    const allocator = std.testing.allocator;

    const malicious_json =
        \\{"action":"teardown","request":{"network":{"driver":"net-porter","options":{"net_porter_socket":"/run/user/1000/net-porter.sock","net_porter_resource":"test-resource"}}}}
    ;

    const parsed = std.json.parseFromSlice(plugin.Request, allocator, malicious_json, .{}) catch return;
    defer parsed.deinit();

    const request = parsed.value;
    try std.testing.expect(request.action == .teardown);
    try std.testing.expect(request.request == .network);
}

test "action/request consistency: create+exec is parseable from JSON" {
    const allocator = std.testing.allocator;

    const malicious_json =
        \\{"action":"create","request":{"exec":{"container_name":"test","container_id":"test-id","network":{"driver":"net-porter","options":{"net_porter_socket":"/run/user/1000/net-porter.sock","net_porter_resource":"test-resource"}},"network_options":{"interface_name":"eth0"}}}}
    ;

    const parsed = std.json.parseFromSlice(plugin.Request, allocator, malicious_json, .{}) catch return;
    defer parsed.deinit();

    const request = parsed.value;
    try std.testing.expect(request.action == .create);
    try std.testing.expect(request.request == .exec);
}
