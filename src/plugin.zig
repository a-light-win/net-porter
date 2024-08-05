const std = @import("std");
const json = @import("json.zig");
const network = @import("network.zig");
const DomainSocket = @import("config/DomainSocket.zig");
const allocator = std.heap.page_allocator;

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

const plugin_info = PluginInfo{
    .name = "net-porter",
    .version = "0.1.0",
    .api_version = "1.0.0",
    .description = "A netavark plugin to create host network interface into the rootless container",
};

pub fn getInfo() !void {
    try json.stringifyToStdout(plugin_info);
}

pub fn create() !void {
    const request = getRequest() catch |err| {
        try json.stringifyToStdout(err);
        return;
    };
    defer allocator.free(request);

    const value = json.parse(allocator, request) catch |err| {
        try json.stringifyToStdout(err);
        return;
    };

    const parsed = json.parseValue(network.Network, allocator, value) catch |err| {
        try json.stringifyToStdout(err);
        return;
    };

    var config = parsed.value;
    const validated = config.validate();
    if (!validated.isOk()) {
        try json.stringifyToStdout(validated);
        return;
    }

    config.withDefaults();
    try json.stringifyToStdout(config);

    // TODO: should we send it to server?
}

pub fn setup() !void {
    const request = try getRequest();
    defer allocator.free(request);
    try sendRequest(PluginAction.setup, request);
}

pub fn teardown() !void {
    const request = try getRequest();
    defer allocator.free(request);
    try sendRequest(PluginAction.teardown, request);
}

fn getRequest() ![]const u8 {
    return std.io.getStdIn().reader().readAllAlloc(allocator, json.max_json_size);
}

fn sendRequest(action: PluginAction, request: []const u8) !void {
    _ = action;

    // TODO: get domain socket from driver options
    const domain_socket = DomainSocket{
        .path = "/run/net-porter.sock",
    };

    const stream = try domain_socket.connect();
    defer stream.close();

    try stream.writeAll(request);
    try std.posix.shutdown(stream.handle, .send);

    const buf = try stream.reader().readAllAlloc(allocator, json.max_json_size);
    std.debug.print("{s}", .{buf});
}
