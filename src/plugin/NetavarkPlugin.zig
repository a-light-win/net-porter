const std = @import("std");
const json = std.json;
const config_mod = @import("../config.zig");
const DomainSocket = config_mod.DomainSocket;
const log = std.log.scoped(.plugin);
const NetavarkPlugin = @This();

pub const name = "net-porter";
pub const version = @import("build_options").version;

pub const max_request_size = 16 * 1024;
pub const max_response_size = 16 * 1024;

const stringify_options = json.Stringify.Options{
    .whitespace = .indent_2,
    .emit_null_optional_fields = false,
};

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
    socket: ?[:0]const u8 = null,
    resource: ?[]const u8 = null,

    /// Deprecated: use `socket` instead.
    net_porter_socket: ?[:0]const u8 = null,
    /// Deprecated: use `resource` instead.
    net_porter_resource: ?[]const u8 = null,

    pub fn resolveSocket(self: DriverOptions) error{MissingSocket}![:0]const u8 {
        if (self.socket) |s| return s;
        if (self.net_porter_socket) |s| {
            log.warn("net_porter_socket is deprecated, use socket instead", .{});
            return s;
        }
        return error.MissingSocket;
    }

    pub fn resolveResource(self: DriverOptions) ![]const u8 {
        if (self.resource) |r| return r;
        if (self.net_porter_resource) |r| {
            log.warn("net_porter_resource is deprecated, use resource instead", .{});
            return r;
        }
        return error.MissingResource;
    }
};

test "DriverOptions.resolveSocket returns explicit socket" {
    const opts = DriverOptions{ .socket = "/custom/path.sock" };
    const result = try opts.resolveSocket();
    try std.testing.expectEqualStrings("/custom/path.sock", result);
}

test "DriverOptions.resolveSocket falls back to deprecated net_porter_socket" {
    const opts = DriverOptions{ .net_porter_socket = "/deprecated/path.sock" };
    const result = try opts.resolveSocket();
    try std.testing.expectEqualStrings("/deprecated/path.sock", result);
}

test "DriverOptions.resolveSocket prefers new socket over deprecated" {
    const opts = DriverOptions{ .socket = "/new.sock", .net_porter_socket = "/old.sock" };
    const result = try opts.resolveSocket();
    try std.testing.expectEqualStrings("/new.sock", result);
}

test "DriverOptions.resolveSocket returns error when neither set" {
    const opts = DriverOptions{};
    try std.testing.expectError(error.MissingSocket, opts.resolveSocket());
}

test "DriverOptions.resolveResource returns explicit resource" {
    const opts = DriverOptions{ .resource = "my-resource" };
    const result = try opts.resolveResource();
    try std.testing.expectEqualStrings("my-resource", result);
}

test "DriverOptions.resolveResource falls back to deprecated net_porter_resource" {
    const opts = DriverOptions{ .net_porter_resource = "old-resource" };
    const result = try opts.resolveResource();
    try std.testing.expectEqualStrings("old-resource", result);
}

test "DriverOptions.resolveResource prefers new resource over deprecated" {
    const opts = DriverOptions{ .resource = "new-res", .net_porter_resource = "old-res" };
    const result = try opts.resolveResource();
    try std.testing.expectEqualStrings("new-res", result);
}

test "DriverOptions.resolveResource returns error when neither set" {
    const opts = DriverOptions{};
    try std.testing.expectError(error.MissingResource, opts.resolveResource());
}

test "DriverOptions parses new field names from JSON" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{"driver":"net-porter","options":{"socket":"/run/user/1000/net-porter.sock","resource":"test-res"}}
    ;
    const parsed = try json.parseFromSlice(
        struct { driver: []const u8, options: DriverOptions },
        allocator,
        json_str,
        .{},
    );
    defer parsed.deinit();
    const opts = parsed.value.options;
    try std.testing.expect(opts.socket != null);
    try std.testing.expectEqualStrings("/run/user/1000/net-porter.sock", opts.socket.?);
    try std.testing.expect(opts.resource != null);
    try std.testing.expectEqualStrings("test-res", opts.resource.?);
}

test "DriverOptions parses deprecated field names from JSON" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{"driver":"net-porter","options":{"net_porter_socket":"/run/user/1000/net-porter.sock","net_porter_resource":"old-res"}}
    ;
    const parsed = try json.parseFromSlice(
        struct { driver: []const u8, options: DriverOptions },
        allocator,
        json_str,
        .{},
    );
    defer parsed.deinit();
    const opts = parsed.value.options;
    try std.testing.expect(opts.net_porter_socket != null);
    try std.testing.expectEqualStrings("/run/user/1000/net-porter.sock", opts.net_porter_socket.?);
    try std.testing.expect(opts.net_porter_resource != null);
    try std.testing.expectEqualStrings("old-res", opts.net_porter_resource.?);
}

