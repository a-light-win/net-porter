const cli = @import("zig-cli");
const NetavarkPlugin = @import("plugin/NetavarkPlugin.zig");

pub const name = NetavarkPlugin.name;
pub const version = NetavarkPlugin.version;
pub const Request = NetavarkPlugin.Request;

var plugin = NetavarkPlugin.defaultNetavarkPlugin();

fn setup() !void {
    try plugin.setup();
}

fn create() !void {
    try plugin.create();
}

fn teardown() !void {
    try plugin.teardown();
}

fn printInfo() !void {
    try plugin.printInfo();
}

pub const cmd_create = cli.Command{
    .name = "create",
    .description = cli.Description{
        .one_line = "netavark plugin api: create a network config",
    },
    .target = cli.CommandTarget{
        .action = cli.CommandAction{
            .exec = create,
        },
    },
};

pub const cmd_setup = cli.Command{
    .name = "setup",
    .description = cli.Description{
        .one_line = "netavark plugin api: setup the network in the container",
    },
    .target = cli.CommandTarget{
        .action = cli.CommandAction{
            .exec = setup,
        },
    },
};

pub const cmd_teardown = cli.Command{
    .name = "teardown",
    .description = cli.Description{
        .one_line = "netavark plugin api: teardown the network in the container",
    },
    .target = cli.CommandTarget{
        .action = cli.CommandAction{
            .exec = teardown,
        },
    },
};

pub const cmd_info = cli.Command{
    .name = "info",
    .description = cli.Description{
        .one_line = "netavark plugin api: get the plugin info",
    },
    .target = cli.CommandTarget{
        .action = cli.CommandAction{
            .exec = printInfo,
        },
    },
};

test {
    _ = @import("plugin/NetavarkPlugin.zig");
}
