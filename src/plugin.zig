const std = @import("std");

pub fn create_network() !void {
    std.debug.print("create\n", .{});
}

pub fn setup_network() !void {
    std.debug.print("setup\n", .{});
}

pub fn teardown_network() !void {
    std.debug.print("teardown\n", .{});
}

pub fn get_info() !void {
    std.debug.print("info\n", .{});
}
