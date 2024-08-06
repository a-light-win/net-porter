const std = @import("std");
const cli = @import("zig-cli");
const Server = @import("server/Server.zig");
const config = @import("config.zig");

var server_opts = struct {
    config_path: ?[]const u8 = null,
}{};

pub fn cmd_server(r: *cli.AppRunner) cli.Command {
    return cli.Command{
        .name = "server",
        .description = cli.Description{
            .one_line = "Run a server to handle network operation requests",
        },
        .options = &.{
            .{
                .long_name = "config",
                .short_alias = 'c',
                .help = "Path to the configuration file",
                .value_ref = r.mkRef(&server_opts.config_path),
            },
        },
        .target = cli.CommandTarget{
            .action = cli.CommandAction{
                .exec = run,
            },
        },
    };
}

fn run() !void {
    var server = try Server.new(server_opts.config_path);
    defer server.deinit();

    try server.run();
}

test {
    _ = @import("server/Server.zig");
}
