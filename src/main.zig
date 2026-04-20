const std = @import("std");
const cli = @import("zig-cli");
const plugin = @import("plugin.zig");
const server = @import("server.zig");
const worker_mod = @import("worker.zig");
const utils = @import("utils.zig");
const Logger = utils.Logger;
const ErrorMessage = utils.ErrorMessage;

pub var logger = Logger.newLogger();

fn logIt(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    logger.log(message_level, scope, format, args);
}

pub const std_options = std.Options{
    .log_level = std.log.Level.debug,
    .logFn = logIt,
};

pub fn main(init: std.process.Init) !void {
    logger.io = init.io;
    plugin.setIo(init.io);
    server.setIo(init.io);
    worker_mod.setIo(init.io);

    var runner = cli.AppRunner.init(&init);

    const app = &cli.App{
        .command = cli.Command{
            .name = plugin.name,
            .description = cli.Description{
                .one_line = "A simple netavark plugin to create network interface",
            },
            .target = cli.CommandTarget{
                .subcommands = &.{
                    plugin.cmd_create,
                    try plugin.cmd_setup(&runner),
                    try plugin.cmd_teardown(&runner),
                    plugin.cmd_info,
                    try server.cmd_server(&runner),
                    try worker_mod.cmd_worker(&runner),
                },
            },
        },
        .version = plugin.version,
        .author = "Songmin Li <lisongmin@protonmail.com>",
    };

    runner.run(app) catch |err| {
        switch (err) {
            error.AlreadyHandled => {},
            else => {
                var write_buffer: [4096]u8 = undefined;
                var file_writer = std.Io.File.stdout().writer(init.io, &write_buffer);
                std.json.Stringify.value(ErrorMessage.init(@errorName(err)), .{ .whitespace = .indent_2 }, &file_writer.interface) catch {};
                file_writer.end() catch {};
            },
        }
        std.process.exit(1);
    };
}

test {
    _ = @import("config.zig");
    _ = @import("plugin.zig");
    _ = @import("server.zig");
    _ = @import("user.zig");
    _ = @import("utils.zig");
    _ = @import("cni.zig");
    _ = @import("worker.zig");
}
