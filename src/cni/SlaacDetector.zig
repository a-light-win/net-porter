const std = @import("std");
const linux = std.os.linux;
const log = std.log.scoped(.slaac);

pub const SLAAC_POLL_INTERVAL_MS: u32 = 100;
pub const SLAAC_MAX_WAIT_MS: u32 = 2000;

pub const Ipv6Addr = struct {
    address: []const u8,
};

pub const DetectError = error{
    ForkFailed,
    PipeFailed,
    WaitFailed,
    ReadFailed,
    Timeout,
};

/// Detect SLAAC IPv6 addresses on an interface in a target network namespace.
/// Uses fork() to isolate the setns() call in a child process so the worker
/// never switches its own netns. Returns an empty slice on timeout (not an error).
pub fn detect(
    allocator: std.mem.Allocator,
    netns_path: []const u8,
    ifname: []const u8,
    poll_interval_ms: u32,
    max_wait_ms: u32,
) DetectError![]Ipv6Addr {
    const netns_path_z = allocator.dupeZ(u8, netns_path) catch return &[_]Ipv6Addr{};
    defer allocator.free(netns_path_z);

    // Use a monotonic clock deadline so signal-interrupted nanosleep
    // does not shorten the total polling window.
    var start_ts: linux.timespec = undefined;
    if (std.posix.errno(linux.clock_gettime(.MONOTONIC, &start_ts)) != .SUCCESS)
        return &[_]Ipv6Addr{};
    const deadline_ns: i64 = @as(i64, @intCast(start_ts.sec)) * std.time.ns_per_s +
        @as(i64, @intCast(start_ts.nsec)) +
        @as(i64, max_wait_ms) * std.time.ns_per_ms;

    while (true) {
        if (queryOnce(allocator, netns_path_z, deadline_ns)) |maybe_content| {
            if (maybe_content) |content| {
                defer allocator.free(content);
                if (parseIfInet6(allocator, content, ifname)) |addrs| {
                    if (addrs.len > 0) return addrs;
                } else |_| {}
            }
        } else |err| {
            log.warn("SLAAC query failed: {s}", .{@errorName(err)});
            return &[_]Ipv6Addr{};
        }

        var now_ts: linux.timespec = undefined;
        if (std.posix.errno(linux.clock_gettime(.MONOTONIC, &now_ts)) != .SUCCESS)
            return &[_]Ipv6Addr{};
        const now_ns: i64 = @as(i64, @intCast(now_ts.sec)) * std.time.ns_per_s +
            @as(i64, @intCast(now_ts.nsec));
        if (now_ns >= deadline_ns) break;

        const remaining_ns = deadline_ns - now_ns;
        const poll_ns = @min(
            @as(i64, poll_interval_ms) * std.time.ns_per_ms,
            remaining_ns,
        );
        var req = linux.timespec{
            .sec = @intCast(@divTrunc(poll_ns, std.time.ns_per_s)),
            .nsec = @intCast(@rem(poll_ns, std.time.ns_per_s)),
        };
        while (true) {
            var rem: linux.timespec = undefined;
            const sleep_rc = linux.nanosleep(&req, &rem);
            if (std.posix.errno(sleep_rc) == .INTR) {
                req = rem;
                continue;
            }
            break;
        }
    }

    log.warn("SLAAC detection timed out after {d}ms for {s}", .{ max_wait_ms, ifname });
    return &[_]Ipv6Addr{};
}

/// Best-effort cleanup: send SIGKILL to the child and reap with waitpid.
/// Retries waitpid on EINTR. All errors are silently ignored.
fn reapChild(pid: i32) void {
    _ = linux.kill(pid, .KILL);
    var status: u32 = 0;
    while (true) {
        const rc = linux.waitpid(pid, &status, 0);
        const n: isize = @bitCast(rc);
        if (n > 0) break;
        if (n < 0 and linux.errno(rc) == .INTR) continue;
        break;
    }
}

