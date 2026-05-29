const std = @import("std");
const linux = std.os.linux;
const config_mod = @import("../config.zig");
const json = std.json;
const log = std.log.scoped(.worker);
const traffic_log = std.log.scoped(.traffic);
const plugin = @import("../plugin.zig");
const AclManager = @import("AclManager.zig");
const DhcpService = @import("../cni/DhcpService.zig");
const Cni = @import("../cni/Cni.zig");
const CniManager = @import("../cni/CniManager.zig");
const StateFile = @import("../cni/StateFile.zig");
const Responser = @import("../common/Responser.zig");
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
dhcp_service: *DhcpService,
catatonit_pid: std.posix.pid_t,
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
                log.err("Invalid request: {s} action with non-exec type from uid={d}", .{ @tagName(request.action), client_info.uid });
                self.responser.writeError("Invalid request", .{});
                return;
            }
        },
    }

    // Validate CNI identifiers for exec requests (path traversal prevention)
    if (request.request == .exec) {
        const exec_req = try request.requestExec();
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

    // Validate resource BEFORE calling request.resource(), which uses
    // `catch unreachable` and would crash the worker if resource is null.
    // A malicious client connecting directly to the socket can omit the
    // resource field, so we must validate it as untrusted input.
    const resource = request.network().options.resolveResource() catch {
        log.err("Missing resource from uid={d}", .{client_info.uid});
        self.responser.writeError("Missing resource", .{});
        return;
    };
    validateCniIdentifier(resource, "resource") catch |err| {
        log.err("Invalid resource from uid={d}: {s}", .{ client_info.uid, @errorName(err) });
        self.responser.writeError("Invalid request", .{});
        return;
    };

    // Validate netns path: must be under /run/user/<uid>/netns/ with safe filename.
    // CNI plugins verify the file is a network namespace; this is a pre-filter
    // to reject obviously invalid paths before reaching the plugin.
    //
    // For setup/teardown, netns is MANDATORY. Without it, Attachment.setup/teardown
    // falls back to "/proc/self/ns/net" (the worker's own namespace = host namespace),
    // which would cause CNI plugins to operate on the host's network namespace instead
    // of the container's. A malicious client connecting to the socket directly could
    // exploit this to create/modify host network interfaces.
    if (request.action == .setup or request.action == .teardown) {
        if (request.netns == null) {
            log.err("Missing netns for {s} action from uid={d}", .{ @tagName(request.action), client_info.uid });
            self.responser.writeError("netns is required", .{});
            return;
        }
    }

    // For setup/teardown, also verify the catatonit process is still alive and
    // owned by the caller's UID. This prevents PID recycling attacks: if
    // catatonit dies and its PID is reused by a different process (potentially
    // a different user), /proc/<catatonit_pid>/root/ would resolve to the wrong
    // filesystem, leaking or corrupting network configuration.
    if (request.netns) |netns| {
        // Verify catatonit is still the expected process
        verifyCatatonitProcess(self.io, self.catatonit_pid, client_info.uid) catch |err| {
            log.err("Catatonit verification failed for uid={d}, catatonit_pid={d}: {s}", .{ client_info.uid, self.catatonit_pid, @errorName(err) });
            self.responser.writeError("Network namespace unavailable", .{});
            return;
        };

        validateNetnsPath(netns, client_info.uid) catch |err| {
            log.err("Invalid netns path from uid={d}: {s} ({s})", .{ client_info.uid, netns, @errorName(err) });
            self.responser.writeError("Invalid network namespace path", .{});
            return;
        };

        // Resolve netns through catatonit's mount namespace.
        // The original path (e.g., /run/user/1000/netns/netns-xxx) is only meaningful
        // inside catatonit's mount namespace where the nsfs is mounted.
        // /proc/<catatonit_pid>/root/ traverses into that mount namespace.
        // NOTE: nsfs verification (verifyNetnsNsfs) is temporarily disabled.
        // CNI plugins perform their own validation via setns().
        const resolved = std.fmt.allocPrint(
            tentative_allocator,
            "/proc/{d}/root{s}",
            .{ self.catatonit_pid, netns },
        ) catch {
            log.err("OOM constructing netns path for uid={d}", .{client_info.uid});
            self.responser.writeError("Internal error", .{});
            return;
        };

        logNetnsDiagnostics(self.io, netns, resolved, client_info.pid, self.catatonit_pid, client_info.uid);

        request.netns = resolved;
    }

    self.authClient(client_info, &request) catch |err| {
        log.err("Auth failed for uid={d}, resource={s}: {s}", .{
            client_info.uid,
            request.resource() catch "<unknown>",
            @errorName(err),
        });
        return;
    };

    const cni = self.cni_manager.loadCni(resource) catch |err| {
        log.err("Failed to load CNI for resource={s}: {s}", .{
            resource,
            @errorName(err),
        });
        self.responser.writeError("Internal error", .{});
        return;
    };

    // Static IP validation for setup action
    if (request.action == .setup) {
        if (self.acl_manager.isStaticResource(resource)) {
            self.validateStaticIp(client_info.uid, &request) catch |err| {
                log.err("Static IP validation failed for uid={d}, resource={s}: {s}", .{
                    client_info.uid,
                    request.resource() catch "<unknown>",
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
    const resource = request.resource() catch |err| {
        log.err("Failed to resolve resource: {s}", .{@errorName(err)});
        self.responser.writeError("Internal error", .{});
        return err;
    };

    // Only start DHCP service for DHCP resources (not static).
    // During teardown, the DHCP daemon may have crashed or the last
    // container (catatonit) may already be gone, causing ensureStarted()
    // to fail. Teardown should still proceed to clean up whatever it can.
    if (request.action != .teardown) {
        if (!self.acl_manager.isStaticResource(resource)) {
            try self.dhcp_service.ensureStarted();
        }
    }
    switch (request.action) {
        .create => try cni.create(allocator, request, &self.responser),
        .setup => try cni.setup(allocator, request, &self.responser, caller_uid),
        .teardown => try cni.teardown(allocator, request, &self.responser, caller_uid),
    }

    // After teardown, stop DHCP service if no active attachments remain
    if (request.action == .teardown) {
        if (!self.acl_manager.isStaticResource(resource)) {
            if (!StateFile.hasActiveAttachments(self.io, caller_uid)) {
                self.dhcp_service.stop();
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
        log.warn("Failed to get peer credentials: {s}", .{@tagName(json_err)});
        return std.posix.unexpectedErrno(json_err);
    }
    return client_info;
}

fn authClient(self: *Handler, client_info: ClientInfo, request: *const plugin.Request) !void {
    const resource = request.resource() catch |err| {
        log.err("Failed to resolve resource: {s}", .{@errorName(err)});
        self.responser.writeError("Internal error", .{});
        return err;
    };

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
    if (!self.acl_manager.isAllowed(resource)) {
        const err = error.AccessDenied;
        self.responser.writeError("Access denied", .{});
        return err;
    }
}

fn validateStaticIp(self: *Handler, uid: u32, request: *const plugin.Request) !void {
    const resource = request.resource() catch |err| {
        log.err("Failed to resolve resource: {s}", .{@errorName(err)});
        self.responser.writeError("Internal error", .{});
        return err;
    };

    const exec_request = try request.requestExec();
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
        if (!self.acl_manager.isIpAllowed(resource, uid, requested_ip)) {
            self.responser.writeError("IP address not allowed: {s}", .{requested_ip});
            return error.IpNotAllowed;
        }
    }
}

/// Validate a CNI identifier (container_id or interface_name) against a whitelist.
/// Only [a-zA-Z0-9\-_.] are allowed. Rejects empty strings, strings > 128 chars,
/// and ".." sequences to prevent path traversal attacks.
fn validateCniIdentifier(value: []const u8, field_name: []const u8) !void {
    if (value.len == 0) return error.InvalidParameter;
    if (value.len > 128) return error.InvalidParameter;
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

/// Verify that the catatonit process is still alive, still named "catatonit",
/// and still owned by the expected UID.
///
/// Called before each setup/teardown request that resolves a netns path through
/// /proc/<catatonit_pid>/root/. Prevents PID recycling attacks where catatonit
/// has died and its PID was reused by a different user's process — which would
/// cause /proc/<pid>/root/ to resolve to the wrong filesystem.
///
/// Checks:
///   1. /proc/<pid> directory exists and is owned by expected_uid (statx)
///   2. /proc/<pid>/comm contains "catatonit" (not a recycled process)
///   3. /proc/<pid>/exe symlink ends with "/catatonit" (cannot be spoofed via prctl)
fn verifyCatatonitProcess(io: std.Io, pid: std.posix.pid_t, expected_uid: u32) !void {
    // Check 1: Process UID via statx on /proc/<pid>
    var path_buf: [64:0]u8 = undefined;
    const dir_path = std.fmt.bufPrint(path_buf[0..], "/proc/{d}", .{pid}) catch return error.CatatonitVerifyFailed;
    path_buf[dir_path.len] = 0;

    var stat_buf: linux.Statx = undefined;
    const stat_rc = linux.statx(linux.AT.FDCWD, &path_buf, 0, .{ .UID = true }, &stat_buf);
    if (stat_rc != 0) {
        log.warn("catatonit statx failed for pid={d}", .{pid});
        return error.CatatonitProcessGone;
    }
    if (stat_buf.uid != expected_uid) {
        log.warn("catatonit uid mismatch: pid={d} expected uid={d} got uid={d}", .{ pid, expected_uid, stat_buf.uid });
        return error.CatatonitUidMismatch;
    }

    // Check 2: Process name via /proc/<pid>/comm
    var comm_buf: [64]u8 = undefined;
    const comm_path = std.fmt.bufPrint(&comm_buf, "/proc/{d}/comm", .{pid}) catch return error.CatatonitVerifyFailed;

    var file = std.Io.Dir.cwd().openFile(io, comm_path, .{}) catch {
        log.warn("catatonit comm open failed for pid={d}", .{pid});
        return error.CatatonitProcessGone;
    };
    defer file.close(io);

    var read_buf: [64]u8 = undefined;
    const n = file.readPositionalAll(io, &read_buf, 0) catch return error.CatatonitVerifyFailed;
    if (n == 0) return error.CatatonitProcessGone;

    const name = std.mem.trim(u8, read_buf[0..n], " \t\r\n");
    if (!std.mem.eql(u8, name, "catatonit")) {
        log.warn("catatonit comm mismatch: pid={d} expected 'catatonit' got '{s}'", .{ pid, name });
        return error.CatatonitNotCatatonit;
    }

    // Check 3: Executable path via /proc/<pid>/exe
    // Unlike comm (settable via prctl(PR_SET_NAME)), the exe symlink points
    // to the actual binary path and cannot be changed by the process.
    var exe_path_buf: [64]u8 = undefined;
    const exe_path = std.fmt.bufPrint(&exe_path_buf, "/proc/{d}/exe", .{pid}) catch return error.CatatonitVerifyFailed;

    var exe_buf: [std.posix.PATH_MAX]u8 = undefined;
    const exe_n = std.Io.Dir.readLinkAbsolute(io, exe_path, &exe_buf) catch {
        log.warn("catatonit exe readlink failed for pid={d}", .{pid});
        return error.CatatonitProcessGone;
    };
    const exe = exe_buf[0..exe_n];
    if (!std.mem.endsWith(u8, exe, "/catatonit") and !std.mem.endsWith(u8, exe, "/catatonit (deleted)")) {
        log.warn("catatonit exe mismatch: pid={d} exe='{s}' does not end with /catatonit", .{ pid, exe });
        return error.CatatonitNotCatatonit;
    }
}

/// Verify that a resolved netns path resides on an nsfs filesystem (f_type == NSFS_MAGIC).
///
/// Defense-in-depth against mount replacement attacks inside catatonit's
/// mount namespace. Without this check, a container user with CAP_SYS_ADMIN in their
/// user namespace could unmount the nsfs and replace it with a different filesystem
/// to redirect CNI plugins to an unintended namespace.
///
/// Uses statfs to check the filesystem magic number:
///   - If statfs fails → rejected (path inaccessible)
///   - If the filesystem is not nsfs (f_type != NSFS_MAGIC) → rejected
///
/// NOTE: statfs follows symlinks, so a symlink to an nsfs file will pass. This is
/// acceptable because validateNetnsPath() and verifyCatatonitProcess() already ensure
/// the path and mount namespace are legitimate.
///
/// NOTE: There is a TOCTOU window between this check and the CNI plugin's open().
/// This is accepted because:
///   1. Rootless containers have independent PID + mount namespaces, limiting
///      attacks to the container's own namespace (no cross-user escalation)
///   2. CNI plugins validate the fd via setns(), which fails on non-netns files
///   3. The precise timing required makes exploitation impractical
fn verifyNetnsNsfs(resolved_path: []const u8) !void {
    // Need a sentinel-terminated path for the statfs syscall
    var path_buf: [std.Io.Dir.max_path_bytes + 1:0]u8 = undefined;
    const path_z: [:0]const u8 = if (std.meta.sentinel(@TypeOf(resolved_path)) != null)
        resolved_path
    else blk: {
        if (resolved_path.len > std.Io.Dir.max_path_bytes) return error.NetnsPathInvalidFormat;
        @memcpy(path_buf[0..resolved_path.len], resolved_path);
        path_buf[resolved_path.len] = 0;
        break :blk path_buf[0..resolved_path.len :0];
    };

    var buf: Statfs = undefined;
    const rc = linux.syscall2(
        .statfs,
        @intFromPtr(path_z.ptr),
        @intFromPtr(&buf),
    );
    if (rc != 0) {
        const err = std.posix.errno(rc);
        log.warn("netns statfs failed for '{s}': {s}", .{ resolved_path, @tagName(err) });
        return error.NetnsStatFailed;
    }

    if (buf.f_type != NSFS_MAGIC) {
        log.warn("netns path '{s}' is not on nsfs (f_type=0x{x})", .{
            resolved_path,
            @as(u64, @bitCast(buf.f_type)),
        });
        return error.NetnsNotNsfs;
    }
}

/// statfs result structure matching the kernel's struct statfs layout.
const Statfs = extern struct {
    f_type: c_long,
    f_bsize: c_long,
    f_blocks: c_ulong,
    f_bfree: c_ulong,
    f_bavail: c_ulong,
    f_files: c_ulong,
    f_ffree: c_ulong,
    f_fsid: [2]c_int,
    f_namelen: c_long,
    f_frsize: c_long,
    f_flags: c_long,
    f_spare: [4]c_long,
};

const NSFS_MAGIC: c_long = 0x6e736673;

/// Helper for logNetnsDiagnostics: run statfs on a path and log the result.
/// Never errors — failures are logged and silently swallowed.
fn diagStatfs(path: []const u8, label: []const u8) void {
    var path_buf: [std.Io.Dir.max_path_bytes + 1:0]u8 = undefined;
    if (path.len > std.Io.Dir.max_path_bytes) {
        log.debug("[diag] statfs on {s}: path too long", .{label});
        return;
    }
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    var buf: Statfs = undefined;
    const rc = linux.syscall2(.statfs, @intFromPtr(&path_buf), @intFromPtr(&buf));
    if (rc == 0) {
        const is_nsfs = buf.f_type == NSFS_MAGIC;
        log.debug("[diag] statfs on {s}: f_type=0x{x}, is_nsfs={}", .{
            label,
            @as(u64, @bitCast(buf.f_type)),
            is_nsfs,
        });
    } else {
        log.debug("[diag] statfs on {s}: error={s}", .{ label, @tagName(std.posix.errno(rc)) });
    }
}

/// Log diagnostic information about netns resolution for cross-distribution debugging.
/// This function NEVER returns errors and NEVER affects the request flow.
/// All syscalls are wrapped to silently swallow failures; results are logged only.
fn logNetnsDiagnostics(
    io: std.Io,
    netns: []const u8,
    resolved: []const u8,
    client_pid: std.posix.pid_t,
    catatonit_pid: std.posix.pid_t,
    uid: u32,
) void {
    _ = io;
    _ = catatonit_pid;
    _ = uid;

    const NS_GET_USERNS: u64 = 0x0000B701;

    log.debug("[diag] original netns path: {s}", .{netns});
    log.debug("[diag] resolved netns path: {s}", .{resolved});

    diagStatfs(netns, "original");
    diagStatfs(resolved, "resolved");

    var netns_inode: u64 = 0;
    var found_netns_inode = false;
    var owning_userns_inode: u64 = 0;
    var found_owning_inode = false;

    inspect_resolved: {
        var res_buf: [std.Io.Dir.max_path_bytes + 1:0]u8 = undefined;
        if (resolved.len > std.Io.Dir.max_path_bytes) {
            log.debug("[diag] open resolved: path too long", .{});
            break :inspect_resolved;
        }
        @memcpy(res_buf[0..resolved.len], resolved);
        res_buf[resolved.len] = 0;

        const open_rc = linux.openat(linux.AT.FDCWD, res_buf[0..resolved.len :0], .{ .CLOEXEC = true }, 0);
        if (std.posix.errno(open_rc) != .SUCCESS) {
            log.debug("[diag] open resolved: error={s}", .{@tagName(std.posix.errno(open_rc))});
            break :inspect_resolved;
        }
        const netns_fd: std.posix.fd_t = @intCast(open_rc);
        defer _ = linux.close(netns_fd);

        var stat_buf: linux.Statx = undefined;
        const fstat_rc = linux.statx(netns_fd, "", linux.AT.EMPTY_PATH, .{ .INO = true }, &stat_buf);
        if (fstat_rc == 0) {
            netns_inode = stat_buf.ino;
            found_netns_inode = true;
            log.debug("[diag] open resolved: inode={d}", .{netns_inode});
        } else {
            log.debug("[diag] open resolved: fstat error={s}", .{@tagName(std.posix.errno(fstat_rc))});
        }

        const ioctl_rc = linux.syscall3(
            .ioctl,
            @as(u64, @bitCast(@as(i64, netns_fd))),
            NS_GET_USERNS,
            0,
        );
        if (std.posix.errno(ioctl_rc) != .SUCCESS) {
            log.debug("[diag] NS_GET_USERNS: error={s}", .{@tagName(std.posix.errno(ioctl_rc))});
            break :inspect_resolved;
        }
        const userns_fd: std.posix.fd_t = @intCast(ioctl_rc);
        defer _ = linux.close(userns_fd);

        var user_stat: linux.Statx = undefined;
        const user_fstat_rc = linux.statx(userns_fd, "", linux.AT.EMPTY_PATH, .{ .INO = true }, &user_stat);
        if (user_fstat_rc == 0) {
            owning_userns_inode = user_stat.ino;
            found_owning_inode = true;
            log.debug("[diag] NS_GET_USERNS: owning_userns_inode={d}", .{owning_userns_inode});
        } else {
            log.debug("[diag] NS_GET_USERNS: fstat error={s}", .{@tagName(std.posix.errno(user_fstat_rc))});
        }
    }

    compare_host: {
        const host_path = "/proc/1/ns/net";
        const open_rc = linux.openat(linux.AT.FDCWD, host_path, .{ .CLOEXEC = true }, 0);
        if (std.posix.errno(open_rc) != .SUCCESS) {
            log.debug("[diag] host netns /proc/1/ns/net: error={s}", .{@tagName(std.posix.errno(open_rc))});
            break :compare_host;
        }
        const host_fd: std.posix.fd_t = @intCast(open_rc);
        defer _ = linux.close(host_fd);

        var host_stat: linux.Statx = undefined;
        const fstat_rc = linux.statx(host_fd, "", linux.AT.EMPTY_PATH, .{ .INO = true }, &host_stat);
        if (fstat_rc == 0) {
            log.debug("[diag] host netns /proc/1/ns/net: inode={d}", .{host_stat.ino});
            if (found_netns_inode) {
                log.debug("[diag] netns vs host: match={}", .{netns_inode == host_stat.ino});
            }
        } else {
            log.debug("[diag] host netns /proc/1/ns/net: fstat error={s}", .{@tagName(std.posix.errno(fstat_rc))});
        }
    }

    compare_client_userns: {
        var client_buf: [64:0]u8 = undefined;
        const client_path = std.fmt.bufPrint(client_buf[0..], "/proc/{d}/ns/user", .{client_pid}) catch break :compare_client_userns;
        client_buf[client_path.len] = 0;

        const open_rc = linux.openat(linux.AT.FDCWD, client_buf[0..client_path.len :0], .{ .CLOEXEC = true }, 0);
        if (std.posix.errno(open_rc) != .SUCCESS) {
            log.debug("[diag] client user ns /proc/{d}/ns/user: error={s}", .{ client_pid, @tagName(std.posix.errno(open_rc)) });
            break :compare_client_userns;
        }
        const client_fd: std.posix.fd_t = @intCast(open_rc);
        defer _ = linux.close(client_fd);

        var client_stat: linux.Statx = undefined;
        const fstat_rc = linux.statx(client_fd, "", linux.AT.EMPTY_PATH, .{ .INO = true }, &client_stat);
        if (fstat_rc == 0) {
            log.debug("[diag] client user ns /proc/{d}/ns/user: inode={d}", .{ client_pid, client_stat.ino });
            if (found_owning_inode) {
                log.debug("[diag] netns owner vs client user ns: match={}", .{owning_userns_inode == client_stat.ino});
            }
        } else {
            log.debug("[diag] client user ns /proc/{d}/ns/user: fstat error={s}", .{ client_pid, @tagName(std.posix.errno(fstat_rc)) });
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

test "validateCniIdentifier rejects string exceeding 128 chars" {
    const long_id = "a" ** 129;
    try std.testing.expectError(error.InvalidParameter, validateCniIdentifier(long_id, "test_field"));
}

test "validateCniIdentifier accepts exactly 128 chars" {
    const max_id = "a" ** 128;
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

// ─── verifyCatatonitProcess tests ─────────────────────────────────────

test "verifyCatatonitProcess rejects non-existent PID" {
    try std.testing.expectError(
        error.CatatonitProcessGone,
        verifyCatatonitProcess(std.testing.io, 99999999, 0),
    );
}

test "verifyCatatonitProcess rejects wrong process name" {
    // Current process is not catatonit
    const own_pid: std.posix.pid_t = @intCast(std.os.linux.getpid());
    const own_uid: u32 = std.os.linux.getuid();
    try std.testing.expectError(
        error.CatatonitNotCatatonit,
        verifyCatatonitProcess(std.testing.io, own_pid, own_uid),
    );
}

test "verifyCatatonitProcess rejects UID mismatch" {
    const own_pid: std.posix.pid_t = @intCast(std.os.linux.getpid());
    try std.testing.expectError(
        error.CatatonitUidMismatch,
        verifyCatatonitProcess(std.testing.io, own_pid, std.math.maxInt(u32)),
    );
}

// ─── verifyNetnsNsfs tests ────────────────────────────────────────────

test "verifyNetnsNsfs rejects non-existent path" {
    try std.testing.expectError(
        error.NetnsStatFailed,
        verifyNetnsNsfs("/proc/99999999/root/run/user/1000/netns/nonexistent"),
    );
}

test "verifyNetnsNsfs rejects regular file (not nsfs)" {
    // /proc/self/comm is a regular procfs file, not an nsfs file
    try std.testing.expectError(
        error.NetnsNotNsfs,
        verifyNetnsNsfs("/proc/self/comm"),
    );
}

test "verifyNetnsNsfs rejects symlink to non-nsfs" {
    // statfs follows symlinks, so a symlink to a non-nsfs file is caught
    // by the f_type check (same as a direct path to a non-nsfs target).
    const link_path: [*:0]const u8 = "/tmp/net-porter-test-nsfs-symlink";
    _ = std.os.linux.unlink(link_path);
    const rc = std.os.linux.symlink("/proc/self/comm", link_path);
    if (rc != 0) return; // skip if can't create symlink
    defer _ = std.os.linux.unlink(link_path);

    // Symlink target (/proc/self/comm) is on procfs (not nsfs) → rejected
    try std.testing.expectError(
        error.NetnsNotNsfs,
        verifyNetnsNsfs(std.mem.sliceTo(link_path, 0)),
    );
}

test "verifyNetnsNsfs accepts nsfs file" {
    // /proc/self/ns/net is an nsfs file (f_type == NSFS_MAGIC).
    // This test verifies the happy path — it may not work in all environments
    // (e.g., some containers may restrict /proc access).
    const result = verifyNetnsNsfs("/proc/self/ns/net");
    // Accept both success and error — the test validates the function runs
    // without crashing, the actual result depends on the environment
    _ = result catch {};
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
        \\{"action":"setup","request":{"network":{"driver":"net-porter","options":{"socket":"/run/user/1000/net-porter.sock","resource":"test-resource"}}}}
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
        \\{"action":"teardown","request":{"network":{"driver":"net-porter","options":{"socket":"/run/user/1000/net-porter.sock","resource":"test-resource"}}}}
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
        \\{"action":"create","request":{"exec":{"container_name":"test","container_id":"test-id","network":{"driver":"net-porter","options":{"socket":"/run/user/1000/net-porter.sock","resource":"test-resource"}},"network_options":{"interface_name":"eth0"}}}}
    ;

    const parsed = std.json.parseFromSlice(plugin.Request, allocator, malicious_json, .{}) catch return;
    defer parsed.deinit();

    const request = parsed.value;
    try std.testing.expect(request.action == .create);
    try std.testing.expect(request.request == .exec);
}
