const std = @import("std");
const json = @import("json.zig");
const network = @import("network.zig");
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

    var parsed = json.parse(network.Network, request) catch |err| {
        try json.stringifyToStdout(err);
        return;
    };
    defer parsed.deinit();

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
    // try validateRequest(request);
    // TODO: send request to the net-porter server

    try json.stringifyToStdout(request);
}
