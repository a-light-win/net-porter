//! Per-UID worker daemon — runs inside the container's mount namespace.
//!
//! The worker is spawned by the main server process via:
//!   net-porter worker --uid <UID> --username <name> --catatonit-pid <PID> --config <PATH>
//!
//! Lifecycle:
//!   1. Load config, ACL, CNI configs (host namespace — paths accessible)
//!   2. Create listening socket at /run/user/<uid>/net-porter.sock (host namespace)
//!   3. Open mount namespace fd + config dir fds (host namespace)
//!   4. setns(catatonit mount ns) → unshare → make-rslave (enter correct namespace)
//!   5. Bind mount config dirs read-only (security: prevent tampering)
//!   6. Event loop: accept connections, spawn handler threads
//!   7. ACL hot-reload via inotify (separate watch thread)
//!
//! Security:
//!   - CNI plugin dir is bind-mounted read-only from host (prevents binary replacement)
//!   - ACL dir is bind-mounted read-only from host (prevents hot-reload privilege escalation)
//!   - Worker runs in an independent mount namespace (rslave — no reverse pollution)
//!   - Socket ownership verified via fchownat to target UID
//!   - No nsenter executed — the worker IS in the correct namespace

const std = @import("std");
const config_mod = @import("../config.zig");
const version = @import("build_options").version;
const AclManager = @import("AclManager.zig");
const CniManager = @import("../cni/CniManager.zig");
const DhcpManager = @import("../cni/DhcpManager.zig");
const Handler = @import("Handler.zig");
const ArenaAllocator = @import("../utils/ArenaAllocator.zig");
const Responser = @import("../plugin/Responser.zig");
const DomainSocket = config_mod.DomainSocket;
const linux = std.os.linux;
const Worker = @This();

const log = std.log.scoped(.worker);

pub const Opts = struct {
    io: ?std.Io = null,
    uid: ?u32 = null,
    username: ?[]const u8 = null,
    catatonit_pid: ?std.posix.pid_t = null,
    config_path: ?[]const u8 = null,
};

const max_concurrent_handlers: usize = 64;

config: config_mod.Config,
io: std.Io,
uid: u32,
username: []const u8,
catatonit_pid: std.posix.pid_t,
acl_manager: AclManager,
cni_manager: CniManager,
dhcp_manager: DhcpManager,
server: std.Io.net.Server,
socket_path: [:0]const u8,
managed_config: config_mod.ManagedConfig,
active_handlers: std.atomic.Value(usize) = .init(0),

/// Initialize the worker. Performs all setup in the correct order:
/// load config → create socket → namespace setup → init subsystems.
pub fn new(opts: Opts) !Worker {
    log.info("Worker initializing: uid={?d} username={s} catatonit_pid={?d} config={s}", .{ opts.uid, opts.username orelse "(null)", opts.catatonit_pid, opts.config_path orelse "(default)" });
    const io = opts.io orelse return error.IoNotInitialized;
    const uid = opts.uid orelse return error.MissingUid;
    const username = opts.username orelse return error.MissingUsername;
    const catatonit_pid = opts.catatonit_pid orelse return error.MissingCatatonitPid;
    const page_alloc = std.heap.page_allocator;

    // 1. Load config (host namespace — paths accessible)
    var managed_config = config_mod.ManagedConfig.load(io, page_alloc, opts.config_path) catch |e| {
        log.err("Failed to read config file: {s}, error: {s}", .{ opts.config_path orelse "", @errorName(e) });
        return e;
    };
    const conf = managed_config.config;
    errdefer managed_config.deinit();

    // 2. Load ACL for this user (worker-side: loads <username>.json + groups)
    var acl_manager = AclManager.init(page_alloc, io, conf.acl_dir, username, uid);
    acl_manager.load();

    // 3. Load CNI configs (host namespace — cni_dir accessible)
    var cni_manager = CniManager.init(io, page_alloc, conf) catch |e| {
        log.err("Failed to initialize CNI manager: {s}", .{@errorName(e)});
        return e;
    };
    errdefer cni_manager.deinit();

    // 4. Create listening socket (host namespace — /run/user/<uid>/ accessible)
    const socket_path = DomainSocket.pathForUid(page_alloc, uid) catch |e| {
        log.err("Failed to allocate socket path for uid={d}: {s}", .{ uid, @errorName(e) });
        return e;
    };
    errdefer page_alloc.free(socket_path);

    const server = DomainSocket.listen(io, socket_path, uid) catch |e| {
        log.err("Failed to listen on {s}: {s}", .{ socket_path, @errorName(e) });
        return e;
    };

    // 5. Setup namespace (setns → unshare → rslave → bind mount config dirs read-only)
    try setupNamespace(catatonit_pid, .{
        .cni_plugin_dir = conf.cni_plugin_dir,
        .acl_dir = conf.acl_dir,
    });

    // 6. Init DHCP manager (after namespace setup — CNI dir is bind-mounted)
    const dhcp_manager = DhcpManager.init(io, page_alloc, conf.cni_plugin_dir);

    return .{
        .config = conf,
        .io = io,
        .uid = uid,
        .username = username,
        .catatonit_pid = catatonit_pid,
        .acl_manager = acl_manager,
        .cni_manager = cni_manager,
        .dhcp_manager = dhcp_manager,
        .server = server,
        .socket_path = socket_path,
        .managed_config = managed_config,
    };
}

