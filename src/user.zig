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
