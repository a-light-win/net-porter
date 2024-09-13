const std = @import("std");
const json = std.json;
const DomainSocket = @import("../config.zig").DomainSocket;
const NetavarkPlugin = @This();

pub const name = "net-porter";
pub const version = "0.2.0";

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

pub const Network = struct {
    driver: []const u8,
    options: DriverOptions,
};

const DriverOptions = struct {
    net_porter_socket: [:0]const u8,
    net_porter_resource: []const u8,
};

const NetworkOptions = struct {
    interface_name: []const u8, // CNI_IFNAME
    static_ips: ?[]const []const u8 = null,
    static_mac: ?[]const u8 = null,
};

pub const NetworkPluginExec = struct {
    container_name: []const u8,
    container_id: []const u8, // CNI_CONTAINERID
    network: Network,
    network_options: NetworkOptions,
};

pub const NetAvarkRequest = union(enum) {
    network: Network,
    exec: NetworkPluginExec,
};

pub const Request = struct {
    action: PluginAction,
    request: NetAvarkRequest,
    // The network namespace path
    netns: ?[]const u8 = null,

    // Following fields are set by the server
    // The value set by the client will be ignored

    // The process ID of the caller
    process_id: ?std.posix.pid_t = null,
    // The user id of the caller
    user_id: ?std.posix.uid_t = null,
    raw_request: ?[]const u8 = null,

    pub fn resource(self: Request) []const u8 {
        return self.network().options.net_porter_resource;
    }

    pub fn network(self: Request) Network {
        return switch (self.request) {
            .network => |net| net,
            .exec => |net_exec| net_exec.network,
        };
    }

    pub fn requestExec(self: Request) NetworkPluginExec {
        return switch (self.request) {
            .network => unreachable,
            .exec => |net_exec| net_exec,
        };
    }
};

