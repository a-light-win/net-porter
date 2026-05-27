const std = @import("std");
const user = @import("user.zig");

test "getUid" {
    const uid = user.getUid("root");
    try std.testing.expect(uid != null);
    try std.testing.expectEqual(0, uid);

    const uid_not_exists = user.getUid("user-not-exists");
    try std.testing.expect(uid_not_exists == null);
}

test "isValidUsername accepts valid usernames" {
    try std.testing.expect(user.isValidUsername("root"));
    try std.testing.expect(user.isValidUsername("alice"));
    try std.testing.expect(user.isValidUsername("Alice"));
    try std.testing.expect(user.isValidUsername("user123"));
    try std.testing.expect(user.isValidUsername("my_user"));
    try std.testing.expect(user.isValidUsername("my-user"));
    try std.testing.expect(user.isValidUsername("a"));
    try std.testing.expect(user.isValidUsername("User_Name-123"));
}

test "isValidUsername rejects empty and too long" {
    try std.testing.expect(!user.isValidUsername(""));
    const long = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; // 33 chars
    try std.testing.expect(!user.isValidUsername(long));
}

test "isValidUsername rejects leading dash and at sign" {
    try std.testing.expect(!user.isValidUsername("-user"));
    try std.testing.expect(!user.isValidUsername("@user"));
}

test "isValidUsername rejects path traversal characters" {
    try std.testing.expect(!user.isValidUsername("../../../etc/passwd"));
    try std.testing.expect(!user.isValidUsername("user/name"));
    try std.testing.expect(!user.isValidUsername("user\\name"));
    try std.testing.expect(!user.isValidUsername("user name"));
    try std.testing.expect(!user.isValidUsername("user\tname"));
    try std.testing.expect(!user.isValidUsername("user.name"));
    try std.testing.expect(!user.isValidUsername("user:name"));
    try std.testing.expect(!user.isValidUsername("user;name"));
    try std.testing.expect(!user.isValidUsername(".."));
}

test "isValidUsername accepts 32-char boundary" {
    const exactly_32 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; // 32 chars
    try std.testing.expect(user.isValidUsername(exactly_32));
}
