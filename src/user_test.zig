const std = @import("std");
const user = @import("user.zig");

test "getUid" {
    const uid = user.getUid("root");
    try std.testing.expect(uid != null);
    try std.testing.expectEqual(0, uid);

    const uid_not_exists = user.getUid("user-not-exists");
    try std.testing.expect(uid_not_exists == null);
}
