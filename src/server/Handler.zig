const std = @import("std");
const config = @import("../config.zig");
const net = std.net;
const json = std.json;
const log = std.log.scoped(.server);
const plugin = @import("../plugin.zig");
const AclManager = @import("AclManager.zig");
const CniManager = @import("CniManager.zig");
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

    switch (request.action) {
        .create => try cni.create(tentative_allocator, request, &self.responser),
        .setup => try cni.setup(tentative_allocator, request, &self.responser),
        .teardown => try cni.teardown(tentative_allocator, request, &self.responser),
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
