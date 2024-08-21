const std = @import("std");
const config = @import("../config.zig");
const net = std.net;
const json = std.json;
const log = std.log.scoped(.server);
const plugin = @import("../plugin.zig");
const AclManager = @import("AclManager.zig");
const CniManager = @import("CniManager.zig");
const Cni = @import("Cni.zig");
const Responser = @import("Responser.zig");
const ArenaAllocator = @import("../ArenaAllocator.zig");
const Handler = @This();

const ClientInfo = extern struct {
    pid: std.posix.pid_t,
    uid: std.posix.uid_t,
    gid: std.posix.gid_t,
};

arena: ArenaAllocator,
config: *config.Config,
acl_manager: *AclManager,
cni_manager: *CniManager,
connection: std.net.Server.Connection,
responser: Responser,

pub fn deinit(self: *Handler) void {
    self.connection.stream.close();

    self.arena.deinit();
}

pub fn handle(self: *Handler) !void {
    var stream = self.connection.stream;

    var arena = try ArenaAllocator.init(self.arena.childAllocator());
    defer arena.deinit();
    const tentative_allocator = arena.allocator();

    const client_info = try getClientInfo(&self.responser);
    log.debug(
        "Client connected with PID {d}, UID {d}, GID {d}",
        .{ client_info.pid, client_info.uid, client_info.gid },
    );

    const buf = stream.reader().readAllAlloc(
        tentative_allocator,
        plugin.max_request_size,
    ) catch |err| {
        self.responser.writeError("Failed to read request: {s}", .{@errorName(err)});
        return;
    };

    std.debug.print("{s}\n", .{buf});

    const parsed_request = json.parseFromSlice(
        plugin.Request,
        tentative_allocator,
        buf,
        .{},
    ) catch |err| {
        self.responser.writeError("Failed to parse request: {s}", .{@errorName(err)});
        return;
    };
    defer parsed_request.deinit();

    var request = parsed_request.value;
    request.process_id = client_info.pid;
    request.user_id = client_info.uid;

    try self.authClient(client_info, &request);
    try self.checkNetns(client_info, &request);

    const cni = self.cni_manager.loadCni(request.resource()) catch |err| {
        self.responser.writeError("Failed to load CNI: {s}", .{@errorName(err)});
        return;
    };

    self.execAction(tentative_allocator, cni, request) catch |err| {
        if (!self.responser.done) {
            self.responser.writeError("Failed to execute action: {s}", .{@errorName(err)});
        }
    };

    if (self.responser.is_error) {
        self.dumpEnv(tentative_allocator, request);
    }
}

fn execAction(
    self: *Handler,
    allocator: std.mem.Allocator,
    cni: *Cni,
    request: plugin.Request,
) !void {
    switch (request.action) {
        .create => try cni.create(allocator, request, &self.responser),
        .setup => try cni.setup(allocator, request, &self.responser),
        .teardown => try cni.teardown(allocator, request, &self.responser),
    }
}

fn getClientInfo(responser: *Responser) std.posix.UnexpectedError!ClientInfo {
    // Get peer credentials
    var client_info: ClientInfo = undefined;
    var info_len: std.posix.socklen_t = @sizeOf(ClientInfo);
    const fd = responser.stream.handle;
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
    if (!self.acl_manager.isAllowed(request.resource(), client_info.uid, client_info.gid)) {
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
    if (request.netns) |netns| {
        const netns_file = std.fs.cwd().openFile(netns, .{}) catch |err| {
            self.responser.writeError("Failed to open netns file {s}: {s}", .{ netns, @errorName(err) });
            return err;
        };
        defer netns_file.close();
        const stat = std.posix.fstat(netns_file.handle) catch |err| {
            self.responser.writeError("Failed to stat netns file {s}: {s}", .{ netns, @errorName(err) });
            return err;
        };

        if (stat.uid != client_info.uid) {
            self.responser.writeError("Netns file {s} doesn't belong to client", .{netns});
            return error.AccessDenied;
        }
    }
}

const dump_env_sh = @embedFile("files/dump_env.sh");

fn dumpEnv(self: Handler, allocator: std.mem.Allocator, request: plugin.Request) void {
    const env_log = std.log.scoped(.dump_env);

    const dump_env = self.config.log.dump_env;
    if (!dump_env.enabled) {
        return;
    }

    switch (request.request) {
        .network => return,
        .exec => {},
    }

    // Ensure the path of dump env exist
    std.fs.cwd().makePath(dump_env.path) catch |err| {
        env_log.warn(
            "Failed to create dump env path {s}: {s}",
            .{ dump_env.path, @errorName(err) },
        );
    };

    var child = std.process.Child.init(
        &[_][]const u8{"sh"},
        allocator,
    );
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();
    child.env_map = &env_map;

    env_map.put(
        "CLIENT_PID",
        std.fmt.allocPrintZ(
            allocator,
            "{d}",
            .{request.process_id.?},
        ) catch unreachable,
    ) catch unreachable;

    child.spawn() catch |err| {
        env_log.warn("Failed to spawn child process: {s}", .{@errorName(err)});
        return;
    };

    if (child.stdin) |stdin| {
        stdin.writeAll(dump_env_sh) catch |err| {
            env_log.warn("Failed to prepare the dump script: {s}", .{@errorName(err)});
        };
        stdin.close();
        child.stdin = null;
    }

    const exec_request = request.requestExec();
    const file_path = std.fmt.allocPrintZ(
        allocator,
        "{s}/{s}-{s}.log",
        .{
            dump_env.path,
            exec_request.container_name,
            exec_request.container_id,
        },
    ) catch unreachable;
    defer allocator.free(file_path);
    env_log.info("Dumping env to {s}", .{file_path});

    const file = std.fs.cwd().createFile(file_path, .{}) catch |err| {
        env_log.warn("Failed to create dump env file {s}: {s}", .{ file_path, @errorName(err) });
        return;
    };
    defer file.close();
    file.chmod(0o640) catch |err| {
        env_log.warn("Failed to chmod the file {s}: {s}", .{ file_path, @errorName(err) });
    };

    const dump_stdout = std.Thread.spawn(.{}, dumpToFile, .{ allocator, child.stdout.?, file }) catch |err| {
        env_log.warn("Failed to spawn thread: {s}", .{@errorName(err)});
        return;
    };
    defer dump_stdout.join();

    const dump_stderr = std.Thread.spawn(.{}, dumpToFile, .{ allocator, child.stderr.?, file }) catch |err| {
        env_log.warn("Failed to spawn thread: {s}", .{@errorName(err)});
        return;
    };
    defer dump_stderr.join();

    _ = child.wait() catch |err| {
        env_log.warn("Failed to wait child process: {s}", .{@errorName(err)});
    };
}

fn dumpToFile(allocator: std.mem.Allocator, in: std.fs.File, out: std.fs.File) void {
    const env_log = std.log.scoped(.dump_env);
    const Fifo = std.fifo.LinearFifo(u8, .Dynamic);

    var fifo: Fifo = Fifo.init(allocator);
    fifo.ensureTotalCapacity(4096) catch unreachable;
    defer fifo.deinit();

    fifo.pump(in.reader(), out.writer()) catch |err| {
        env_log.warn("Failed to dump env: {s}", .{@errorName(err)});
    };
}
