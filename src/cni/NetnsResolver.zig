//! NetnsResolver resolves a network namespace path from the host namespace.
//!
//! Problem: The server receives `request.netns` (e.g., `/proc/<pid>/ns/net`)
//! from the client, which runs inside rootless podman's namespace. The PID in
//! the path may not be a global PID visible from the host. Also, the netns path
//! might be a custom path (e.g., `/var/run/netns/<name>`) that only exists in
//! the user's mount namespace.
//!
//! Solution: Use `/proc/<plugin_pid>/root/` to access the netns file in the
//! user's mount namespace WITHOUT entering the namespace or executing any
//! external binary. This is a pure syscall approach:
//!   1. readlink(/proc/<plugin_pid>/root/<netns_path>) → netns inode
//!   2. Walk host /proc/ to find the global PID with matching netns inode
//!   3. Return /proc/<global_pid>/ns/net (host-valid path)
//!
//! Security: No binary is executed in the user's mount namespace. The readlink
//! is performed by the server's own process via syscall. The user cannot
//! interfere with this operation because:
//!   - The server's own code is in host namespace (trusted)
//!   - readlink on a procfs magic symlink is a kernel operation
//!   - Even if the user bind-mounts a fake file at the netns path, readlink
//!     would return EINVAL (regular files aren't symlinks) or a fake inode
//!     that won't match any host process → safe failure
//!
const std = @import("std");
const log = std.log.scoped(.netns_resolver);
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

/// Resolve a netns path from the host namespace.
/// Given the plugin's global PID and the netns path from the request,
/// returns a host-valid netns path like `/proc/<global_pid>/ns/net`.
///
/// Steps:
///   1. Read the netns inode via `/proc/<plugin_pid>/root/<netns_path>`
///   2. Walk host `/proc/` to find the global PID with that inode
///   3. Return `/proc/<global_pid>/ns/net`
pub fn resolve(
    allocator: Allocator,
    plugin_pid: std.posix.pid_t,
    netns_path: []const u8,
) ![]const u8 {
    // Step 1: Read netns inode from the user's namespace via /proc/<pid>/root/
    const inode = try readNetnsInodeViaRoot(allocator, plugin_pid, netns_path);
    defer allocator.free(inode);

    log.info("Resolved netns inode from plugin pid {}: {s}", .{ plugin_pid, inode });

    // Step 2: Find the global PID in host /proc/ with matching netns inode
    const global_pid = try findGlobalPidByNetnsInode(allocator, inode);

    const result = try std.fmt.allocPrint(allocator, "/proc/{}/ns/net", .{global_pid});
    log.info("Resolved host netns path: {s}", .{result});
    return result;
}

/// Read the netns inode by accessing the file through `/proc/<pid>/root/`.
/// This uses the kernel's procfs interface to resolve the path in the target
/// process's mount namespace without entering it.
///
/// For example, if netns_path is "/proc/1234/ns/net" and plugin_pid is 5678:
///   readlink("/proc/5678/root/proc/1234/ns/net") → "net:[4026531957]"
fn readNetnsInodeViaRoot(allocator: Allocator, plugin_pid: std.posix.pid_t, netns_path: []const u8) ![]const u8 {
    // Build path: /proc/<plugin_pid>/root/<netns_path>
    const full_path = try std.fmt.allocPrintSentinel(allocator, "/proc/{d}/root/{s}", .{ plugin_pid, netns_path }, 0);
    defer allocator.free(full_path);

    var buf: [64]u8 = undefined;
    const rc = linux.readlink(full_path, &buf, buf.len);
    const err = std.posix.errno(rc);
    if (err != .SUCCESS) {
        log.warn("readlink(\"{s}\") failed: {s} (raw_netns=\"{s}\", plugin_pid={d})", .{ full_path, @tagName(err), netns_path, plugin_pid });
        switch (err) {
            .NOENT, .NOTDIR => return error.NetnsNotFound,
            .INVAL => return error.NetnsNotAccessible,
            .ACCES => return error.NetnsNotAccessible,
            else => return error.NetnsNotAccessible,
        }
    }
    const len: usize = @intCast(rc);

    if (len == 0) return error.NetnsNotAccessible;

    const inode = buf[0..len];

    // Validate it looks like a netns inode: "net:[<number>]"
    if (!std.mem.startsWith(u8, inode, "net:[")) {
        log.warn("readlink(\"{s}\") returned unexpected format: {s}", .{ full_path, inode });
        return error.InvalidNetnsInode;
    }
    if (inode[inode.len - 1] != ']') return error.InvalidNetnsInode;

    return try allocator.dupe(u8, inode);
}

