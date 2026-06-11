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

    var elapsed_ms: u32 = 0;
    while (true) {
        if (queryOnce(allocator, netns_path_z)) |maybe_content| {
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

        if (elapsed_ms >= max_wait_ms) break;

        const sleep_ms = @min(poll_interval_ms, max_wait_ms - elapsed_ms);
        const req = linux.timespec{ .sec = 0, .nsec = @intCast(sleep_ms * 1_000_000) };
        _ = linux.nanosleep(&req, null);
        elapsed_ms += sleep_ms;
    }

    log.warn("SLAAC detection timed out after {d}ms for {s}", .{ max_wait_ms, ifname });
    return &[_]Ipv6Addr{};
}

/// Fork a child to read /proc/net/if_inet6 inside the target netns.
/// Returns null if the child fails or produces no data.
fn queryOnce(allocator: std.mem.Allocator, netns_path_z: [*:0]const u8) DetectError!?[]const u8 {
    var pipe_fds: [2]i32 = undefined;
    const pipe_rc = linux.pipe(&pipe_fds);
    if (pipe_rc != 0) return error.PipeFailed;
    errdefer {
        _ = linux.close(pipe_fds[0]);
        _ = linux.close(pipe_fds[1]);
    }

    const pid_raw = linux.fork();
    const pid_signed: isize = @bitCast(pid_raw);
    if (pid_signed < 0) return error.ForkFailed;

    if (pid_signed == 0) {
        childMain(pipe_fds[1], netns_path_z);
    }

    // Parent: close write end of pipe
    _ = linux.close(pipe_fds[1]);

    // Read child output from pipe into a stack buffer
    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n_raw = linux.read(pipe_fds[0], buf[total..].ptr, buf.len - total);
        const n: isize = @bitCast(n_raw);
        if (n <= 0) break;
        total += @intCast(n);
    }
    _ = linux.close(pipe_fds[0]);

    // Reap the child process
    var status: u32 = 0;
    _ = linux.waitpid(@intCast(pid_signed), &status, 0);

    if (total == 0) return null;
    return allocator.dupe(u8, buf[0..total]) catch null;
}

/// Child process entry point. Opens the netns, switches to it, reads
/// /proc/net/if_inet6, writes the raw content to the pipe, and exits.
/// Only raw syscalls are used — no stdlib I/O, no locks, no allocations.
fn childMain(write_fd: i32, netns_path_z: [*:0]const u8) noreturn {
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

    // Read the entire file into a stack buffer
    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n_raw = linux.read(@intCast(inet6_fd), buf[total..].ptr, buf.len - total);
        const n: isize = @bitCast(n_raw);
        if (n <= 0) break;
        total += @intCast(n);
    }
    _ = linux.close(@intCast(inet6_fd));

    // Write raw content to the pipe for the parent to parse
    var written: usize = 0;
    while (written < total) {
        const n_raw = linux.write(write_fd, buf[written..total].ptr, total - written);
        const n: isize = @bitCast(n_raw);
        if (n <= 0) break;
        written += @intCast(n);
    }

    _ = linux.close(write_fd);
    linux.exit(0);
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

        // Tokenize by whitespace (handles variable-width padding)
        var tokens = std.mem.tokenizeScalar(u8, trimmed, ' ');
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

        // Parse prefix length from hex
        const prefix_len = std.fmt.parseInt(u8, prefix_hex, 16) catch continue;

        const formatted = formatIpv6Cidr(allocator, hex_addr, prefix_len) catch continue;
        try addrs.append(allocator, .{ .address = formatted });
    }

    return addrs.toOwnedSlice(allocator);
}

/// Format a 32-hex-char IPv6 address and prefix length into "addr/prefix" CIDR notation.
/// Output format: "2001:0db8:0000:0000:0000:0000:0000:0001/64"
pub fn formatIpv6Cidr(allocator: std.mem.Allocator, hex32: []const u8, prefix_len: u8) ![]const u8 {
    if (hex32.len != 32) return error.InvalidInput;

    // Max output: 8 groups * 4 chars + 7 colons + 1 slash + 3 digit prefix = 43
    var buf: [48]u8 = undefined;
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
    const prefix_str = try std.fmt.bufPrint(buf[pos..], "{d}", .{prefix_len});
    pos += prefix_str.len;

    return allocator.dupe(u8, buf[0..pos]);
}

/// Convert a 32-hex-char IPv6 address to a u128 for comparison.
pub fn hex32ToU128(hex: []const u8) ?u128 {
    if (hex.len != 32) return null;
    var result: u128 = 0;
    for (hex) |c| {
        const d = std.fmt.charToDigit(c, 16) catch return null;
        result = result * 16 + @as(u128, @intCast(d));
    }
    return result;
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

test "formatIpv6Cidr produces correct expanded notation" {
    const allocator = std.testing.allocator;

    const result = try formatIpv6Cidr(allocator, "20010db8000000000000000000000001", 64);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("2001:0db8:0000:0000:0000:0000:0000:0001/64", result);
}

test "formatIpv6Cidr handles prefix length 128" {
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

test "hex32ToU128 parses 32 hex chars to u128" {
    const val = hex32ToU128("20010db8000000000000000000000001");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(u128, 0x20010db8000000000000000000000001), val.?);
}

test "hex32ToU128 returns null for wrong length" {
    try std.testing.expect(hex32ToU128("short") == null);
    try std.testing.expect(hex32ToU128("") == null);
}

test "hex32ToU128 returns null for non-hex chars" {
    try std.testing.expect(hex32ToU128("20010db80000000000000000000000zz") == null);
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
