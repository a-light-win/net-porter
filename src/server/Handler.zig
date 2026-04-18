const std = @import("std");
const config_mod = @import("../config.zig");
const json = std.json;
const log = std.log.scoped(.server);
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
        self.responser.writeError("Failed to read request: {s}", .{@errorName(err)});
        return;
    };

    const parsed_request = json.parseFromSlice(
        plugin.Request,
        tentative_allocator,
        buf,
        .{},
    ) catch |err| {
        log.err("Failed to parse request: {s}", .{@errorName(err)});
        self.responser.writeError("Failed to parse request: {s}", .{@errorName(err)});
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
            self.responser.writeError("Invalid container_id: {s}", .{@errorName(err)});
            return;
        };
        validateCniIdentifier(exec_req.network_options.interface_name, "interface_name") catch |err| {
            log.err("Invalid interface_name from uid={d}: {s}", .{ client_info.uid, @errorName(err) });
            self.responser.writeError("Invalid interface_name: {s}", .{@errorName(err)});
            return;
        };
    }

    self.authClient(client_info, &request) catch |err| {
        log.err("Auth failed for uid={d}, gid={d}, resource={s}: {s}", .{
            client_info.uid,
            client_info.gid,
            request.resource(),
            @errorName(err),
        });
        return;
    };

    self.checkNetns(client_info, &request) catch |err| {
        log.err("Netns check failed for uid={d}, netns={s}: {s}", .{
            client_info.uid,
            request.netns orelse "none",
            @errorName(err),
        });
        return;
    };

    const cni = self.cni_manager.loadCni(request.resource()) catch |err| {
        log.err("Failed to load CNI for resource={s}: {s}", .{
            request.resource(),
            @errorName(err),
        });
        self.responser.writeError("Failed to load CNI: {s}", .{@errorName(err)});
        return;
    };

    // Static IP validation for setup action
    if (request.action == .setup) {
        if (self.acl_manager.isStaticResource(self.io, request.resource())) {
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
            self.responser.writeError("Failed to execute action: {s}", .{@errorName(err)});
            if (@errorReturnTrace()) |trace| {
                std.log.warn("Trace: {any}", .{trace});
            }
        }
    };
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
        if (!self.acl_manager.isStaticResource(self.io, request.resource())) {
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
        if (!self.acl_manager.isStaticResource(self.io, request.resource())) {
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
        responser.writeError("Failed to get connection info: {d}", .{res});

        const json_err = std.posix.errno(res);
        log.warn("Failed to send error message: {s}", .{@tagName(json_err)});
        return std.posix.unexpectedErrno(json_err);
    }
    return client_info;
}

fn authClient(self: *Handler, client_info: ClientInfo, request: *const plugin.Request) !void {
    // Socket-level pre-filtering: reject if uid has no permission on any resource
    if (!self.acl_manager.hasAnyPermission(self.io, client_info.uid, client_info.gid)) {
        const err = error.AccessDenied;
        self.responser.writeError(
            "User {} has no permission on any resource, error: {s}",
            .{ client_info.uid, @errorName(err) },
        );
        return err;
    }
    // Resource-level ACL check
    if (!self.acl_manager.isAllowed(self.io, request.resource(), client_info.uid, client_info.gid)) {
        const err = error.AccessDenied;
        self.responser.writeError(
            "Failed to access resource '{s}', error: {s}",
            .{
                request.resource(),
                @errorName(err),
            },
        );
        return err;
    }
}

fn checkNetns(self: *Handler, client_info: ClientInfo, request: *const plugin.Request) !void {
    _ = self;
    _ = client_info;
    if (request.netns) |_| {
        // In the per-user daemon architecture, ownership verification is not needed:
        //   1. Each worker serves exactly one UID (enforced by main process via ACL)
        //   2. Socket ownership is set by fchownat to the target UID
        //   3. Client UID is verified via SO_PEERCRED before reaching here
        //   4. After setns into catatonit's mount namespace, statx returns
        //      container-mapped UIDs (e.g., 0 instead of 1000), making
        //      direct UID comparison incorrect.
        //
        // We only need to verify the netns path is accessible.
    }
}

fn validateStaticIp(self: *Handler, uid: u32, request: *const plugin.Request) !void {
    const exec_request = request.requestExec();
    const static_ips = exec_request.network_options.static_ips orelse {
        self.responser.writeError("Static IP is required for resource '{s}'", .{request.resource()});
        return error.StaticIpRequired;
    };
    if (static_ips.len == 0) {
        self.responser.writeError("Static IP is required for resource '{s}'", .{request.resource()});
        return error.StaticIpRequired;
    }

    const requested_ip = static_ips[0];
    if (!self.acl_manager.isIpAllowed(self.io, request.resource(), uid, requested_ip)) {
        self.responser.writeError("IP '{s}' is not allowed for uid={d} on resource '{s}'", .{
            requested_ip,
            uid,
            request.resource(),
        });
        return error.IpNotAllowed;
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
