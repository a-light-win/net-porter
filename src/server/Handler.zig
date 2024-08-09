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
    const allocator = self.arena.allocator();

    const client_info = try getClientInfo(&self.responser);
    log.debug(
        "Client connected with PID {d}, UID {d}, GID {d}",
        .{ client_info.pid, client_info.uid, client_info.gid },
    );

    const buf = stream.reader().readAllAlloc(
        allocator,
        plugin.max_request_size,
    ) catch |err| {
        self.responser.writeError("Failed to read request: {s}", .{@errorName(err)});
        return;
    };

    std.debug.print("{s}\n", .{buf});

    const parsed_request = json.parseFromSlice(
        plugin.Request,
        allocator,
        buf,
        .{},
    ) catch |err| {
        self.responser.writeError("Failed to parse request: {s}", .{@errorName(err)});
        return;
    };
    defer parsed_request.deinit();

    const request = parsed_request.value;
    try self.authClient(client_info, &request);

    if (request.netns) |netns| {
        const netns_file = std.fs.cwd().openFile(netns, .{}) catch |err| {
            self.responser.writeError("Failed to open netns file {s}: {s}", .{ netns, @errorName(err) });
            return;
        };
        defer netns_file.close();
    }

    switch (request.action) {
        .create => try self.handleCreate(request),
        // .setup => try self.handleSetup(request),
        // TODO: implement other actions
        else => {
            self.responser.writeError("Unsupported action: {s}", .{@tagName(request.action)});
        },
    }
}

fn handleCreate(self: *Handler, request: plugin.Request) !void {
    const cni = self.cni_manager.loadCni(request.resource) catch |err| {
        self.responser.writeError("Failed to load CNI: {s}", .{@errorName(err)});
        return;
    };
    _ = cni;

    self.responser.write(request.request);
}

fn handleSetup(self: *Handler, request: plugin.Request) !void {
    const cni = self.cni_manager.loadCni(request.resource) catch |err| {
        self.responser.writeError("Failed to load CNI: {s}", .{@errorName(err)});
        return;
    };

    _ = cni;
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
    if (!self.acl_manager.isAllowed(request.resource, client_info.uid, client_info.gid)) {
        const err = error.AccessDenied;
        self.responser.writeError(
            "Failed to access resource '{s}', error: {s}",
            .{
                request.resource,
                @errorName(err),
            },
        );
        return err;
    }
}
