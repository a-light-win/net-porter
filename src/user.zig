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

/// Validate that a username contains only safe characters.
/// Prevents path traversal attacks when the username is used in file paths.
/// Valid: a-z, A-Z, 0-9, underscore, hyphen. Must not be empty, must not start with '-' or '@'.
pub fn isValidUsername(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name.len > 32) return false;
    if (name[0] == '-' or name[0] == '@') return false;
    for (name) |ch| {
        switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => {},
            else => return false,
        }
    }
    return true;
}

pub fn getUsername(allocator: std.mem.Allocator, uid: std.posix.uid_t) !?[:0]const u8 {
    var buf: [1024]u8 = undefined;
    var pwd: c.struct_passwd = undefined;
    var result: ?*c.struct_passwd = null;

    const ret = c.getpwuid_r(uid, &pwd, &buf[0], buf.len, &result);
    if (ret != 0 or result == null) return null;

    const name = std.mem.sliceTo(pwd.pw_name, 0);
    return try allocator.dupeZ(u8, name);
}

test {
    _ = @import("user_test.zig");
}
