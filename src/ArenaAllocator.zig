const std = @import("std");
const Allocator = std.mem.Allocator;
const Self = @This();

arena: *std.heap.ArenaAllocator,

pub fn init(child_allocator: Allocator) Allocator.Error!Self {
    var arena = try child_allocator.create(std.heap.ArenaAllocator);
    errdefer child_allocator.destroy(arena);

    arena.* = std.heap.ArenaAllocator.init(child_allocator);
    errdefer arena.deinit();

    return Self{ .arena = arena };
}

pub fn allocator(self: *Self) Allocator {
    return self.arena.allocator();
}

pub fn childAllocator(self: Self) Allocator {
    return self.arena.child_allocator;
}

pub fn deinit(self: Self) void {
    const child_allocator = self.arena.child_allocator;
    self.arena.deinit();
    child_allocator.destroy(self.arena);
}