/// Find a global PID whose netns inode matches the target.
/// Walks /proc/ and compares readlink("/proc/<pid>/ns/net") with target_inode.
fn findGlobalPidByNetnsInode(allocator: Allocator, target_inode: []const u8) !std.posix.pid_t {
    var buf: [64]u8 = undefined;

    const proc_fd_rc = linux.openat(linux.AT.FDCWD, "/proc", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (std.posix.errno(proc_fd_rc) != .SUCCESS) return error.ProcNotAccessible;
    const proc_fd: std.posix.fd_t = @intCast(proc_fd_rc);
    defer _ = linux.close(proc_fd);

    var entry_buf: [1024]u8 align(@alignOf(linux.dirent64)) = undefined;
    var offset: usize = 0;
    var got: usize = 0;

    while (true) {
        if (offset >= got) {
            const n = linux.getdents64(proc_fd, &entry_buf, entry_buf.len);
            if (n <= 0) break;
            got = @intCast(n);
            offset = 0;
        }

        const entry: *linux.dirent64 = @ptrCast(@alignCast(entry_buf[offset..].ptr));
        offset += entry.reclen;

        const name = std.mem.sliceTo(entry.name[0..], 0);
        const pid = std.fmt.parseUnsigned(std.posix.pid_t, name, 10) catch continue;

        // readlink /proc/<pid>/ns/net
        const ns_path = std.fmt.bufPrintZ(&buf, "/proc/{}/ns/net", .{pid}) catch continue;
        const ns_inode = readNsInodeFromPath(allocator, ns_path) catch continue;
        defer allocator.free(ns_inode);

        if (std.mem.eql(u8, ns_inode, target_inode)) {
            log.debug("Found global PID {} with netns {s}", .{ pid, target_inode });
            return pid;
        }
    }

    log.warn("No global PID found for netns inode {s}", .{target_inode});
    return error.ContainerNetnsNotFound;
}

/// Read a namespace inode from a /proc/<pid>/ns/* path.
fn readNsInodeFromPath(allocator: Allocator, path: [:0]const u8) ![]const u8 {
    var buf: [64]u8 = undefined;
    const rc = linux.readlink(path, &buf, buf.len);
    if (std.posix.errno(rc) != .SUCCESS) {
        // Process may have exited between directory scan and readlink
        return error.ProcessGone;
    }
    const len: usize = @intCast(rc);
    if (len == 0) return error.InvalidNsInode;
    return try allocator.dupe(u8, buf[0..len]);
}

// ─── Tests ────────────────────────────────────────────────────────────

test "resolve: returns current process netns path" {
    const allocator = std.testing.allocator;
    const self_pid: std.posix.pid_t = @intCast(linux.getpid());

    const result = try resolve(allocator, self_pid, "/proc/self/ns/net");
    defer allocator.free(result);

    // Should return a path like /proc/<pid>/ns/net
    try std.testing.expect(std.mem.startsWith(u8, result, "/proc/"));
    try std.testing.expect(std.mem.endsWith(u8, result, "/ns/net"));

    // The resolved path should point to the same netns as /proc/self/ns/net
    var self_buf: [64]u8 = undefined;
    var result_buf: [64]u8 = undefined;
    const rc1 = linux.readlink("/proc/self/ns/net", &self_buf, self_buf.len);
    try std.testing.expect(rc1 >= 0);
    const self_inode = self_buf[0..@as(usize, @intCast(rc1))];

    // result needs to be a [:0]const u8 for readlink
    const result_z = try std.fmt.allocPrintSentinel(allocator, "{s}", .{result}, 0);
    defer allocator.free(result_z);
    const rc2 = linux.readlink(result_z, &result_buf, result_buf.len);
    try std.testing.expect(rc2 >= 0);
    const result_inode = result_buf[0..@as(usize, @intCast(rc2))];

    try std.testing.expectEqualSlices(u8, self_inode, result_inode);
}

test "readNetnsInodeViaRoot: reads inode from current process" {
    const allocator = std.testing.allocator;
    const self_pid: std.posix.pid_t = @intCast(linux.getpid());

    const inode = try readNetnsInodeViaRoot(allocator, self_pid, "/proc/self/ns/net");
    defer allocator.free(inode);

    // Should look like "net:[<number>]"
    try std.testing.expect(std.mem.startsWith(u8, inode, "net:["));
    try std.testing.expect(inode[inode.len - 1] == ']');
}

test "readNetnsInodeViaRoot: returns error for invalid path" {
    const allocator = std.testing.allocator;
    const self_pid: std.posix.pid_t = @intCast(linux.getpid());

    const result = readNetnsInodeViaRoot(allocator, self_pid, "/nonexistent/path");
    try std.testing.expectError(error.NetnsNotFound, result);
}

test "findGlobalPidByNetnsInode: finds current process" {
    const allocator = std.testing.allocator;

    // Get current netns inode
    var buf: [64]u8 = undefined;
    const rc = linux.readlink("/proc/self/ns/net", &buf, buf.len);
    try std.testing.expect(rc >= 0);
    const self_inode = buf[0..@as(usize, @intCast(rc))];

    const inode = try allocator.dupe(u8, self_inode);
    defer allocator.free(inode);

    const pid = try findGlobalPidByNetnsInode(allocator, inode);
    const self_pid: std.posix.pid_t = @intCast(linux.getpid());
    try std.testing.expectEqual(self_pid, pid);
}

test "findGlobalPidByNetnsInode: returns error for fake inode" {
    const allocator = std.testing.allocator;

    const result = findGlobalPidByNetnsInode(allocator, "net:[999999999]");
    try std.testing.expectError(error.ContainerNetnsNotFound, result);
}
