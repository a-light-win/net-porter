const cli = @import("zig-cli");
const NetavarkPlugin = @import("plugin/NetavarkPlugin.zig");

pub const name = NetavarkPlugin.name;
pub const version = NetavarkPlugin.version;
pub const max_request_size = NetavarkPlugin.max_request_size;
pub const max_response_size = NetavarkPlugin.max_response_size;
pub const Request = NetavarkPlugin.Request;
pub const Response = NetavarkPlugin.Response;
pub const Interface = NetavarkPlugin.Interface;
pub const Subnet = NetavarkPlugin.Subnet;

pub const NetworkPluginExec = NetavarkPlugin.NetworkPluginExec;

var plugin = NetavarkPlugin.defaultNetavarkPlugin();

fn create() !void {
    try plugin.create();
}

fn setup() !void {
    try plugin.setup();
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

pub fn cmd_setup(r: *cli.AppRunner) !cli.Command {
    return cli.Command{
        .name = "setup",
        .description = cli.Description{
            .one_line = "netavark plugin api: setup the network in the container",
        },
        .target = cli.CommandTarget{
            .action = cli.CommandAction{
                .exec = setup,
                .positional_args = cli.PositionalArgs{
                    .required = try r.mkSlice(cli.PositionalArg, &.{
                        .{
                            .name = "namespace_path",
                            .help = "The path to the network namespace",
                            .value_ref = r.mkRef(&plugin.namespace_path),
                        },
                    }),
                },
            },
        },
    };
}

pub fn cmd_teardown(r: *cli.AppRunner) !cli.Command {
    return cli.Command{
        .name = "teardown",
        .description = cli.Description{
            .one_line = "netavark plugin api: teardown the network in the container",
        },
        .target = cli.CommandTarget{
            .action = cli.CommandAction{
                .exec = teardown,
                .positional_args = cli.PositionalArgs{
                    .required = try r.mkSlice(cli.PositionalArg, &.{
                        .{
                            .name = "namespace_path",
                            .help = "The path to the network namespace",
                            .value_ref = r.mkRef(&plugin.namespace_path),
                        },
                    }),
                },
            },
        },
    };
}

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
