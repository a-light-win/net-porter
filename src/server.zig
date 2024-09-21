const std = @import("std");
const cli = @import("zig-cli");
const Server = @import("server/Server.zig");
const config = @import("config.zig");

var server_opts = Server.Opts{};

pub fn cmd_server(r: *cli.AppRunner) !cli.Command {
    return cli.Command{
        .name = "server",
        .description = cli.Description{
            .one_line = "Run a server to handle network operation requests",
        },
        .options = try r.mkSlice(
            cli.Option,
            &.{ .{
                .long_name = "config",
                .short_alias = 'c',
                .help = "Path to the configuration file",
                .value_ref = r.mkRef(&server_opts.config_path),
            }, .{
                .long_name = "uid",
                .short_alias = 'u',
                .help = "The net-porter server will process requests from this user id",
                .value_ref = r.mkRef(&server_opts.uid),
            } },
        ),
        .target = cli.CommandTarget{
            .action = cli.CommandAction{
                .exec = run,
            },
        },
    };
}

fn run() !void {
    var server = try Server.new(server_opts);
    defer server.deinit();

    try server.run();
}

test {
    _ = @import("server/Server.zig");
    _ = @import("server/Handler.zig");
    _ = @import("server/Acl.zig");
    _ = @import("server/AclManager.zig");
}
