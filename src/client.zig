const std = @import("std");
const json = @import("json.zig");
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
    const buffer = try readStdio();
    defer allocator.free(buffer);
    try sendRequest(PluginAction.create);
}

pub fn setup() !void {
    const buffer = try readStdio();
    defer allocator.free(buffer);
    try sendRequest(PluginAction.setup);
}

pub fn teardown() !void {
    const buffer = try readStdio();
    defer allocator.free(buffer);
    try sendRequest(PluginAction.teardown);
}

const max_input_size = 1024 * 1024;

fn readStdio() ![]u8 {
    return std.io.getStdIn().reader().readAllAlloc(allocator, max_input_size);
}

fn sendRequest(action: PluginAction) !void {
    // TODO: send request to the net-porter server
    try json.stringifyToStdout(action);
}
