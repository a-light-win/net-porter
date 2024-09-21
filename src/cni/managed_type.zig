const std = @import("std");
const ArenaAllocator = @import("../utils/ArenaAllocator.zig");

pub fn ManagedType(comptime T: type) type {
    return struct {
        v: T,
        arena: ?ArenaAllocator = null,

        const Self = @This();

        pub fn deinit(self: *Self) void {
            if (@hasDecl(T, "deinit") and @typeInfo(@TypeOf(T.deinit)) == .Fn) {
                self.v.deinit();
            }

            if (self.arena) |arena| {
                arena.deinit();
            }
        }
    };
}

test "ManagedType() should release the arena and value" {
    const allocator = std.testing.allocator;
    const Test = struct {
        released: bool = false,

        const Test = @This();
        pub fn deinit(self: *Test) void {
            self.released = true;
        }
    };

    var managedTest = ManagedType(Test){
        .v = Test{},
        .arena = try ArenaAllocator.init(allocator),
    };
    managedTest.deinit();

    try std.testing.expect(managedTest.v.released);
}