const NetworkOptions = struct {
    interface_name: []const u8, // CNI_IFNAME
    static_ips: ?[]const []const u8 = null,
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
        return self.network().options.resolveResource() catch unreachable;
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
    const test_allocator = std.testing.allocator;

    const request = Request{
        .action = PluginAction.setup,
        .request = NetAvarkRequest{
            .exec = NetworkPluginExec{
                .container_name = "test-container",
                .container_id = "test-container-id",
                .network = Network{
                    .driver = "net-porter",
                    .options = DriverOptions{
                        .socket = "test-socket",
                        .resource = "test-resource",
                    },
                },
                .network_options = NetworkOptions{
                    .interface_name = "test-interface",
                },
            },
        },
    };
    const output = try json.Stringify.valueAlloc(test_allocator, request, stringify_options);
    defer test_allocator.free(output);
    try std.testing.expect(output.len != 0);

    const parsed = try json.parseFromSlice(Request, test_allocator, output, .{});
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

    const output = try json.Stringify.valueAlloc(allocator, response, stringify_options);
    defer allocator.free(output);
    try std.testing.expect(output.len != 0);

    const parsed = try json.parseFromSlice(
        Response,
        allocator,
        output,
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
stdin_file: std.Io.File,
stdout_file: std.Io.File,
io: std.Io = undefined,
namespace_path: []const u8 = undefined,

pub fn defaultNetavarkPlugin() NetavarkPlugin {
    return NetavarkPlugin{
        .allocator = std.heap.page_allocator,
        .stdin_file = std.Io.File.stdin(),
        .stdout_file = std.Io.File.stdout(),
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
    var write_buffer: [4096]u8 = undefined;
    var file_writer = self.stdout_file.writer(self.io, &write_buffer);
    try json.Stringify.value(message, stringify_options, &file_writer.interface);
    try file_writer.end();
}

fn writeError(self: *NetavarkPlugin, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    const message = try std.fmt.bufPrint(&buf, fmt, args);
    try self.write(.{ .@"error" = message });
}

test "printInfo()" {
    const test_allocator = std.testing.allocator;

    // Use valueAlloc to test serialization
    const info = PluginInfo{
        .name = name,
        .version = version,
        .api_version = "1.0.0",
        .description = "A netavark plugin to create host network interface into the rootless container",
    };
    const output = try json.Stringify.valueAlloc(test_allocator, info, stringify_options);
    defer test_allocator.free(output);
    try std.testing.expect(output.len != 0);

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

    const socket_path = network.options.resolveSocket() catch {
        try self.writeError("Missing socket in network options", .{});
        return error.AlreadyHandled;
    };

    try self.sendRequest(
        socket_path,
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

    const socket_path = network.options.resolveSocket() catch {
        try self.writeError("Missing socket in network options", .{});
        return error.AlreadyHandled;
    };

    try self.sendRequest(
        socket_path,
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
    _ = network.options.resolveResource() catch {
        self.writeError("Missing resource in network options", .{}) catch {};
        return false;
    };
    return true;
}

fn getRequest(self: *NetavarkPlugin) ![]const u8 {
    var read_buffer: [4096]u8 = undefined;
    var file_reader = self.stdin_file.reader(self.io, &read_buffer);
    return try file_reader.interface.allocRemaining(self.allocator, .limited(max_request_size));
}

fn sendRequest(self: *NetavarkPlugin, socket_path: [:0]const u8, request: *const Request) !void {
    const stream = DomainSocket.connect(self.io, socket_path) catch |err| {
        try self.writeError("Failed to connect to domain socket {s}: {s}", .{ socket_path, @errorName(err) });
        return error.AlreadyHandled;
    };
    defer stream.close(self.io);

    {
        var write_buffer: [4096]u8 = undefined;
        var stream_writer = stream.writer(self.io, &write_buffer);
        json.Stringify.value(request, stringify_options, &stream_writer.interface) catch |err| {
            try self.writeError("Failed to send request to domain socket {s}: {s}", .{ socket_path, @errorName(err) });
            return error.AlreadyHandled;
        };
        try stream_writer.interface.flush();
    }

    try stream.shutdown(self.io, .send);

    var read_buffer: [4096]u8 = undefined;
    var stream_reader = stream.reader(self.io, &read_buffer);
    const buf = stream_reader.interface.allocRemaining(
        self.allocator,
        .limited(max_response_size),
    ) catch |err| {
        try self.writeError("Failed to read response from domain socket {s}: {s}", .{ socket_path, @errorName(err) });
        return error.AlreadyHandled;
    };

    {
        var write_buffer: [4096]u8 = undefined;
        var out_writer = self.stdout_file.writer(self.io, &write_buffer);
        _ = try out_writer.interface.write(buf);
        try out_writer.end();
    }

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
