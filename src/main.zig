const std = @import("std");
const cli = @import("zig-cli");
const plugin = @import("plugin.zig");
const server = @import("server.zig");
const json = @import("json.zig");
const network = @import("network.zig");

const allocator = std.heap.page_allocator;

const cmd_server = cli.Command{
    .name = "server",
    .description = cli.Description{
        .one_line = "Run a server to handle network operation requests",
    },
    .target = cli.CommandTarget{
        .action = cli.CommandAction{
            .exec = server.run,
        },
    },
};

const app = &cli.App{
    .command = cli.Command{
        .name = plugin.name,
        .description = cli.Description{
            .one_line = "A simple netavark plugin to create network interface",
        },
        .target = cli.CommandTarget{
            .subcommands = &.{
                plugin.cmd_create,
                plugin.cmd_setup,
                plugin.cmd_teardown,
                plugin.cmd_info,
                cmd_server,
            },
        },
    },
    .version = plugin.version,
    .author = "Songmin Li <lisongmin@protonmail.com>",
};

pub fn main() !void {
    var runner = cli.AppRunner.init(allocator) catch |err| {
        const error_message = network.ErrorMessage.init(@errorName(err));
        try json.stringifyToStdout(error_message);
    };
    runner.run(app) catch |err| {
        const error_message = network.ErrorMessage.init(@errorName(err));
        try json.stringifyToStdout(error_message);
    };
}

test {
    _ = @import("config.zig");
    _ = @import("json.zig");
    _ = @import("network.zig");
    _ = @import("plugin.zig");
    _ = @import("server.zig");
}
