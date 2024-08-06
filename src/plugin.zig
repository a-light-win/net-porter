const NetavarkPlugin = @import("plugin/NetavarkPlugin.zig");

pub const name = NetavarkPlugin.name;
pub const version = NetavarkPlugin.version;

var plugin = NetavarkPlugin.defaultNetavarkPlugin();

pub fn setup() !void {
    try plugin.setup();
}

pub fn create() !void {
    try plugin.create();
}

pub fn teardown() !void {
    try plugin.teardown();
}

pub fn printInfo() !void {
    try plugin.printInfo();
}

test {
    _ = @import("plugin/NetavarkPlugin.zig");
}
