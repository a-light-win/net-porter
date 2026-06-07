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
    // Use DebugAllocator in Debug/ReleaseSafe for leak and double-free detection;
    // page_allocator in ReleaseFast/ReleaseSmall for maximum performance.
    // The GPA must outlive Server and all its sub-objects, so it lives in the
    // caller and is passed to Server.new() via Opts. Defers run in reverse:
    // server.deinit() runs first (frees sub-objects), then gpa.deinit() runs
    // (reports any unfreed allocations as leaks).
    const builtin = @import("builtin");
    const use_gpa = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;
    var gpa = if (use_gpa) std.heap.DebugAllocator(.{}).init else {};
    defer {
        if (use_gpa) _ = gpa.deinit();
    }

    // Build a local Opts instead of mutating the global server_opts. The GPA's
    // allocator() returns a pointer into the stack-local gpa, so storing it in
    // the global would leave a dangling pointer after run() returns.
    const opts = Server.Opts{
        .io = server_opts.io,
        .config_path = server_opts.config_path,
        .allocator = if (use_gpa) gpa.allocator() else std.heap.page_allocator,
    };

    var server = try Server.new(opts);
    defer server.deinit();

    try server.run();
}

test {
    _ = @import("server/Server.zig");
    _ = @import("acl/Acl.zig");
    _ = @import("acl/AclFile.zig");
    _ = @import("server/AclScanner.zig");
    _ = @import("server/AclWatcher.zig");
    _ = @import("server/UidTracker.zig");
}
