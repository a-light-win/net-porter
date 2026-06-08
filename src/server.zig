const std = @import("std");
const cli = @import("zig-cli");
const Server = @import("server/Server.zig");
const log = std.log.scoped(.server_cmd);
const linux = std.os.linux;
const posix = std.posix;

var server_opts = Server.Opts{};

// Signal-handler-readable state. Signal handlers run asynchronously and may
// only use atomic operations and async-signal-safe syscalls. The atomic flag
// enables the main event loop to exit cleanly; `signal_pipe_write` is the
// write end of a self-pipe that wakes poll() from blocking so the flag is
// observed promptly. `pipe2 + NONBLOCK + CLOEXEC` is set up in run() before
// the handler is installed.
var shutdown_requested: std.atomic.Value(bool) = .init(false);
var signal_pipe_write: posix.fd_t = -1;

/// Async-signal-safe handler installed for SIGTERM and SIGINT.
/// Sets the atomic shutdown flag and writes a single byte to the self-pipe so
/// the main loop's poll() returns immediately (Zig's `posix.poll` auto-retries
/// on EINTR, so a bare signal would not unblock it).
fn signalHandler(_: posix.SIG) callconv(.c) void {
    shutdown_requested.store(true, .release);
    if (signal_pipe_write >= 0) {
        const buf: [1]u8 = .{1};
        _ = linux.write(signal_pipe_write, &buf, 1);
    }
}

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

    // Self-pipe used by the signal handler to wake poll() on SIGTERM/SIGINT.
    // Created before the handler is installed so the handler never sees a
    // stale `signal_pipe_write`. Both ends are non-blocking and close-on-exec.
    var pipe_fds: [2]posix.fd_t = undefined;
    {
        const rc = linux.pipe2(&pipe_fds, .{ .NONBLOCK = true, .CLOEXEC = true });
        if (posix.errno(rc) != .SUCCESS) {
            log.err("pipe2 for signal wake-up failed: errno={d}", .{@intFromEnum(posix.errno(rc))});
            return error.SignalPipeFailed;
        }
    }
    const pipe_read = pipe_fds[0];
    const pipe_write = pipe_fds[1];
    defer {
        _ = linux.close(pipe_read);
        _ = linux.close(pipe_write);
    }

    // Install signal handlers. Reset state in case run() is invoked more than
    // once in the same process (today it is not, but this is defensive).
    shutdown_requested.store(false, .release);
    signal_pipe_write = pipe_write;
    const sa: posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.TERM, &sa, null);
    posix.sigaction(.INT, &sa, null);

    var server = try Server.new(opts);
    defer server.deinit();

    try server.run(.{
        .shutdown_flag = &shutdown_requested,
        .wake_fd = pipe_read,
    });
}

test {
    _ = @import("server/Server.zig");
    _ = @import("acl/Acl.zig");
    _ = @import("acl/AclFile.zig");
    _ = @import("server/AclScanner.zig");
    _ = @import("server/AclWatcher.zig");
    _ = @import("server/UidTracker.zig");
}
