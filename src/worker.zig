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
                .long_name = "username",
                .help = "Username for ACL loading",
                .value_ref = r.mkRef(&worker_opts.username),
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
    // Use DebugAllocator in Debug/ReleaseSafe for leak and double-free detection;
    // page_allocator in ReleaseFast/ReleaseSmall for maximum performance.
    // The GPA must outlive Worker and all its sub-objects, so it lives in the
    // caller and is passed to Worker.new() via Opts. Defers run in reverse:
    // worker.deinit() runs first (frees sub-objects), then gpa.deinit() runs
    // (reports any unfreed allocations as leaks).
    const builtin = @import("builtin");
    const use_gpa = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;
    var gpa = if (use_gpa) std.heap.DebugAllocator(.{}).init else {};
    defer {
        if (use_gpa) _ = gpa.deinit();
    }

    // Build a local Opts instead of mutating the global worker_opts. The GPA's
    // allocator() returns a pointer into the stack-local gpa, so storing it in
    // the global would leave a dangling pointer after run() returns.
    const opts = Worker.Opts{
        .io = worker_opts.io,
        .uid = worker_opts.uid,
        .username = worker_opts.username,
        .catatonit_pid = worker_opts.catatonit_pid,
        .config_path = worker_opts.config_path,
        .allocator = if (use_gpa) gpa.allocator() else std.heap.page_allocator,
    };

    var worker = try Worker.new(opts);
    defer worker.deinit();

    try worker.run();
}

test {
    _ = @import("worker/Worker.zig");
    _ = @import("worker/WorkerManager.zig");
    _ = @import("worker/Handler.zig");
    _ = @import("worker/AclManager.zig");
}