pub fn deinit(self: *Worker) void {
    log.info("Worker shutting down for uid={d}", .{self.uid});

    // Stop DHCP services first
    self.dhcp_manager.deinit();

    // Close server socket and remove socket file
    self.server.deinit(self.io);
    std.Io.Dir.cwd().deleteFile(self.io, self.socket_path) catch {};

    self.pageAllocator().free(self.socket_path);
    self.cni_manager.deinit();
    self.acl_manager.deinit();
    self.managed_config.deinit();
}

pub fn run(self: *Worker) !void {
    const io = self.io;
    log.info("net-porter worker {s} started for uid={d} (username={s}, catatonit_pid={d})", .{ version, self.uid, self.username, self.catatonit_pid });
    const log_response = self.config.log.logEnabled(.debug, .traffic);

    // Start ACL inotify watch thread (daemon thread, outlives worker)
    if (self.acl_manager.getInotifyFd()) |_| {
        _ = std.Thread.spawn(.{}, aclWatchLoop, .{self}) catch |err| {
            log.warn("Failed to start ACL watch thread: {s} (ACL hot-reload disabled)", .{@errorName(err)});
        };
    }

    while (true) {
        var conn_stream = self.server.accept(io) catch |err| {
            log.err("Failed to accept connection: {s}", .{@errorName(err)});
            continue;
        };

        // Limit concurrent handlers to prevent resource exhaustion
        if (self.active_handlers.fetchAdd(1, .acquire) >= max_concurrent_handlers) {
            _ = self.active_handlers.fetchSub(1, .release);
            log.warn("Too many concurrent connections (max={d}), dropping", .{max_concurrent_handlers});
            conn_stream.close(io);
            continue;
        }

        const conn = try self.pageAllocator().create(struct { stream: std.Io.net.Stream });
        conn.* = .{ .stream = conn_stream };

        var handler = Handler{
            .io = io,
            .arena = try ArenaAllocator.init(self.pageAllocator()),
            .acl_manager = &self.acl_manager,
            .cni_manager = &self.cni_manager,
            .dhcp_manager = &self.dhcp_manager,
            .config = &self.config,
            .connection = .{ .stream = conn.stream },
            .responser = Responser{
                .io = io,
                .stream = &conn.stream,
                .log_response = log_response,
            },
        };

        _ = std.Thread.spawn(.{}, handleRequests, .{ &handler, &self.active_handlers }) catch |e| {
            _ = self.active_handlers.fetchSub(1, .release);
            log.warn("Failed to spawn handler thread: {s}", .{@errorName(e)});
            handler.arena.deinit();
            self.pageAllocator().destroy(conn);
            continue;
        };
    }
}

