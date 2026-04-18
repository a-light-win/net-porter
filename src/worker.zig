const std = @import("std");
const cli = @import("zig-cli");
const Worker = @import("worker/Worker.zig");

var worker_opts = Worker.Opts{};

pub fn setIo(io: std.Io) void {
    worker_opts.io = io;
}

pub fn cmd_worker(r: *cli.AppRunner) !cli.Command {
    return cli.Command{
        .name = "worker",
        .description = cli.Description{
            .one_line = "Run a per-UID worker daemon (spawned by the main server)",
        },
        .options = try r.allocOptions(&.{
            .{
                .long_name = "uid",
                .help = "UID this worker serves",
                .value_ref = r.mkRef(&worker_opts.uid),
            },
            .{
                .long_name = "catatonit-pid",
                .help = "PID of the catatonit infra container for this UID",
                .value_ref = r.mkRef(&worker_opts.catatonit_pid),
            },
            .{
                .long_name = "config",
                .short_alias = 'c',
                .help = "Path to the configuration file",
                .value_ref = r.mkRef(&worker_opts.config_path),
            },
        }),
        .target = cli.CommandTarget{
            .action = cli.CommandAction{
                .exec = run,
            },
        },
    };
}

fn run() !void {
    var worker = try Worker.new(worker_opts);
    defer worker.deinit();

    try worker.run();
}

test {
    _ = @import("worker/Worker.zig");
    _ = @import("worker/WorkerManager.zig");
    _ = @import("worker/Handler.zig");
}
