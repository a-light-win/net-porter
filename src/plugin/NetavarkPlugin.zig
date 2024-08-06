const std = @import("std");
const json = std.json;
const DomainSocket = @import("../config.zig").DomainSocket;
const NetavarkPlugin = @This();

pub const name = "net-porter";
pub const version = "0.1.0";

pub const max_request_size = 16 * 1024;
pub const max_response_size = 16 * 1024;

const PluginAction = enum {
    create,
    setup,
    teardown,
};

const PluginInfo = struct {
    name: []const u8,
    version: []const u8,
    api_version: []const u8,
    description: []const u8,
};

const Network = struct {
    driver: []const u8,
    options: DriverOptions,
};

const DriverOptions = struct {
    net_porter_socket: []const u8,
    net_porter_resource: []const u8,
};

const NetworkPluginExec = struct {
    network: Network,
};

pub const Request = struct {
    action: PluginAction,
    resource: []const u8,
    request: []const u8,
};

allocator: std.mem.Allocator,
stream_in: *std.io.StreamSource,
stream_out: *std.io.StreamSource,

pub fn defaultNetavarkPlugin() NetavarkPlugin {
    return NetavarkPlugin{
        .allocator = std.heap.page_allocator,
        .stream_in = @constCast(&std.io.StreamSource{ .file = std.io.getStdIn() }),
        .stream_out = @constCast(&std.io.StreamSource{ .file = std.io.getStdOut() }),
    };
}

pub fn printInfo(self: *NetavarkPlugin) !void {
    try self.write(PluginInfo{
        .name = name,
        .version = version,
        .api_version = "1.0.0",
        .description = "A netavark plugin to create host network interface into the rootless container",
    });
}

fn write(self: *NetavarkPlugin, message: anytype) !void {
    try json.stringify(
        message,
        .{
            .whitespace = .indent_2,
            .emit_null_optional_fields = false,
        },
        self.stream_out.writer(),
    );
}

fn writeError(self: *NetavarkPlugin, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    const message = try std.fmt.bufPrint(&buf, fmt, args);
    try self.write(.{ .@"error" = message });
}

test "printInfo()" {
    const test_allocator = std.testing.allocator;
    var buffer: [1024]u8 = undefined;
    var source = std.io.StreamSource{ .buffer = std.io.fixedBufferStream(&buffer) };

    var plugin = NetavarkPlugin{
        .allocator = test_allocator,
        .stream_in = &source,
        .stream_out = &source,
    };
    try plugin.printInfo();

    const output = source.buffer.getWritten();
    try std.testing.expect(source.buffer.pos != 0);

    const parsed = try json.parseFromSlice(PluginInfo, test_allocator, output, .{});
    defer parsed.deinit();

    try std.testing.expectEqualSlices(u8, "net-porter", parsed.value.name);
}

pub fn create(self: *NetavarkPlugin) !void {
    const request = self.getRequest() catch |err| {
        try self.writeError("Read request failed with {s}", .{@errorName(err)});
        return;
    };
    defer self.allocator.free(request);

    const parsed = json.parseFromSlice(
        Network,
        self.allocator,
        request,
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        try self.writeError("Parse request failed with {s}", .{@errorName(err)});
        return;
    };
    defer parsed.deinit();

    const network = parsed.value;
    if (!self.validateNetwork(network)) {
        return;
    }

    try self.sendRequest(
        network.options.net_porter_socket,
        &Request{
            .action = PluginAction.create,
            .resource = network.options.net_porter_resource,
            .request = request,
        },
    );
}

pub fn setup(self: *NetavarkPlugin) !void {
    try self.exec(PluginAction.setup);
}

pub fn teardown(self: *NetavarkPlugin) !void {
    try self.exec(PluginAction.teardown);
}

fn exec(self: *NetavarkPlugin, action: PluginAction) !void {
    const request = self.getRequest() catch |err| {
        try self.writeError("Read request failed with {s}", .{@errorName(err)});
        return;
    };
    defer self.allocator.free(request);

    const parsed = json.parseFromSlice(
        NetworkPluginExec,
        self.allocator,
        request,
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        try self.writeError("Parse request failed with {s}", .{@errorName(err)});
        return;
    };
    defer parsed.deinit();

    const network = parsed.value.network;
    if (!self.validateNetwork(network)) {
        return;
    }

    try self.sendRequest(
        network.options.net_porter_socket,
        &Request{
            .action = action,
            .resource = network.options.net_porter_resource,
            .request = request,
        },
    );
}

fn validateNetwork(self: *NetavarkPlugin, network: Network) bool {
    if (!std.mem.eql(u8, name, network.driver)) {
        self.writeError("Expect driver name '{s}' but got '{s}'", .{ name, network.driver }) catch {};
        return false;
    }
    if (network.options.net_porter_socket.len == 0) {
        self.writeError("Missing net_porter_socket in network options", .{}) catch {};
        return false;
    }
    if (network.options.net_porter_resource.len == 0) {
        self.writeError("Missing net_porter_resource in network options", .{}) catch {};
        return false;
    }
    return true;
}

fn getRequest(self: *NetavarkPlugin) ![]const u8 {
    return self.stream_in.reader().readAllAlloc(self.allocator, max_request_size);
}

fn sendRequest(self: *NetavarkPlugin, socket_path: []const u8, request: *const Request) !void {
    const domain_socket = DomainSocket{
        .path = socket_path,
    };

    const stream = domain_socket.connect() catch |err| {
        try self.writeError("Failed to connect to domain socket {s}: {s}", .{ socket_path, @errorName(err) });
        return;
    };
    defer stream.close();

    json.stringify(
        request,
        .{
            .whitespace = .indent_2,
            .emit_null_optional_fields = false,
        },
        stream.writer(),
    ) catch |err| {
        try self.writeError("Failed to send request to domain socket {s}: {s}", .{ socket_path, @errorName(err) });
    };

    try std.posix.shutdown(stream.handle, .send);

    const buf = stream.reader().readAllAlloc(
        self.allocator,
        max_response_size,
    ) catch |err| {
        try self.writeError("Failed to read response from domain socket {s}: {s}", .{ socket_path, @errorName(err) });
        return;
    };

    _ = try self.stream_out.writer().write(buf);
}