/// Fork a child to read /proc/net/if_inet6 inside the target netns.
/// Returns null if the child fails or produces no data.
/// deadline_ns is the absolute monotonic deadline in nanoseconds.
fn queryOnce(allocator: std.mem.Allocator, netns_path_z: [*:0]const u8, deadline_ns: i64) DetectError!?[]const u8 {
    var pipe_fds: [2]i32 = undefined;
    const pipe_rc = linux.pipe2(&pipe_fds, .{ .CLOEXEC = true });
    if (std.posix.errno(pipe_rc) != .SUCCESS) return error.PipeFailed;
    errdefer {
        if (pipe_fds[0] != -1) _ = linux.close(pipe_fds[0]);
        if (pipe_fds[1] != -1) _ = linux.close(pipe_fds[1]);
    }

    const pid_raw = linux.fork();
    const pid_signed: isize = @bitCast(pid_raw);
    if (pid_signed < 0) return error.ForkFailed;

    if (pid_signed == 0) {
        // Child: close read end — write end has CLOEXEC so future
        // open() calls from childMain won't leak it either.
        _ = linux.close(pipe_fds[0]);
        childMain(pipe_fds[1], netns_path_z);
    }

    // Parent: close write end of pipe
    _ = linux.close(pipe_fds[1]);
    pipe_fds[1] = -1;

    // Compute remaining time for poll timeout (check clock_gettime return)
    var now_ts: linux.timespec = undefined;
    if (std.posix.errno(linux.clock_gettime(.MONOTONIC, &now_ts)) != .SUCCESS)
        return error.ReadFailed;
    const now_ns: i64 = @as(i64, @intCast(now_ts.sec)) * std.time.ns_per_s +
        @as(i64, @intCast(now_ts.nsec));
    var remaining_ms: i64 = @divFloor(deadline_ns - now_ns, std.time.ns_per_ms);
    if (remaining_ms <= 0) {
        _ = linux.close(pipe_fds[0]);
        pipe_fds[0] = -1;
        reapChild(@intCast(pid_signed));
        return error.Timeout;
    }

    // Poll the pipe fd with a timeout so we don't block forever.
    // Retry on EINTR with recomputed timeout; distinguish errors from timeout.
    var initial_poll_done = false;
    while (!initial_poll_done) {
        var pfds = [1]linux.pollfd{.{
            .fd = pipe_fds[0],
            .events = linux.POLL.IN,
            .revents = 0,
        }};
        const poll_timeout: i32 = if (remaining_ms > std.math.maxInt(i32))
            std.math.maxInt(i32)
        else
            @intCast(remaining_ms);
        const poll_rc = linux.poll(&pfds, 1, poll_timeout);
        const poll_n: isize = @bitCast(poll_rc);
        if (poll_n < 0) {
            if (linux.errno(poll_rc) == .INTR) {
                // Recompute remaining time and retry
                var retry_ts: linux.timespec = undefined;
                if (std.posix.errno(linux.clock_gettime(.MONOTONIC, &retry_ts)) != .SUCCESS)
                    return error.ReadFailed;
                const retry_ns: i64 = @as(i64, @intCast(retry_ts.sec)) * std.time.ns_per_s +
                    @as(i64, @intCast(retry_ts.nsec));
                remaining_ms = @divFloor(deadline_ns - retry_ns, std.time.ns_per_ms);
                if (remaining_ms <= 0) {
                    _ = linux.close(pipe_fds[0]);
                    pipe_fds[0] = -1;
                    reapChild(@intCast(pid_signed));
                    return error.Timeout;
                }
                continue;
            }
            // Other poll error
            _ = linux.close(pipe_fds[0]);
            pipe_fds[0] = -1;
            reapChild(@intCast(pid_signed));
            return error.ReadFailed;
        }
        if (poll_n == 0) {
            _ = linux.close(pipe_fds[0]);
            pipe_fds[0] = -1;
            reapChild(@intCast(pid_signed));
            return error.Timeout;
        }
        initial_poll_done = true;
    }

    // Read child output into a dynamically-sized buffer.
    // Each read is guarded by a poll with the remaining deadline so a
    // stalled child cannot hang the parent mid-transfer.
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    var tmp: [4096]u8 = undefined;
    var read_error = false;
    while (true) {
        // Poll before each read to enforce transfer deadline
        while (true) {
            var poll_ts: linux.timespec = undefined;
            if (std.posix.errno(linux.clock_gettime(.MONOTONIC, &poll_ts)) != .SUCCESS) {
                read_error = true;
                break;
            }
            const poll_ns: i64 = @as(i64, @intCast(poll_ts.sec)) * std.time.ns_per_s +
                @as(i64, @intCast(poll_ts.nsec));
            const poll_rem_ms: i64 = @divFloor(deadline_ns - poll_ns, std.time.ns_per_ms);
            if (poll_rem_ms <= 0) {
                read_error = true;
                break;
            }
            var rpfds = [1]linux.pollfd{.{
                .fd = pipe_fds[0],
                .events = linux.POLL.IN,
                .revents = 0,
            }};
            const rpt: i32 = if (poll_rem_ms > std.math.maxInt(i32))
                std.math.maxInt(i32)
            else
                @intCast(poll_rem_ms);
            const rprc = linux.poll(&rpfds, 1, rpt);
            const rpn: isize = @bitCast(rprc);
            if (rpn < 0) {
                if (linux.errno(rprc) == .INTR) continue;
                read_error = true;
                break;
            }
            if (rpn == 0) {
                read_error = true;
                break;
            }
            break; // data available
        }
        if (read_error) break;

        const n_raw = linux.read(pipe_fds[0], &tmp, tmp.len);
        const n: isize = @bitCast(n_raw);
        if (n > 0) {
            buf.appendSlice(allocator, tmp[0..@as(usize, @intCast(n))]) catch
                return error.ReadFailed;
        } else if (n == 0) {
            break; // EOF
        } else {
            if (linux.errno(n_raw) == .INTR) continue;
            read_error = true;
            break;
        }
    }
    _ = linux.close(pipe_fds[0]);
    pipe_fds[0] = -1;

    if (read_error) {
        reapChild(@intCast(pid_signed));
        return error.ReadFailed;
    }

    // Reap the child process and verify it exited cleanly.
    var status: u32 = 0;
    while (true) {
        const wp_rc = linux.waitpid(@intCast(pid_signed), &status, 0);
        const wp_n: isize = @bitCast(wp_rc);
        if (wp_n > 0) break;
        if (wp_n < 0 and linux.errno(wp_rc) == .INTR) continue;
        return error.WaitFailed;
    }
    const wifexited = (status & 0x7f) == 0;
    const wexitstatus: u32 = (status >> 8) & 0xff;
    if (!wifexited or wexitstatus != 0) return null;

    if (buf.items.len == 0) return null;
    return buf.toOwnedSlice(allocator) catch null;
}

