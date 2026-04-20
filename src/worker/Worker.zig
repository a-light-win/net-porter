//! Per-UID worker daemon — runs in the host namespace.
//!
//! The worker is spawned by the main server process via:
//!   net-porter worker --uid <UID> --username <name> --catatonit-pid <PID> --config <PATH>
//!
//! Lifecycle:
//!   1. Load config, ACL, CNI configs (host namespace — paths accessible)
//!   2. Create listening socket at /run/user/<uid>/net-porter.sock
//!   3. Init DHCP manager
//!   4. Event loop: accept connections, spawn handler threads
//!   5. ACL hot-reload via inotify (separate watch thread)
//!
//! Network namespace resolution:
//!   The worker does NOT enter catatonit's mount namespace. Instead, CNI_NETNS
//!   paths are resolved via /proc/<catatonit_pid>/root/<path>, which traverses
//!   into catatonit's mount namespace to access the nsfs mount points.
//!
//!   Security: see .opencode/context/security/netns-resolution-security.md
//!
//! Security:
//!   - Socket ownership verified via fchownat to target UID
//!   - Per-request catatonit process verification (UID + comm check)
//!   - Per-request netns nsfs verification (statx AT_SYMLINK_NOFOLLOW + device 0:4)

const std = @import("std");
const config_mod = @import("../config.zig");
const version = @import("build_options").version;
const AclManager = @import("AclManager.zig");
const CniManager = @import("../cni/CniManager.zig");
const DhcpService = @import("../cni/DhcpService.zig");
const Handler = @import("Handler.zig");
const ArenaAllocator = @import("../utils/ArenaAllocator.zig");
const Responser = @import("../common/Responser.zig");
const DomainSocket = config_mod.DomainSocket;
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
dhcp_service: DhcpService,
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

    // 1. Load config
    var managed_config = config_mod.ManagedConfig.load(io, page_alloc, opts.config_path) catch |e| {
        log.err("Failed to read config file: {s}, error: {s}", .{ opts.config_path orelse "", @errorName(e) });
        return e;
    };
    const conf = managed_config.config;
    errdefer managed_config.deinit();

    // 2. Load ACL for this user (loads <username>.json + groups)
    var acl_manager = AclManager.init(page_alloc, io, conf.acl_dir, username, uid);
    acl_manager.load();

    // 3. Load CNI configs
    var cni_manager = CniManager.init(io, page_alloc, conf) catch |e| {
        log.err("Failed to initialize CNI manager: {s}", .{@errorName(e)});
        return e;
    };
    errdefer cni_manager.deinit();

    // 4. Create listening socket
    const socket_path = DomainSocket.pathForUid(page_alloc, uid) catch |e| {
        log.err("Failed to allocate socket path for uid={d}: {s}", .{ uid, @errorName(e) });
        return e;
    };
    errdefer page_alloc.free(socket_path);

    const server = DomainSocket.listen(io, socket_path, uid) catch |e| {
        log.err("Failed to listen on {s}: {s}", .{ socket_path, @errorName(e) });
        return e;
    };

    // 5. Init DHCP service
    const dhcp_service = DhcpService.init(io, page_alloc, uid, conf.cni_plugin_dir) catch |e| {
        log.err("Failed to initialize DHCP service: {s}", .{@errorName(e)});
        return e;
    };
    errdefer dhcp_service.deinit();

    return .{
        .config = conf,
        .io = io,
        .uid = uid,
        .username = username,
        .catatonit_pid = catatonit_pid,
        .acl_manager = acl_manager,
        .cni_manager = cni_manager,
        .dhcp_service = dhcp_service,
        .server = server,
        .socket_path = socket_path,
        .managed_config = managed_config,
    };
}

pub fn deinit(self: *Worker) void {
    log.info("Worker shutting down for uid={d}", .{self.uid});

    // Stop DHCP service first
    self.dhcp_service.deinit();

    // Close server socket and remove socket file
    self.server.deinit(self.io);
    std.Io.Dir.cwd().deleteFile(self.io, self.socket_path) catch {};

    std.heap.page_allocator.free(self.socket_path);
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

        const conn = try std.heap.page_allocator.create(struct { stream: std.Io.net.Stream });
        conn.* = .{ .stream = conn_stream };

        var handler = Handler{
            .io = io,
            .arena = try ArenaAllocator.init(std.heap.page_allocator),
            .acl_manager = &self.acl_manager,
            .cni_manager = &self.cni_manager,
            .dhcp_service = &self.dhcp_service,
            .config = &self.config,
            .catatonit_pid = self.catatonit_pid,
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
            std.heap.page_allocator.destroy(conn);
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