/// Background thread: watches ACL directory for changes and triggers reload.
fn aclWatchLoop(self: *Worker) void {
    const fd = self.acl_manager.getInotifyFd() orelse return;
    var event_buf: [4096]u8 = undefined;

    var poll_fds = [1]std.posix.pollfd{
        .{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };

    log.info("ACL watch thread started for uid={d}", .{self.uid});

    while (true) {
        const n = std.posix.poll(&poll_fds, -1) catch continue;
        if (n == 0) continue;

        if (self.acl_manager.processInotifyEvents(&event_buf)) {
            self.acl_manager.reload();
        }
    }
}

fn handleRequests(handler: *Handler, active_handlers: *std.atomic.Value(usize)) !void {
    defer {
        handler.deinit();
        _ = active_handlers.fetchSub(1, .release);
    }
    try handler.handle();
}

fn pageAllocator(self: *Worker) std.mem.Allocator {
    _ = self;
    return std.heap.page_allocator;
}

// ─── Namespace Setup ──────────────────────────────────────────────────

/// Directories to bind-mount into the worker's namespace.
const NamespaceDirs = struct {
    cni_plugin_dir: []const u8,
    acl_dir: []const u8,
};

/// Enter the container's mount namespace and set up a safe working environment.
///
/// Steps:
///   1. Open catatonit's mount namespace fd (before setns)
///   2. Open host directory fds for bind-mount targets (before setns)
///   3. setns into catatonit's mount namespace
///   4. unshare(CLONE_NEWNS) to create an independent copy
///   5. mount --make-rslave / for one-way propagation
///   6. Bind mount host config dirs read-only (anti-privilege-escalation)
fn setupNamespace(catatonit_pid: std.posix.pid_t, dirs: NamespaceDirs) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // 1. Open catatonit's mount namespace fd
    const mnt_ns_path = try std.fmt.allocPrintSentinel(arena_alloc, "/proc/{d}/ns/mnt", .{catatonit_pid}, 0);
    const mnt_ns_fd_rc = linux.open(mnt_ns_path, .{ .ACCMODE = .RDONLY }, 0);
    if (std.posix.errno(mnt_ns_fd_rc) != .SUCCESS) {
        log.err("Failed to open mount namespace fd for pid={d}: {s}", .{ catatonit_pid, @tagName(std.posix.errno(mnt_ns_fd_rc)) });
        return error.NamespaceSetupFailed;
    }
    const mnt_ns_fd: std.posix.fd_t = @intCast(mnt_ns_fd_rc);
    defer _ = linux.close(mnt_ns_fd);

    // 2. Open host directory fds before namespace change.
    //    /proc/self/fd/<fd> magic symlinks resolve to the host inode
    //    regardless of current namespace — this is how we carry host
    //    directories across the namespace boundary.

    // CNI plugin dir — mandatory (worker executes binaries from here)
    const cni_plugin_fd = openDirFd(arena_alloc, dirs.cni_plugin_dir) catch |err| {
        log.err("Failed to open CNI plugin dir '{s}': {s}", .{ dirs.cni_plugin_dir, @errorName(err) });
        return error.NamespaceSetupFailed;
    };
    defer _ = linux.close(cni_plugin_fd);

    // ACL dir — mandatory (hot-reload reads from this path; without read-only
    // bind mount, a container user could write malicious ACL files that the
    // inotify watch thread would pick up and reload — privilege escalation).
    const acl_fd = openDirFd(arena_alloc, dirs.acl_dir) catch |err| {
        log.err("Failed to open ACL dir '{s}': {s}", .{ dirs.acl_dir, @errorName(err) });
        return error.NamespaceSetupFailed;
    };
    defer _ = linux.close(acl_fd);

    // 3. setns — enter catatonit's mount namespace
    const setns_rc = linux.setns(mnt_ns_fd, linux.CLONE.NEWNS);
    if (std.posix.errno(setns_rc) != .SUCCESS) {
        log.err("setns(CLONE_NEWNS) failed: {s}", .{@tagName(std.posix.errno(setns_rc))});
        return error.NamespaceSetupFailed;
    }
    log.info("Entered catatonit mount namespace (pid={d})", .{catatonit_pid});

    // 4. unshare — create independent mount namespace copy
    const unshare_rc = linux.unshare(linux.CLONE.NEWNS);
    if (std.posix.errno(unshare_rc) != .SUCCESS) {
        log.err("unshare(CLONE_NEWNS) failed: {s}", .{@tagName(std.posix.errno(unshare_rc))});
        return error.NamespaceSetupFailed;
    }

    // 5. mount --make-rslave / — one-way propagation (host → child only)
    const slave_rc = linux.mount("", "/", "", linux.MS.SLAVE | linux.MS.REC, 0);
    if (std.posix.errno(slave_rc) != .SUCCESS) {
        log.err("mount --make-rslave failed: {s}", .{@tagName(std.posix.errno(slave_rc))});
        return error.NamespaceSetupFailed;
    }

    // 6. Bind mount host directories read-only into this namespace.
    //
    //    SECURITY: Both directories MUST be mounted read-only to prevent
    //    privilege escalation by the container user:
    //      - CNI plugin dir: prevents replacing binaries executed as root
    //      - ACL dir: prevents writing malicious ACL files that hot-reload
    //        would pick up and apply (direct privilege escalation)
    //
    //    Both failures are fatal — the worker refuses to start without
    //    these security guarantees.

    try bindMountReadOnly(arena_alloc, cni_plugin_fd, dirs.cni_plugin_dir, "CNI plugin");
    try bindMountReadOnly(arena_alloc, acl_fd, dirs.acl_dir, "ACL");

    log.info("Namespace setup complete for catatonit_pid={d}", .{catatonit_pid});
}