/// Child process entry point. Opens the netns, switches to it, reads
/// /proc/net/if_inet6, writes the raw content to the pipe, and exits.
/// Only raw syscalls are used — no stdlib I/O, no locks, no allocations.
fn childMain(write_fd: i32, netns_path_z: [*:0]const u8) noreturn {
    // Ignore SIGPIPE so writing to a closed pipe returns EPIPE instead of killing us
    var sa: linux.Sigaction = .{
        .handler = .{ .handler = linux.SIG.IGN },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    _ = linux.sigaction(.PIPE, &sa, null);

    // Close all non-essential inherited fds (keep stdin, stdout, stderr, write_fd)
    closeNonEssentialFds(write_fd);

    // Open the network namespace file
    const netns_fd_raw = linux.open(netns_path_z, .{ .ACCMODE = .RDONLY }, 0);
    const netns_fd: isize = @bitCast(netns_fd_raw);
    if (netns_fd < 0) {
        _ = linux.close(write_fd);
        linux.exit(1);
    }

    // Switch to the target network namespace
    const setns_rc_raw = linux.setns(@intCast(netns_fd), linux.CLONE.NEWNET);
    _ = linux.close(@intCast(netns_fd));
    const setns_rc: isize = @bitCast(setns_rc_raw);
    if (setns_rc != 0) {
        _ = linux.close(write_fd);
        linux.exit(1);
    }

    // Open /proc/net/if_inet6 in the target namespace
    const inet6_path: [*:0]const u8 = "/proc/net/if_inet6";
    const inet6_fd_raw = linux.open(inet6_path, .{ .ACCMODE = .RDONLY }, 0);
    const inet6_fd: isize = @bitCast(inet6_fd_raw);
    if (inet6_fd < 0) {
        _ = linux.close(write_fd);
        linux.exit(1);
    }

    // Stream /proc/net/if_inet6 to the pipe chunk by chunk so the
    // total file size is not limited by a fixed stack buffer.
    var buf: [4096]u8 = undefined;
    while (true) {
        // Read a chunk from the file (retry on EINTR, exit on error)
        var chunk_len: usize = undefined;
        while (true) {
            const r_raw = linux.read(@intCast(inet6_fd), &buf, buf.len);
            const r: isize = @bitCast(r_raw);
            if (r > 0) {
                chunk_len = @intCast(r);
                break;
            } else if (r == 0) {
                // EOF: clean up and exit successfully
                _ = linux.close(@intCast(inet6_fd));
                _ = linux.close(write_fd);
                linux.exit(0);
            } else {
                if (linux.errno(r_raw) == .INTR) continue;
                // Read error
                _ = linux.close(@intCast(inet6_fd));
                _ = linux.close(write_fd);
                linux.exit(1);
            }
        }

        // Write the chunk to the pipe (retry on EINTR, exit on error)
        var written: usize = 0;
        while (written < chunk_len) {
            const w_raw = linux.write(write_fd, buf[written..chunk_len].ptr, chunk_len - written);
            const w: isize = @bitCast(w_raw);
            if (w > 0) {
                written += @intCast(w);
            } else if (w < 0) {
                if (linux.errno(w_raw) == .INTR) continue;
                // Write error (EPIPE, EIO, etc.)
                _ = linux.close(@intCast(inet6_fd));
                _ = linux.close(write_fd);
                linux.exit(1);
            } else {
                // w == 0: unexpected for non-zero length
                _ = linux.close(@intCast(inet6_fd));
                _ = linux.close(write_fd);
                linux.exit(1);
            }
        }
    }
}

/// Close all file descriptors inherited from the parent except for
/// stdin (0), stdout (1), stderr (2), and the given keep_fd.
/// Uses raw syscalls only — safe to call in the child after fork.
fn closeNonEssentialFds(keep_fd: i32) void {
    const fd_dir_raw = linux.open("/proc/self/fd", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    const fd_dir: isize = @bitCast(fd_dir_raw);
    if (fd_dir < 0) return;
    defer _ = linux.close(@intCast(fd_dir));

    var dent_buf: [2048]u8 = undefined;
    while (true) {
        const n_raw = linux.getdents64(@intCast(fd_dir), &dent_buf, dent_buf.len);
        const n: isize = @bitCast(n_raw);
        if (n <= 0) break;
        const len: usize = @intCast(n);

        var pos: usize = 0;
        while (pos + 19 <= len) {
            // linux_dirent64 layout: d_ino(8) + d_off(8) + d_reclen(2) + d_type(1) + d_name(var)
            const reclen: u16 = @as(u16, dent_buf[pos + 16]) |
                (@as(u16, dent_buf[pos + 17]) << 8);
            if (reclen == 0 or pos + reclen > len) break;

            const name_start = pos + 19;
            const name_end = pos + @as(usize, reclen);
            if (name_start >= name_end) {
                pos += reclen;
                continue;
            }

            // Parse the fd number from the name string
            var fd_val: i32 = 0;
            var valid = true;
            for (dent_buf[name_start..name_end]) |ch| {
                if (ch == 0) break;
                if (ch < '0' or ch > '9') {
                    valid = false;
                    break;
                }
                fd_val = fd_val * 10 + (ch - '0');
            }
            if (valid and fd_val > 2 and fd_val != keep_fd and fd_val != @as(i32, @intCast(fd_dir))) {
                _ = linux.close(fd_val);
            }
            pos += reclen;
        }
    }
}

/// Parse /proc/net/if_inet6 content and return global-scope IPv6 addresses
/// for the given interface. Link-local addresses (scope 0x20) are excluded.
///
/// /proc/net/if_inet6 format (stable Linux kernel ABI):
///   <32-hex-addr> <ifindex-hex> <prefix-len-hex> <scope-hex> <flags-hex> <ifname>
///   e.g. 20010db8000000000000000000000001 02 40 00 80 eth0
pub fn parseIfInet6(allocator: std.mem.Allocator, content: []const u8, ifname: []const u8) ![]Ipv6Addr {
    var addrs = std.ArrayList(Ipv6Addr).empty;
    errdefer {
        for (addrs.items) |addr| allocator.free(addr.address);
        addrs.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Tokenize by whitespace (handles variable-width padding and tabs)
        var tokens = std.mem.tokenizeAny(u8, trimmed, " \t");
        const hex_addr = tokens.next() orelse continue;
        _ = tokens.next() orelse continue; // ifindex
        const prefix_hex = tokens.next() orelse continue;
        const scope_hex = tokens.next() orelse continue;
        _ = tokens.next() orelse continue; // flags
        const line_ifname = tokens.next() orelse continue;

        // Filter: interface name must match
        if (!std.mem.eql(u8, line_ifname, ifname)) continue;

        // Filter: only global scope (0x00). Link-local (0x20) is excluded.
        if (!std.mem.eql(u8, scope_hex, "00")) continue;

        // Validate: address must be exactly 32 hex chars
        if (hex_addr.len != 32) continue;

        // Parse prefix length from hex, reject out-of-range values
        const prefix_len = std.fmt.parseInt(u8, prefix_hex, 16) catch continue;
        if (prefix_len > 128) continue;

        const formatted = formatIpv6Cidr(allocator, hex_addr, prefix_len) catch continue;
        try addrs.append(allocator, .{ .address = formatted });
    }

    return addrs.toOwnedSlice(allocator);
}

/// Format a 32-hex-char IPv6 address and prefix length into expanded
/// "addr/prefix" CIDR notation. Inserts a colon every 4 hex characters.
pub fn formatIpv6Cidr(allocator: std.mem.Allocator, hex32: []const u8, prefix_len: u8) ![]const u8 {
    if (hex32.len != 32) return error.InvalidInput;
    if (prefix_len > 128) return error.InvalidInput;

    // 8 groups of 4 hex chars + 7 colons + 1 slash + up to 3 prefix digits
    var buf: [44]u8 = undefined;
    var pos: usize = 0;

    for (0..8) |i| {
        if (i > 0) {
            buf[pos] = ':';
            pos += 1;
        }
        @memcpy(buf[pos..][0..4], hex32[i * 4 ..][0..4]);
        pos += 4;
    }

    buf[pos] = '/';
    pos += 1;
    const prefix_str = std.fmt.bufPrint(buf[pos..], "{d}", .{prefix_len}) catch unreachable;
    pos += prefix_str.len;

    return allocator.dupe(u8, buf[0..pos]);
}

/// Parse an IPv6 address string (with optional /prefix suffix) to u128.
/// Handles standard formats including :: compression.
pub fn ipv6ToU128(addr_str: []const u8) ?u128 {
    const slash_pos = std.mem.indexOfScalar(u8, addr_str, '/') orelse addr_str.len;
    const addr = addr_str[0..slash_pos];

    if (addr.len == 0) return null;
    if (addr.len == 2 and addr[0] == ':' and addr[1] == ':') return 0;

    var groups: [8]u16 = [_]u16{0} ** 8;
    var group_count: usize = 0;
    var double_colon_pos: ?usize = null;
    var i: usize = 0;

    // Handle leading ::
    if (addr[0] == ':') {
        if (addr.len < 2 or addr[1] != ':') return null;
        double_colon_pos = 0;
        i = 2;
        if (i >= addr.len) return 0;
    }

    while (i < addr.len) {
        if (addr[i] == ':') {
            if (i + 1 < addr.len and addr[i + 1] == ':') {
                if (double_colon_pos != null) return null;
                double_colon_pos = group_count;
                i += 2;
                if (i >= addr.len) break;
                continue;
            }
            // Single ':' separator — next char must be a hex digit
            i += 1;
            if (i >= addr.len) return null;
            continue;
        }

        // Parse a hex group (up to 4 hex digits)
        var val: u16 = 0;
        var digits: usize = 0;
        while (i < addr.len and addr[i] != ':') : (i += 1) {
            const d = std.fmt.charToDigit(addr[i], 16) catch return null;
            if (digits >= 4) return null;
            val = val * 16 + @as(u16, @intCast(d));
            digits += 1;
        }
        if (digits == 0) return null;
        if (group_count >= 8) return null;
        groups[group_count] = val;
        group_count += 1;
    }

    // Reconstruct u128 from groups, expanding :: to zero groups
    var result: u128 = 0;

    if (double_colon_pos) |pos| {
        const before = pos;
        const after = group_count - pos;
        const zeros = 8 - before - after;
        if (zeros > 8) return null;

        for (0..before) |g| {
            result = (result << 16) | groups[g];
        }
        if (zeros > 0) {
            result = result << @intCast(zeros * 16);
        }
        for (before..group_count) |g| {
            result = (result << 16) | groups[g];
        }
    } else {
        if (group_count != 8) return null;
        for (0..8) |g| {
            result = (result << 16) | groups[g];
        }
    }

    return result;
}

// -- Unit tests --

test "parseIfInet6 returns global IPv6 for matching interface" {
    const allocator = std.testing.allocator;

    const content =
        \\fe80000000000000aca8d4fffed3c5a1 02 40 20 80 eth0
        \\20010db8000000000000000000000001 02 40 00 80 eth0
        \\20010db8000000000000000000000002 03 40 00 80 other0
        \\
    ;

    const addrs = try parseIfInet6(allocator, content, "eth0");
    defer {
        for (addrs) |addr| allocator.free(addr.address);
        allocator.free(addrs);
    }

    try std.testing.expectEqual(@as(usize, 1), addrs.len);
    try std.testing.expectEqualStrings("2001:0db8:0000:0000:0000:0000:0000:0001/64", addrs[0].address);
}

test "parseIfInet6 excludes link-local addresses" {
    const allocator = std.testing.allocator;

    const content =
        \\fe80000000000000aca8d4fffed3c5a1 02 40 20 80 eth0
        \\
    ;

    const addrs = try parseIfInet6(allocator, content, "eth0");
    defer {
        for (addrs) |addr| allocator.free(addr.address);
        allocator.free(addrs);
    }

    try std.testing.expectEqual(@as(usize, 0), addrs.len);
}

test "parseIfInet6 returns empty for non-matching interface" {
    const allocator = std.testing.allocator;

    const content =
        \\20010db8000000000000000000000001 02 40 00 80 eth0
        \\
    ;

    const addrs = try parseIfInet6(allocator, content, "ens33");
    defer {
        for (addrs) |addr| allocator.free(addr.address);
        allocator.free(addrs);
    }

    try std.testing.expectEqual(@as(usize, 0), addrs.len);
}

test "parseIfInet6 handles multiple matching addresses" {
    const allocator = std.testing.allocator;

    const content =
        \\20010db8000000000000000000000001 02 40 00 80 eth0
        \\20010db8000000000000000000000002 02 40 00 80 eth0
        \\fe80000000000000aca8d4fffed3c5a1 02 40 20 80 eth0
        \\
    ;

    const addrs = try parseIfInet6(allocator, content, "eth0");
    defer {
        for (addrs) |addr| allocator.free(addr.address);
        allocator.free(addrs);
    }

    try std.testing.expectEqual(@as(usize, 2), addrs.len);
}

test "parseIfInet6 handles empty content" {
    const allocator = std.testing.allocator;

    const addrs = try parseIfInet6(allocator, "", "eth0");
    defer allocator.free(addrs);

    try std.testing.expectEqual(@as(usize, 0), addrs.len);
}

test "parseIfInet6 rejects prefix_len > 128" {
    const allocator = std.testing.allocator;

    // prefix_len = 0x81 = 129 — out of range
    const content =
        \\20010db8000000000000000000000001 02 81 00 80 eth0
        \\
    ;

    const addrs = try parseIfInet6(allocator, content, "eth0");
    defer allocator.free(addrs);

    try std.testing.expectEqual(@as(usize, 0), addrs.len);
}

test "formatIpv6Cidr produces expanded IPv6 notation" {
    const allocator = std.testing.allocator;

    const result = try formatIpv6Cidr(allocator, "20010db8000000000000000000000001", 64);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("2001:0db8:0000:0000:0000:0000:0000:0001/64", result);
}

test "formatIpv6Cidr handles all-zeros address" {
    const allocator = std.testing.allocator;

    const result = try formatIpv6Cidr(allocator, "00000000000000000000000000000000", 0);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("0000:0000:0000:0000:0000:0000:0000:0000/0", result);
}

test "formatIpv6Cidr handles loopback with prefix 128" {
    const allocator = std.testing.allocator;

    const result = try formatIpv6Cidr(allocator, "00000000000000000000000000000001", 128);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("0000:0000:0000:0000:0000:0000:0000:0001/128", result);
}

test "formatIpv6Cidr rejects invalid hex length" {
    const allocator = std.testing.allocator;

    const result = formatIpv6Cidr(allocator, "short", 64);
    try std.testing.expectError(error.InvalidInput, result);
}

test "formatIpv6Cidr rejects prefix_len > 128" {
    const allocator = std.testing.allocator;

    const result = formatIpv6Cidr(allocator, "20010db8000000000000000000000001", 200);
    try std.testing.expectError(error.InvalidInput, result);
}

test "ipv6ToU128 parses standard IPv6 with ::" {
    const val = ipv6ToU128("2001:db8::1");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(u128, 0x20010db8000000000000000000000001), val.?);
}

test "ipv6ToU128 parses full expanded IPv6" {
    const val = ipv6ToU128("2001:0db8:0000:0000:0000:0000:0000:0001");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(u128, 0x20010db8000000000000000000000001), val.?);
}

test "ipv6ToU128 parses ::1 (loopback)" {
    const val = ipv6ToU128("::1");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(u128, 0x00000000000000000000000000000001), val.?);
}

test "ipv6ToU128 parses :: (all zeros)" {
    const val = ipv6ToU128("::");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(u128, 0), val.?);
}

test "ipv6ToU128 parses fe80:: link-local prefix" {
    const val = ipv6ToU128("fe80::aca8:d4ff:fed3:c5a1");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(u128, 0xfe80000000000000aca8d4fffed3c5a1), val.?);
}

test "ipv6ToU128 handles address with /prefix suffix" {
    const val = ipv6ToU128("2001:db8::1/64");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(u128, 0x20010db8000000000000000000000001), val.?);
}

test "ipv6ToU128 returns null for invalid input" {
    try std.testing.expect(ipv6ToU128("") == null);
    try std.testing.expect(ipv6ToU128(":::") == null);
    try std.testing.expect(ipv6ToU128("1:2:3:4:5:6:7:8:9") == null);
}
