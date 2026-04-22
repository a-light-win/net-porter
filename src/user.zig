const std = @import("std");
const c = @cImport({
    @cInclude("pwd.h");
    @cInclude("unistd.h");
    @cInclude("stddef.h");
});

pub fn getUid(username: [:0]const u8) ?std.posix.uid_t {
    var buf: [1024]u8 = undefined; // Buffer for `getpwnam_r`
    var pwd: c.struct_passwd = undefined; // Struct to store the result
    var result: ?*c.struct_passwd = null; // Pointer to the result struct

    const ret = c.getpwnam_r(
        &username[0],
        &pwd,
        &buf[0],
        buf.len,
        &result,
    );

    if (ret != 0 or result == null) {
        return null;
    }

    return pwd.pw_uid;
}

/// Read the host UID from /proc/self/uid_map.
/// In a user namespace (e.g. rootless podman), getuid() returns the
/// namespace-mapped UID (typically 0), but uid_map reveals the actual
/// host UID mapping.
/// Format: "namespace_uid host_uid count"
/// Falls back to getuid() if not in a namespace or on read error.
pub fn getHostUid(io: std.Io) std.posix.uid_t {
    const ns_uid = std.os.linux.getuid();

    var buf: [256]u8 = undefined;
    const file = std.Io.Dir.cwd().openFile(io, "/proc/self/uid_map", .{}) catch return ns_uid;
    defer file.close(io);
    var reader = file.reader(io, &buf);
    const content = reader.interface.allocRemaining(std.heap.page_allocator, .limited(255)) catch return ns_uid;
    defer std.heap.page_allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const ns_start = std.fmt.parseUnsigned(std.posix.uid_t, it.next() orelse continue, 10) catch continue;
        const host_start = std.fmt.parseUnsigned(std.posix.uid_t, it.next() orelse continue, 10) catch continue;
        const count = std.fmt.parseUnsigned(std.posix.uid_t, it.next() orelse continue, 10) catch continue;

        if (count > 0 and ns_uid >= ns_start and ns_uid < ns_start + count) {
            return host_start + (ns_uid - ns_start);
        }
    }

    return ns_uid;
}

pub fn getUsername(allocator: std.mem.Allocator, uid: std.posix.uid_t) ?[:0]const u8 {
    var buf: [1024]u8 = undefined;
    var pwd: c.struct_passwd = undefined;
    var result: ?*c.struct_passwd = null;

    const ret = c.getpwuid_r(uid, &pwd, &buf[0], buf.len, &result);
    if (ret != 0 or result == null) return null;

    const name = std.mem.sliceTo(pwd.pw_name, 0);
    return allocator.dupeZ(u8, name) catch null;
}

test {
    _ = @import("user_test.zig");
}