/// Open a directory fd by path. Returns the raw fd or an error.
fn openDirFd(arena_alloc: std.mem.Allocator, path: []const u8) !std.posix.fd_t {
    const path_z = try arena_alloc.allocSentinel(u8, path.len, 0);
    @memcpy(path_z[0..path.len], path);
    const rc = linux.open(path_z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (std.posix.errno(rc) != .SUCCESS) return error.DirOpenFailed;
    return @intCast(rc);
}

/// Bind mount a host directory read-only into the current namespace.
/// `host_dir_fd` must have been opened before the namespace change.
/// `mount_point` is the path where the directory will appear (same as host path).
/// `label` is used for log messages.
fn bindMountReadOnly(arena_alloc: std.mem.Allocator, host_dir_fd: std.posix.fd_t, mount_point: []const u8, label: []const u8) !void {
    // Create mount point directory (ignore errors — may already exist)
    const mnt_z = try arena_alloc.allocSentinel(u8, mount_point.len, 0);
    @memcpy(mnt_z[0..mount_point.len], mount_point);

    // Ensure parent directory exists
    if (std.mem.lastIndexOf(u8, mount_point, "/")) |last_slash| {
        if (last_slash > 0) {
            const parent = mount_point[0..last_slash];
            const parent_z = try arena_alloc.allocSentinel(u8, parent.len, 0);
            @memcpy(parent_z[0..parent.len], parent);
            _ = linux.mkdir(parent_z, 0o755); // ignore error
        }
    }
    _ = linux.mkdir(mnt_z, 0o755); // ignore error — may already exist

    // Source: /proc/self/fd/<host_dir_fd> — resolves to the host directory
    // regardless of current mount namespace.
    const fd_path = try std.fmt.allocPrintSentinel(arena_alloc, "/proc/self/fd/{d}", .{host_dir_fd}, 0);

    // Bind mount
    const bind_rc = linux.mount(fd_path, mnt_z, "", linux.MS.BIND, 0);
    if (std.posix.errno(bind_rc) != .SUCCESS) {
        log.warn("{s} dir bind mount failed: {s}", .{ label, @tagName(std.posix.errno(bind_rc)) });
        return error.BindMountFailed;
    }

    // Remount read-only
    const ro_rc = linux.mount(mnt_z, mnt_z, "", linux.MS.BIND | linux.MS.REMOUNT | linux.MS.RDONLY, 0);
    if (std.posix.errno(ro_rc) != .SUCCESS) {
        log.warn("{s} dir read-only remount failed: {s}", .{ label, @tagName(std.posix.errno(ro_rc)) });
        // Attempt to clean up the read-write mount
        _ = linux.umount2(mnt_z, 0);
        return error.BindMountFailed;
    }

    log.info("Bind mounted {s} dir read-only: {s}", .{ label, mount_point });
}
