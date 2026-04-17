//! NetnsResolver resolves a network namespace path from the host namespace.
//!
//! Problem: The server receives `request.netns` from the client, which runs
//! inside rootless podman's namespace. The path can be:
//!   - `/proc/<pid>/ns/net` (procfs magic symlink)
//!   - `/run/user/<uid>/netns/<name>` (bind-mounted regular file)
//! Neither path is valid from the host, because:
//!   - The PID may not be a global PID visible from the host
//!   - The netns path may only exist in the user's mount namespace
//!
//! Solution: Use `/proc/<plugin_pid>/root/` to access the netns file in the
//! user's mount namespace WITHOUT entering the namespace or executing any
//! external binary:
//!   1. stat(/proc/<plugin_pid>/root/<netns_path>) → nsfs inode number
//!   2. Walk host /proc/ to find the global PID with matching inode
//!   3. Return /proc/<global_pid>/ns/net (host-valid path)
//!
//! Note: We use stat instead of readlink because the netns file can be a
//! regular bind-mounted file (not a symlink). stat works on both regular
//! files and magic symlinks.
//!
//! Security: No binary is executed in the user's mount namespace. The stat
//! is performed by the server's own process via the kernel. The user cannot
//! interfere with this operation because:
//!   - The server's own code is in host namespace (trusted)
//!   - stat via /proc/<pid>/root/ is a kernel operation
//!   - Even if the user bind-mounts a fake file, its inode won't match
//!     any host process's netns → safe failure
//!
const std = @import("std");
const log = std.log.scoped(.netns_resolver);
const Allocator = std.mem.Allocator;

/// Resolve a netns path from the host namespace.
/// Given the plugin's global PID and the netns path from the request,
/// returns a host-valid netns path like `/proc/<global_pid>/ns/net`.
///
/// Steps:
///   1. stat the netns file via `/proc/<plugin_pid>/root/<netns_path>` → inode
///   2. Walk host `/proc/` to find the global PID with that inode
///   3. Return `/proc/<global_pid>/ns/net`
pub fn resolve(
    io: std.Io,
    allocator: Allocator,
    plugin_pid: std.posix.pid_t,
    netns_path: []const u8,
) ![]const u8 {
    // Step 1: Get netns inode from the user's namespace via /proc/<pid>/root/
    const target_inode = try statNetnsViaRoot(io, allocator, plugin_pid, netns_path);

    log.info("Resolved netns inode from plugin pid {}: {}", .{ plugin_pid, target_inode });

    // Step 2: Find the global PID in host /proc/ with matching netns inode
    const global_pid = try findGlobalPidByNetnsInode(io, target_inode);

    const result = try std.fmt.allocPrint(allocator, "/proc/{}/ns/net", .{global_pid});
    log.info("Resolved host netns path: {s}", .{result});
    return result;
}

/// Stat the netns file through `/proc/<pid>/root/` to get its inode number.
/// This works for both regular files (bind mounts) and magic symlinks.
fn statNetnsViaRoot(io: std.Io, allocator: Allocator, plugin_pid: std.posix.pid_t, netns_path: []const u8) !std.Io.File.INode {
    // Build path: /proc/<plugin_pid>/root/<netns_path>
    const full_path = try std.fmt.allocPrint(allocator, "/proc/{d}/root/{s}", .{ plugin_pid, netns_path });
    defer allocator.free(full_path);

    const file = std.Io.Dir.openFileAbsolute(io, full_path, .{ .mode = .read_only }) catch |err| {
        log.warn("Failed to open netns \"{s}\": {s} (raw_netns=\"{s}\", plugin_pid={d})", .{ full_path, @errorName(err), netns_path, plugin_pid });
        switch (err) {
            error.FileNotFound => return error.NetnsNotFound,
            else => return error.NetnsNotAccessible,
        }
    };
    defer file.close(io);

    const stat = file.stat(io) catch |err| {
        log.warn("Failed to stat netns \"{s}\": {s}", .{ full_path, @errorName(err) });
        return error.NetnsNotAccessible;
    };

    return stat.inode;
}

