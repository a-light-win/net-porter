const std = @import("std");
const cli = @import("zig-cli");
const plugin = @import("plugin.zig");
const server = @import("server.zig");
const json = @import("json.zig");
const network = @import("network.zig");

const allocator = std.heap.page_allocator;

const cmd_create = cli.Command{
    .name = "create",
    .description = cli.Description{
        .one_line = "netavark plugin api: create a network config",
    },
    .target = cli.CommandTarget{
        .action = cli.CommandAction{
            .exec = plugin.create,
        },
    },
};

const cmd_setup = cli.Command{
    .name = "setup",
    .description = cli.Description{
        .one_line = "netavark plugin api: setup the network in the container",
    },
    .target = cli.CommandTarget{
        .action = cli.CommandAction{
            .exec = plugin.setup,
        },
    },
};

const cmd_teardown = cli.Command{
    .name = "teardown",
    .description = cli.Description{
        .one_line = "netavark plugin api: teardown the network in the container",
    },
    .target = cli.CommandTarget{
        .action = cli.CommandAction{
            .exec = plugin.teardown,
        },
    },
};

const cmd_info = cli.Command{
    .name = "info",
    .description = cli.Description{
        .one_line = "netavark plugin api: get the plugin info",
    },
    .target = cli.CommandTarget{
        .action = cli.CommandAction{
            .exec = plugin.getInfo,
        },
    },
};

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
        .name = "net-porter",
        .description = cli.Description{
            .one_line = "A simple netavark plugin to create network interface",
        },
        .target = cli.CommandTarget{
            .subcommands = &.{
                cmd_create,
                cmd_setup,
                cmd_teardown,
                cmd_info,
                cmd_server,
            },
        },
    },
    .version = "0.1.0",
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
    _ = @import("config/Config.zig");
    _ = @import("json.zig");
    _ = @import("network.zig");
    _ = @import("plugin.zig");
    _ = @import("server.zig");
}
