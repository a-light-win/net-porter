const std = @import("std");
const cli = @import("zig-cli");
const Server = @import("server/Server.zig");

var server_opts = Server.Opts{};

pub fn setIo(io: std.Io) void {
    server_opts.io = io;
}

pub fn cmd_server(r: *cli.AppRunner) !cli.Command {
    return cli.Command{
        .name = "server",
        .description = cli.Description{
            .one_line = "Run a server to handle network operation requests",
        },
        .options = try r.allocOptions(
            &.{.{
                .long_name = "config",
                .short_alias = 'c',
                .help = "Path to the configuration file",
                .value_ref = r.mkRef(&server_opts.config_path),
            }},
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
    _ = @import("server/AclFile.zig");
    _ = @import("server/AclManager.zig");
    _ = @import("server/AclManager_test.zig");
    _ = @import("server/Worker.zig");
    _ = @import("server/WorkerManager.zig");
}
