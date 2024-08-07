const std = @import("std");
const c = @cImport({
    @cInclude("pwd.h");
    @cInclude("grp.h");
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

pub fn getGid(groupname: [:0]const u8) ?std.posix.gid_t {
    var buf: [1024]u8 = undefined; // Buffer for `getgrnam_r`
    var grp: c.struct_group = undefined; // Struct to store the result
    var result: ?*c.struct_group = null; // Pointer to the result struct

    const ret = c.getgrnam_r(&groupname[0], &grp, &buf[0], buf.len, &result);

    if (ret != 0 or result == null) {
        return null; // Group not found or error
    }

    return grp.gr_gid;
}

test {
    _ = @import("user_test.zig");
}