/// Find a global PID whose netns inode matches the target.
/// Walks /proc/ and stats `/proc/<pid>/ns/net` for each process.
fn findGlobalPidByNetnsInode(io: std.Io, target_inode: std.Io.File.INode) !std.posix.pid_t {
    var proc_dir = std.Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true }) catch
        return error.ProcNotAccessible;
    defer proc_dir.close(io);

    var iter = proc_dir.iterate();
    while (iter.next(io) catch null) |entry| {
        const pid = std.fmt.parseUnsigned(std.posix.pid_t, entry.name, 10) catch continue;

        // stat /proc/<pid>/ns/net
        var buf: [64]u8 = undefined;
        const ns_path = std.fmt.bufPrint(&buf, "/proc/{}/ns/net", .{pid}) catch continue;
        const file = std.Io.Dir.openFileAbsolute(io, ns_path, .{ .mode = .read_only }) catch continue;
        defer file.close(io);

        const stat = file.stat(io) catch continue;
        if (stat.inode == target_inode) {
            log.debug("Found global PID {} with netns inode {}", .{ pid, target_inode });
            return pid;
        }
    }

    log.warn("No global PID found for netns inode {}", .{target_inode});
    return error.ContainerNetnsNotFound;
}

// ─── Tests ────────────────────────────────────────────────────────────

test "resolve: returns current process netns path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const self_pid: std.posix.pid_t = @intCast(std.os.linux.getpid());

    const result = try resolve(io, allocator, self_pid, "/proc/self/ns/net");
    defer allocator.free(result);

    // Should return a path like /proc/<pid>/ns/net
    try std.testing.expect(std.mem.startsWith(u8, result, "/proc/"));
    try std.testing.expect(std.mem.endsWith(u8, result, "/ns/net"));

    // The resolved path should point to the same netns as /proc/self/ns/net
    const self_file = try std.Io.Dir.openFileAbsolute(io, "/proc/self/ns/net", .{ .mode = .read_only });
    defer self_file.close(io);
    const self_stat = try self_file.stat(io);

    const result_file = try std.Io.Dir.openFileAbsolute(io, result, .{ .mode = .read_only });
    defer result_file.close(io);
    const result_stat = try result_file.stat(io);

    try std.testing.expectEqual(self_stat.inode, result_stat.inode);
}

test "statNetnsViaRoot: reads inode from current process" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const self_pid: std.posix.pid_t = @intCast(std.os.linux.getpid());

    const inode = try statNetnsViaRoot(io, allocator, self_pid, "/proc/self/ns/net");

    // Should be a positive inode number
    try std.testing.expect(inode > 0);
}

test "statNetnsViaRoot: returns error for invalid path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const self_pid: std.posix.pid_t = @intCast(std.os.linux.getpid());

    const result = statNetnsViaRoot(io, allocator, self_pid, "/nonexistent/path");
    try std.testing.expectError(error.NetnsNotFound, result);
}

test "findGlobalPidByNetnsInode: finds current process" {
    const io = std.testing.io;

    // Get current netns inode
    const file = try std.Io.Dir.openFileAbsolute(io, "/proc/self/ns/net", .{ .mode = .read_only });
    defer file.close(io);
    const stat = try file.stat(io);

    const pid = try findGlobalPidByNetnsInode(io, stat.inode);
    const self_pid: std.posix.pid_t = @intCast(std.os.linux.getpid());
    try std.testing.expectEqual(self_pid, pid);
}

test "findGlobalPidByNetnsInode: returns error for fake inode" {
    const io = std.testing.io;

    const result = findGlobalPidByNetnsInode(io, 999999999);
    try std.testing.expectError(error.ContainerNetnsNotFound, result);
}