test "Request can stringify and parsed" {
    var buffer: [1024]u8 = undefined;
    var source = std.io.StreamSource{ .buffer = std.io.fixedBufferStream(&buffer) };

    const request = Request{
        .action = PluginAction.setup,
        .request = NetAvarkRequest{
            .exec = NetworkPluginExec{
                .container_name = "test-container",
                .container_id = "test-container-id",
                .network = Network{
                    .driver = "net-porter",
                    .options = DriverOptions{
                        .net_porter_socket = "test-socket",
                        .net_porter_resource = "test-resource",
                    },
                },
                .network_options = NetworkOptions{
                    .interface_name = "test-interface",
                },
            },
        },
    };
    try json.stringify(request, .{ .whitespace = .indent_2 }, source.writer());
    // std.debug.print("{s}\n", .{buffer[0..source.buffer.pos]});
    try std.testing.expect(source.buffer.pos != 0);

    const parsed = try json.parseFromSlice(Request, std.testing.allocator, source.buffer.getWritten(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualSlices(u8, "test-resource", parsed.value.resource());
    try std.testing.expectEqualSlices(u8, "test-container", parsed.value.requestExec().container_name);
}

pub const Response = struct {
    dns_search_domains: ?[]const []const u8 = null,
    dns_server_ips: ?[]const []const u8 = null,
    // should be ObjectMap of interface
    interfaces: json.ArrayHashMap(Interface),
};

pub const Interface = struct {
    mac_address: []const u8,
    subnets: ?[]const Subnet = null,
};

pub const Subnet = struct {
    ipnet: []const u8,
    gateway: ?[]const u8 = null,
};

test "Response can stringify and parsed" {
    const allocator = std.testing.allocator;

    var buffer: [1024]u8 = undefined;
    var source = std.io.StreamSource{ .buffer = std.io.fixedBufferStream(&buffer) };

    var response = Response{
        .dns_search_domains = &[_][]const u8{"test-domain"},
        .interfaces = json.ArrayHashMap(Interface){},
    };
    defer response.interfaces.deinit(allocator);

    try response.interfaces.map.put(allocator, "eth0", .{
        .mac_address = "aa:bb:cc:dd:ee:ff",
        .subnets = &[_]Subnet{
            .{ .ipnet = "192.168.2.3/24" },
        },
    });

    try json.stringify(
        response,
        .{ .whitespace = .indent_2 },
        source.writer(),
    );
    try std.testing.expect(source.buffer.pos != 0);

    const parsed = try json.parseFromSlice(
        Response,
        allocator,
        source.buffer.getWritten(),
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expectEqualSlices(
        u8,
        "test-domain",
        parsed.value.dns_search_domains.?[0],
    );
    try std.testing.expectEqualSlices(
        u8,
        "192.168.2.3/24",
        parsed.value.interfaces.map.get("eth0").?.subnets.?[0].ipnet,
    );
}

pub const ErrorResponse = struct {
    @"error": ?[]const u8 = null,
};

allocator: std.mem.Allocator,
stream_in: *std.io.StreamSource,
stream_out: *std.io.StreamSource,
namespace_path: []const u8 = undefined,

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

    const parsed = try json.parseFromSlice(
        PluginInfo,
        test_allocator,
        output,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    try std.testing.expectEqualSlices(u8, "net-porter", parsed.value.name);
}

pub fn create(self: *NetavarkPlugin) !void {
    const request = self.getRequest() catch |err| {
        try self.writeError("Read request failed with {s}", .{@errorName(err)});
        return error.AlreadyHandled;
    };
    defer self.allocator.free(request);

    const parsed_network = json.parseFromSlice(
        Network,
        self.allocator,
        request,
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        try self.writeError("Parse request failed with {s}", .{@errorName(err)});
        return error.AlreadyHandled;
    };
    defer parsed_network.deinit();

    const network = parsed_network.value;
    if (!self.validateNetwork(network)) {
        return error.AlreadyHandled;
    }

    try self.sendRequest(
        network.options.net_porter_socket,
        &Request{
            .action = PluginAction.create,
            .request = .{ .network = parsed_network.value },
            .raw_request = request,
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
        return error.AlreadyHandled;
    };
    defer self.allocator.free(request);

    const parsed = json.parseFromSlice(
        NetworkPluginExec,
        self.allocator,
        request,
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        try self.writeError("Parse request failed with {s}", .{@errorName(err)});
        return error.AlreadyHandled;
    };
    defer parsed.deinit();

    const network = parsed.value.network;

    if (!self.validateNetwork(network)) {
        return error.AlreadyHandled;
    }

    try self.sendRequest(
        network.options.net_porter_socket,
        &Request{
            .action = action,
            .request = .{ .exec = parsed.value },
            .netns = self.namespace_path,
            .raw_request = request,
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

fn sendRequest(self: *NetavarkPlugin, socket_path: [:0]const u8, request: *const Request) !void {
    const domain_socket = DomainSocket{
        .path = socket_path,
    };

    const stream = domain_socket.connect() catch |err| {
        try self.writeError("Failed to connect to domain socket {s}: {s}", .{ socket_path, @errorName(err) });
        return error.AlreadyHandled;
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
        return error.AlreadyHandled;
    };

    try std.posix.shutdown(stream.handle, .send);

    const buf = stream.reader().readAllAlloc(
        self.allocator,
        max_response_size,
    ) catch |err| {
        try self.writeError("Failed to read response from domain socket {s}: {s}", .{ socket_path, @errorName(err) });
        return error.AlreadyHandled;
    };

    _ = try self.stream_out.writer().write(buf);

    const parsed_response = json.parseFromSlice(
        ErrorResponse,
        self.allocator,
        buf,
        .{ .ignore_unknown_fields = true },
    ) catch {
        return;
    };
    defer parsed_response.deinit();

    if (parsed_response.value.@"error") |_| {
        return error.AlreadyHandled;
    }
}
