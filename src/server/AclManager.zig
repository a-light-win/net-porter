const std = @import("std");
const log = std.log.scoped(.acl_manager);
const Acl = @import("Acl.zig");
const AclFile = @import("AclFile.zig");
const ArenaAllocator = @import("../utils/ArenaAllocator.zig");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const AclManager = @This();

arena: ArenaAllocator,
allocator: Allocator,
acls: std.ArrayList(Acl) = undefined,
mutex: std.Io.Mutex = .init,

/// inotify file descriptor for watching acl_dir, null if dir doesn't exist.
acl_inotify_fd: ?std.posix.fd_t = null,
acl_dir: []const u8,

// inotify event mask bits
const IN_CREATE: u32 = 0x00000100;
const IN_DELETE: u32 = 0x00000200;
const IN_MODIFY: u32 = 0x00000002;
const IN_MOVED_FROM: u32 = 0x00000040;
const IN_MOVED_TO: u32 = 0x00000080;
const IN_CLOSE_WRITE: u32 = 0x00000008;

const IN_NONBLOCK: u32 = 0x800;
const IN_CLOEXEC: u32 = 0x80000;

const max_acl_file_size: usize = 64 * 1024;

pub fn init(root_allocator: Allocator, acl_dir: []const u8) AclManager {
    return AclManager{
        .arena = ArenaAllocator.init(root_allocator) catch unreachable,
        .allocator = root_allocator,
        .acls = std.ArrayList(Acl).empty,
        .acl_dir = acl_dir,
    };
}

pub fn deinit(self: *AclManager) void {
    self.deinitAcls();

    if (self.acl_inotify_fd) |fd| {
        _ = linux.close(fd);
    }

    self.arena.deinit();
}

fn deinitAcls(self: *AclManager) void {
    const allocator = self.arena.allocator();
    for (self.acls.items) |*acl| {
        acl.deinit();
    }
    self.acls.deinit(allocator);
}

/// Set up inotify watch on acl_dir and perform initial load.
/// Should be called after init().
pub fn startWatching(self: *AclManager, io: std.Io) void {
    self.loadFromDir(io);
    self.setupInotify(io);
}

fn setupInotify(self: *AclManager, io: std.Io) void {
    _ = io;
    const init_rc = linux.inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (std.posix.errno(init_rc) != .SUCCESS) {
        log.warn("Failed to create inotify fd for ACL directory: {s}", .{@tagName(std.posix.errno(init_rc))});
        return;
    }
    const ifd: std.posix.fd_t = @intCast(init_rc);

    // inotify_add_watch requires [*:0]const u8 - create sentinel-terminated copy
    const acl_dir_z = self.arena.allocator().allocSentinel(u8, self.acl_dir.len, 0) catch {
        log.warn("Failed to allocate ACL dir path for inotify", .{});
        _ = linux.close(ifd);
        return;
    };
    @memcpy(acl_dir_z, self.acl_dir);

    const wd_rc = linux.inotify_add_watch(ifd, acl_dir_z, IN_CREATE | IN_DELETE | IN_MODIFY | IN_MOVED_FROM | IN_MOVED_TO | IN_CLOSE_WRITE);
    if (std.posix.errno(wd_rc) != .SUCCESS) {
        log.warn("Failed to add inotify watch on ACL directory '{s}': {s}", .{ self.acl_dir, @tagName(std.posix.errno(wd_rc)) });
        _ = linux.close(ifd);
        return;
    }

    self.acl_inotify_fd = ifd;
    log.info("Watching ACL directory: {s}", .{self.acl_dir});
}

/// Scan ACL directory and build a new ACL list from all .json files.
/// Caller is responsible for thread safety — must either hold the mutex
/// or be in a single-threaded context (e.g. initial load).
fn scanAclDir(self: *AclManager, io: std.Io) ?std.ArrayList(Acl) {
    const arena_allocator = self.arena.allocator();

    var new_acls = std.ArrayList(Acl).empty;

    var dir = std.Io.Dir.cwd().openDir(io, self.acl_dir, .{ .iterate = true }) catch |err| {
        log.warn("Failed to open ACL directory '{s}': {s}", .{ self.acl_dir, @errorName(err) });
        return null;
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;

        // Only process .json files
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const file_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.acl_dir, entry.name }) catch continue;

        self.loadAclFile(io, arena_allocator, &new_acls, file_path, entry.name);
    }

    return new_acls;
}

/// Load all ACL entries from files in the ACL directory.
/// Replaces the current ACL set atomically (acquires mutex internally).
pub fn loadFromDir(self: *AclManager, io: std.Io) void {
    const new_acls = self.scanAclDir(io) orelse return;

    // Atomically swap: lock, replace, unlock
    self.mutex.lock(io) catch return;
    self.deinitAcls();
    self.acls = new_acls;
    self.mutex.unlock(io);

    log.info("Loaded {} ACL entries from {s}", .{ self.acls.items.len, self.acl_dir });
}

fn loadAclFile(self: *AclManager, io: std.Io, allocator: Allocator, acls: *std.ArrayList(Acl), file_path: []const u8, filename: []const u8) void {
    // Read file
    var file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch |err| {
        log.warn("Failed to open ACL file '{s}': {s}", .{ filename, @errorName(err) });
        return;
    };
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    const buf = file_reader.interface.allocRemaining(allocator, .limited(max_acl_file_size)) catch |err| {
        log.warn("Failed to read ACL file '{s}': {s}", .{ filename, @errorName(err) });
        return;
    };
    defer allocator.free(buf);

    // Parse JSON
    const parsed = AclFile.parseFromSlice(allocator, buf) catch |err| {
        log.warn("Failed to parse ACL file '{s}': {s}", .{ filename, @errorName(err) });
        return;
    };
    defer parsed.deinit();

    const acl_entry = parsed.value;

    // Must have at least user or group
    if (acl_entry.user == null and acl_entry.group == null) {
        log.warn("ACL file '{s}' has no user or group specified, skipping", .{filename});
        return;
    }

    if (acl_entry.grants.len == 0) {
        log.warn("ACL file '{s}' has no grants, skipping", .{filename});
        return;
    }

    // Process each grant
    for (acl_entry.grants) |grant| {
        self.addGrantToAcl(allocator, acls, grant.resource, .{
            .user = acl_entry.user,
            .group = acl_entry.group,
            .ips = grant.ips,
        }) catch |err| {
            log.warn("Failed to process grant in ACL file '{s}' for resource '{s}': {s}", .{ filename, grant.resource, @errorName(err) });
        };
    }
}

/// Find or create an Acl for the given resource name, then add the grant.
fn addGrantToAcl(self: *AclManager, allocator: Allocator, acls: *std.ArrayList(Acl), resource_name: []const u8, grant_data: Acl.GrantData) !void {
    _ = self;

    // Find existing Acl for this resource
    for (acls.items) |*acl| {
        if (std.mem.eql(u8, acl.name, resource_name)) {
            try acl.addGrant(allocator, grant_data);
            return;
        }
    }

    // Create new Acl for this resource
    const name = try allocator.dupe(u8, resource_name);
    var acl = Acl.init(allocator, name);
    try acl.addGrant(allocator, grant_data);
    try acls.append(allocator, acl);
}

/// Process pending inotify events from the ACL directory.
/// Returns true if any events were processed (indicating a reload is needed).
pub fn processInotifyEvents(self: *AclManager, event_buf: []u8) bool {
    const fd = self.acl_inotify_fd orelse return false;
    var changed = false;

    while (true) {
        const n = std.posix.read(fd, event_buf) catch |err| {
            log.warn("Failed to read ACL inotify events: {s}", .{@errorName(err)});
            return changed;
        };
        if (n == 0) return changed;

        var offset: usize = 0;
        while (offset < n) {
            const event_ptr: *align(4) std.os.linux.inotify_event = @ptrCast(@alignCast(event_buf[offset..].ptr));
            const event = event_ptr.*;
            offset += @sizeOf(std.os.linux.inotify_event) + event.len;
            changed = true;
        }
    }
}

/// Reload ACLs from the directory. Called after inotify events.
/// Thread-safe: acquires mutex before freeing old data to prevent
/// use-after-free from concurrent handler threads.
pub fn reload(self: *AclManager, io: std.Io) void {
    log.info("Reloading ACL directory: {s}", .{self.acl_dir});

    // Acquire mutex BEFORE freeing old data — prevents concurrent handlers
    // from accessing ACL data while we tear down and rebuild.
    self.mutex.lock(io) catch return;
    defer self.mutex.unlock(io);

    // Properly clean up ACL objects while their memory is still valid
    self.deinitAcls();

    // Free all arena memory (ACL internals already deinited above)
    self.arena.deinit();
    self.arena = ArenaAllocator.init(self.allocator) catch {
        log.err("Failed to create arena for ACL reload", .{});
        return;
    };
    self.acls = std.ArrayList(Acl).empty;

    // Rebuild from directory (already under mutex — handler threads are blocked)
    if (self.scanAclDir(io)) |new_acls| {
        self.acls = new_acls;
    }

    log.info("Loaded {} ACL entries from {s}", .{ self.acls.items.len, self.acl_dir });
}

/// Get all allowed UIDs derived from current ACLs.
/// Used by SocketManager to know which UIDs to create sockets for.
pub fn getAllowedUids(self: *AclManager, io: std.Io, allocator: Allocator) std.ArrayList(u32) {
    self.mutex.lock(io) catch return .empty;
    defer self.mutex.unlock(io);

    var uid_set = std.AutoHashMap(u32, void).init(allocator);
    defer uid_set.deinit();

    for (self.acls.items) |acl| {
        for (acl.allow_uids.items) |uid| {
            uid_set.put(uid, {}) catch {};
        }
    }

    var result = std.ArrayList(u32).initCapacity(allocator, uid_set.count()) catch return .empty;
    var iter = uid_set.keyIterator();
    while (iter.next()) |uid| {
        result.appendAssumeCapacity(uid.*);
    }
    return result;
}

// ============================================================
// Query methods (thread-safe via mutex)
// ============================================================

pub fn isAllowed(self: *AclManager, io: std.Io, name: []const u8, uid: u32, gid: u32) bool {
    self.mutex.lock(io) catch return false;
    defer self.mutex.unlock(io);

    for (self.acls.items) |acl| {
        if (std.mem.eql(u8, name, acl.name)) {
            return acl.isAllowed(uid, gid);
        }
    }
    return false;
}

/// Check if a uid has permission to access any resource.
/// Used for socket-level pre-filtering.
pub fn hasAnyPermission(self: *AclManager, io: std.Io, uid: u32, gid: u32) bool {
    self.mutex.lock(io) catch return false;
    defer self.mutex.unlock(io);

    for (self.acls.items) |acl| {
        if (acl.isAllowed(uid, gid)) {
            return true;
        }
    }
    return false;
}

/// Check if a resource is a static IP resource (has IP constraints).
pub fn isStaticResource(self: *AclManager, io: std.Io, name: []const u8) bool {
    self.mutex.lock(io) catch return false;
    defer self.mutex.unlock(io);

    for (self.acls.items) |acl| {
        if (std.mem.eql(u8, name, acl.name)) {
            return acl.isStatic();
        }
    }
    return false;
}

/// Check if a uid is allowed to use the given IP on the specified resource.
pub fn isIpAllowed(self: *AclManager, io: std.Io, name: []const u8, uid: u32, ip: []const u8) bool {
    self.mutex.lock(io) catch return false;
    defer self.mutex.unlock(io);

    for (self.acls.items) |acl| {
        if (std.mem.eql(u8, name, acl.name)) {
            return acl.isIpAllowed(uid, ip);
        }
    }
    return false;
}

// ============================================================
// Tests
// ============================================================

test "AclManager: loadFromDir with no directory returns empty" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var manager = init(allocator, "/nonexistent/acl/directory");
    defer manager.deinit();

    manager.loadFromDir(io);
    try std.testing.expectEqual(@as(usize, 0), manager.acls.items.len);
}

test "AclManager: getAllowedUids returns deduplicated UIDs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var manager = init(allocator, "/nonexistent");
    defer manager.deinit();

    // Manually build ACLs for testing
    const arena_allocator = manager.arena.allocator();

    var acl1 = Acl.init(arena_allocator, "resource-a");
    try acl1.addGrant(arena_allocator, .{ .user = "1000" });
    try acl1.addGrant(arena_allocator, .{ .user = "1001" });
    try manager.acls.append(arena_allocator, acl1);

    var acl2 = Acl.init(arena_allocator, "resource-b");
    try acl2.addGrant(arena_allocator, .{ .user = "1000" }); // duplicate
    try acl2.addGrant(arena_allocator, .{ .user = "1002" });
    try manager.acls.append(arena_allocator, acl2);

    var uids = manager.getAllowedUids(io, allocator);
    defer uids.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), uids.items.len);
}

test "AclManager: isAllowed checks resource-level access" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var manager = init(allocator, "/nonexistent");
    defer manager.deinit();

    const arena_allocator = manager.arena.allocator();

    var acl = Acl.init(arena_allocator, "test-resource");
    try acl.addGrant(arena_allocator, .{ .user = "1000" });
    try manager.acls.append(arena_allocator, acl);

    try std.testing.expect(manager.isAllowed(io, "test-resource", 1000, 1000));
    try std.testing.expect(!manager.isAllowed(io, "test-resource", 2000, 2000));
    try std.testing.expect(!manager.isAllowed(io, "other-resource", 1000, 1000));
}

test "AclManager: hasAnyPermission checks across all resources" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var manager = init(allocator, "/nonexistent");
    defer manager.deinit();

    const arena_allocator = manager.arena.allocator();

    var acl1 = Acl.init(arena_allocator, "net-a");
    try acl1.addGrant(arena_allocator, .{ .user = "1000" });
    try manager.acls.append(arena_allocator, acl1);

    var acl2 = Acl.init(arena_allocator, "net-b");
    try acl2.addGrant(arena_allocator, .{ .group = "100" });
    try manager.acls.append(arena_allocator, acl2);

    try std.testing.expect(manager.hasAnyPermission(io, 1000, 1000));
    try std.testing.expect(!manager.hasAnyPermission(io, 999, 999));
    try std.testing.expect(manager.hasAnyPermission(io, 100, 100));
}

test "AclManager: isStaticResource and isIpAllowed" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var manager = init(allocator, "/nonexistent");
    defer manager.deinit();

    const arena_allocator = manager.arena.allocator();

    var dhcp_acl = Acl.init(arena_allocator, "dhcp-net");
    try dhcp_acl.addGrant(arena_allocator, .{ .user = "1000" });
    try manager.acls.append(arena_allocator, dhcp_acl);

    var static_acl = Acl.init(arena_allocator, "static-net");
    try static_acl.addGrant(arena_allocator, .{
        .user = "1000",
        .ips = &[_][:0]const u8{"192.168.1.10-192.168.1.20"},
    });
    try manager.acls.append(arena_allocator, static_acl);

    try std.testing.expect(!manager.isStaticResource(io, "dhcp-net"));
    try std.testing.expect(manager.isStaticResource(io, "static-net"));
    try std.testing.expect(!manager.isStaticResource(io, "not-exists"));

    try std.testing.expect(manager.isIpAllowed(io, "static-net", 1000, "192.168.1.15"));
    try std.testing.expect(!manager.isIpAllowed(io, "static-net", 1000, "192.168.1.30"));
    try std.testing.expect(!manager.isIpAllowed(io, "dhcp-net", 1000, "192.168.1.15"));
}

test "AclManager: addGrantToAcl merges grants for same resource" {
    const allocator = std.testing.allocator;
    var manager = init(allocator, "/nonexistent");
    defer manager.deinit();

    const arena_allocator = manager.arena.allocator();
    var acls = std.ArrayList(Acl).empty;

    try manager.addGrantToAcl(arena_allocator, &acls, "shared-net", .{ .user = "1000" });
    try manager.addGrantToAcl(arena_allocator, &acls, "shared-net", .{ .user = "2000" });
    try manager.addGrantToAcl(arena_allocator, &acls, "other-net", .{ .user = "1000" });

    try std.testing.expectEqual(@as(usize, 2), acls.items.len);

    // shared-net should have 2 users
    try std.testing.expectEqualSlices(u8, "shared-net", acls.items[0].name);
    try std.testing.expectEqual(@as(usize, 2), acls.items[0].allow_uids.items.len);

    // other-net should have 1 user
    try std.testing.expectEqualSlices(u8, "other-net", acls.items[1].name);
    try std.testing.expectEqual(@as(usize, 1), acls.items[1].allow_uids.items.len);

    for (acls.items) |*acl| {
        acl.deinit();
    }
    acls.deinit(arena_allocator);
}

test "AclManager: IP ranges scoped to correct resource" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var manager = init(allocator, "/nonexistent");
    defer manager.deinit();

    const arena_allocator = manager.arena.allocator();

    var static_a = Acl.init(arena_allocator, "static-a");
    try static_a.addGrant(arena_allocator, .{
        .user = "1000",
        .ips = &[_][:0]const u8{"10.0.0.5-10.0.0.10"},
    });
    try manager.acls.append(arena_allocator, static_a);

    var static_b = Acl.init(arena_allocator, "static-b");
    try static_b.addGrant(arena_allocator, .{
        .user = "1000",
        .ips = &[_][:0]const u8{"192.168.1.5-192.168.1.10"},
    });
    try manager.acls.append(arena_allocator, static_b);

    // Same uid, different ranges on different resources
    try std.testing.expect(manager.isIpAllowed(io, "static-a", 1000, "10.0.0.7"));
    try std.testing.expect(!manager.isIpAllowed(io, "static-a", 1000, "192.168.1.7"));

    try std.testing.expect(!manager.isIpAllowed(io, "static-b", 1000, "10.0.0.7"));
    try std.testing.expect(manager.isIpAllowed(io, "static-b", 1000, "192.168.1.7"));
}

// ============================================================
// File-based integration tests
// ============================================================

/// Helper to create a temporary directory for ACL testing.
const TestAclDir = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    dir_path: []const u8,

    fn create(io: std.Io, allocator: std.mem.Allocator) !TestAclDir {
        var prng = std.Random.DefaultPrng.init(@intCast(std.os.linux.getpid()));
        const rand = prng.random().int(u64);
        const dir_path = try std.fmt.allocPrint(allocator, "/tmp/acl-test-{x:0>16}", .{rand});
        try std.Io.Dir.cwd().createDirPath(io, dir_path);
        return TestAclDir{ .io = io, .allocator = allocator, .dir_path = dir_path };
    }

    fn deinit(self: TestAclDir) void {
        // Remove all .json files first
        var dir = std.Io.Dir.cwd().openDir(self.io, self.dir_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var iter = dir.iterate();
        while (iter.next(self.io) catch null) |entry| {
            dir.deleteFile(self.io, entry.name) catch {};
        }
        std.Io.Dir.cwd().deleteDir(self.io, self.dir_path) catch {};
        self.allocator.free(self.dir_path);
    }

    fn writeFile(self: TestAclDir, filename: []const u8, content: []const u8) !void {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const file_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.dir_path, filename }) catch return;
        const file = try std.Io.Dir.cwd().createFile(self.io, file_path, .{});
        defer file.close(self.io);
        var write_buffer: [4096]u8 = undefined;
        var writer = file.writer(self.io, &write_buffer);
        writer.interface.writeAll(content) catch return;
        writer.end() catch return;
    }
};

test "AclManager: loadFromDir loads single user ACL file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_dir = try TestAclDir.create(io, allocator);
    defer test_dir.deinit();

    try test_dir.writeFile("jellyfin.json",
        \\{"user":"1000","grants":[{"resource":"macvlan-dhcp"}]}
    );

    var manager = init(allocator, test_dir.dir_path);
    defer manager.deinit();
    manager.loadFromDir(io);

    try std.testing.expectEqual(@as(usize, 1), manager.acls.items.len);
    try std.testing.expect(manager.isAllowed(io, "macvlan-dhcp", 1000, 1000));
    try std.testing.expect(!manager.isAllowed(io, "macvlan-dhcp", 2000, 2000));
    try std.testing.expect(!manager.isAllowed(io, "other-resource", 1000, 1000));
}

test "AclManager: loadFromDir loads multiple users for same resource" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_dir = try TestAclDir.create(io, allocator);
    defer test_dir.deinit();

    try test_dir.writeFile("alice.json",
        \\{"user":"1000","grants":[{"resource":"macvlan-dhcp"}]}
    );
    try test_dir.writeFile("bob.json",
        \\{"user":"1001","grants":[{"resource":"macvlan-dhcp"}]}
    );

    var manager = init(allocator, test_dir.dir_path);
    defer manager.deinit();
    manager.loadFromDir(io);

    // Both users should be on the same resource
    try std.testing.expect(manager.isAllowed(io, "macvlan-dhcp", 1000, 1000));
    try std.testing.expect(manager.isAllowed(io, "macvlan-dhcp", 1001, 1001));
    try std.testing.expect(!manager.isAllowed(io, "macvlan-dhcp", 999, 999));
}

test "AclManager: loadFromDir loads user with multiple resources and IPs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_dir = try TestAclDir.create(io, allocator);
    defer test_dir.deinit();

    try test_dir.writeFile("alice.json",
        \\{
        \\  "user": "1000",
        \\  "grants": [
        \\    { "resource": "macvlan-dhcp" },
        \\    { "resource": "bridge-static", "ips": ["192.168.1.10-192.168.1.20"] }
        \\  ]
        \\}
    );

    var manager = init(allocator, test_dir.dir_path);
    defer manager.deinit();
    manager.loadFromDir(io);

    try std.testing.expectEqual(@as(usize, 2), manager.acls.items.len);
    try std.testing.expect(manager.isAllowed(io, "macvlan-dhcp", 1000, 1000));
    try std.testing.expect(manager.isAllowed(io, "bridge-static", 1000, 1000));
    try std.testing.expect(!manager.isStaticResource(io, "macvlan-dhcp"));
    try std.testing.expect(manager.isStaticResource(io, "bridge-static"));
    try std.testing.expect(manager.isIpAllowed(io, "bridge-static", 1000, "192.168.1.15"));
    try std.testing.expect(!manager.isIpAllowed(io, "bridge-static", 1000, "192.168.1.25"));
}

test "AclManager: loadFromDir loads group-based ACL" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_dir = try TestAclDir.create(io, allocator);
    defer test_dir.deinit();

    try test_dir.writeFile("media-group.json",
        \\{"group":"100","grants":[{"resource":"macvlan-dhcp"}]}
    );

    var manager = init(allocator, test_dir.dir_path);
    defer manager.deinit();
    manager.loadFromDir(io);

    try std.testing.expect(manager.isAllowed(io, "macvlan-dhcp", 0, 100));
    try std.testing.expect(!manager.isAllowed(io, "macvlan-dhcp", 0, 999));
}

test "AclManager: loadFromDir with both user and group in same file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_dir = try TestAclDir.create(io, allocator);
    defer test_dir.deinit();

    try test_dir.writeFile("mixed.json",
        \\{
        \\  "user": "1000",
        \\  "group": "100",
        \\  "grants": [{"resource": "shared-net"}]
        \\}
    );

    var manager = init(allocator, test_dir.dir_path);
    defer manager.deinit();
    manager.loadFromDir(io);

    // Should allow both by UID and by GID
    try std.testing.expect(manager.isAllowed(io, "shared-net", 1000, 0));
    try std.testing.expect(manager.isAllowed(io, "shared-net", 0, 100));
    try std.testing.expect(!manager.isAllowed(io, "shared-net", 999, 999));
}

test "AclManager: loadFromDir skips malformed JSON file and loads valid ones" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_dir = try TestAclDir.create(io, allocator);
    defer test_dir.deinit();

    try test_dir.writeFile("valid.json",
        \\{"user":"1000","grants":[{"resource":"net-a"}]}
    );
    try test_dir.writeFile("broken.json", "{not valid json!!!");
    try test_dir.writeFile("also-valid.json",
        \\{"user":"1001","grants":[{"resource":"net-b"}]}
    );

    var manager = init(allocator, test_dir.dir_path);
    defer manager.deinit();
    manager.loadFromDir(io);

    // Valid files should be loaded, broken one skipped
    try std.testing.expect(manager.isAllowed(io, "net-a", 1000, 1000));
    try std.testing.expect(manager.isAllowed(io, "net-b", 1001, 1001));
    try std.testing.expectEqual(@as(usize, 2), manager.acls.items.len);
}

test "AclManager: loadFromDir skips file with no user or group" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_dir = try TestAclDir.create(io, allocator);
    defer test_dir.deinit();

    try test_dir.writeFile("no-identity.json",
        \\{"grants":[{"resource":"net-a"}]}
    );

    var manager = init(allocator, test_dir.dir_path);
    defer manager.deinit();
    manager.loadFromDir(io);

    try std.testing.expectEqual(@as(usize, 0), manager.acls.items.len);
}

test "AclManager: loadFromDir skips file with empty grants" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_dir = try TestAclDir.create(io, allocator);
    defer test_dir.deinit();

    try test_dir.writeFile("empty-grants.json",
        \\{"user":"1000","grants":[]}
    );

    var manager = init(allocator, test_dir.dir_path);
    defer manager.deinit();
    manager.loadFromDir(io);

    try std.testing.expectEqual(@as(usize, 0), manager.acls.items.len);
}

test "AclManager: loadFromDir skips non-.json files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_dir = try TestAclDir.create(io, allocator);
    defer test_dir.deinit();

    try test_dir.writeFile("jellyfin.json",
        \\{"user":"1000","grants":[{"resource":"net-a"}]}
    );
    try test_dir.writeFile("readme.txt", "This should be ignored");
    try test_dir.writeFile("backup.json.bak",
        \\{"user":"1001","grants":[{"resource":"net-b"}]}
    );

    var manager = init(allocator, test_dir.dir_path);
    defer manager.deinit();
    manager.loadFromDir(io);

    // Only .json file should be loaded
    try std.testing.expectEqual(@as(usize, 1), manager.acls.items.len);
    try std.testing.expect(manager.isAllowed(io, "net-a", 1000, 1000));
    try std.testing.expect(!manager.isAllowed(io, "net-b", 1001, 1001));
}

test "AclManager: reload replaces existing ACLs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_dir = try TestAclDir.create(io, allocator);
    defer test_dir.deinit();

    // Initial load
    try test_dir.writeFile("alice.json",
        \\{"user":"1000","grants":[{"resource":"net-a"}]}
    );

    var manager = init(allocator, test_dir.dir_path);
    defer manager.deinit();
    manager.loadFromDir(io);

    try std.testing.expect(manager.isAllowed(io, "net-a", 1000, 1000));
    try std.testing.expectEqual(@as(usize, 1), manager.acls.items.len);

    // Add a new user and reload
    try test_dir.writeFile("bob.json",
        \\{"user":"1001","grants":[{"resource":"net-a"},{"resource":"net-b"}]}
    );

    manager.reload(io);

    // Both users should be present
    try std.testing.expect(manager.isAllowed(io, "net-a", 1000, 1000));
    try std.testing.expect(manager.isAllowed(io, "net-a", 1001, 1001));
    try std.testing.expect(manager.isAllowed(io, "net-b", 1001, 1001));
    try std.testing.expectEqual(@as(usize, 2), manager.acls.items.len);
}

test "AclManager: reload after deleting file removes grants" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_dir = try TestAclDir.create(io, allocator);
    defer test_dir.deinit();

    try test_dir.writeFile("alice.json",
        \\{"user":"1000","grants":[{"resource":"net-a"}]}
    );
    try test_dir.writeFile("bob.json",
        \\{"user":"1001","grants":[{"resource":"net-a"}]}
    );

    var manager = init(allocator, test_dir.dir_path);
    defer manager.deinit();
    manager.loadFromDir(io);

    try std.testing.expect(manager.isAllowed(io, "net-a", 1000, 1000));
    try std.testing.expect(manager.isAllowed(io, "net-a", 1001, 1001));

    // Delete bob's file and reload
    var dir = try std.Io.Dir.cwd().openDir(io, test_dir.dir_path, .{});
    defer dir.close(io);
    dir.deleteFile(io, "bob.json") catch {};

    manager.reload(io);

    // Only alice should remain
    try std.testing.expect(manager.isAllowed(io, "net-a", 1000, 1000));
    try std.testing.expect(!manager.isAllowed(io, "net-a", 1001, 1001));
    try std.testing.expectEqual(@as(usize, 1), manager.acls.items.len);
}

test "AclManager: getAllowedUids after loadFromDir" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_dir = try TestAclDir.create(io, allocator);
    defer test_dir.deinit();

    try test_dir.writeFile("alice.json",
        \\{"user":"1000","grants":[{"resource":"net-a"}]}
    );
    try test_dir.writeFile("bob.json",
        \\{"user":"1001","grants":[{"resource":"net-a"}]}
    );
    try test_dir.writeFile("charlie.json",
        \\{"user":"1000","grants":[{"resource":"net-b"}]}
    );

    var manager = init(allocator, test_dir.dir_path);
    defer manager.deinit();
    manager.loadFromDir(io);

    var uids = manager.getAllowedUids(io, allocator);
    defer uids.deinit(allocator);

    // alice (1000) appears in two files but should be deduplicated
    try std.testing.expectEqual(@as(usize, 2), uids.items.len);
}

test "AclManager: hasAnyPermission after file load" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_dir = try TestAclDir.create(io, allocator);
    defer test_dir.deinit();

    try test_dir.writeFile("alice.json",
        \\{"user":"1000","grants":[{"resource":"net-a"}]}
    );

    var manager = init(allocator, test_dir.dir_path);
    defer manager.deinit();
    manager.loadFromDir(io);

    try std.testing.expect(manager.hasAnyPermission(io, 1000, 1000));
    try std.testing.expect(!manager.hasAnyPermission(io, 999, 999));
}

test "AclManager: loadFromDir with IP ranges on DHCP resource" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_dir = try TestAclDir.create(io, allocator);
    defer test_dir.deinit();

    // IP ranges on DHCP resource - config loads fine, but runtime won't validate
    try test_dir.writeFile("alice.json",
        \\{
        \\  "user": "1000",
        \\  "grants": [
        \\    { "resource": "dhcp-net", "ips": ["10.0.0.1-10.0.0.100"] }
        \\  ]
        \\}
    );

    var manager = init(allocator, test_dir.dir_path);
    defer manager.deinit();
    manager.loadFromDir(io);

    // IP ranges are stored even for DHCP resources
    try std.testing.expect(manager.isStaticResource(io, "dhcp-net"));
    try std.testing.expect(manager.isIpAllowed(io, "dhcp-net", 1000, "10.0.0.50"));
}

test "AclManager: multiple grants for same resource from different files merge" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_dir = try TestAclDir.create(io, allocator);
    defer test_dir.deinit();

    try test_dir.writeFile("alice.json",
        \\{
        \\  "user": "1000",
        \\  "grants": [
        \\    { "resource": "shared", "ips": ["10.0.0.5-10.0.0.10"] }
        \\  ]
        \\}
    );
    try test_dir.writeFile("bob.json",
        \\{
        \\  "user": "1001",
        \\  "grants": [
        \\    { "resource": "shared", "ips": ["192.168.1.50"] }
        \\  ]
        \\}
    );

    var manager = init(allocator, test_dir.dir_path);
    defer manager.deinit();
    manager.loadFromDir(io);

    // Single resource with merged grants from two files
    try std.testing.expectEqual(@as(usize, 1), manager.acls.items.len);

    // Alice's IP range
    try std.testing.expect(manager.isIpAllowed(io, "shared", 1000, "10.0.0.7"));
    try std.testing.expect(!manager.isIpAllowed(io, "shared", 1000, "192.168.1.50"));

    // Bob's IP
    try std.testing.expect(manager.isIpAllowed(io, "shared", 1001, "192.168.1.50"));
    try std.testing.expect(!manager.isIpAllowed(io, "shared", 1001, "10.0.0.7"));
}

test "AclManager: processInotifyEvents returns false when no inotify fd" {
    const allocator = std.testing.allocator;
    var manager = init(allocator, "/nonexistent");
    defer manager.deinit();

    var buf: [4096]u8 = undefined;
    try std.testing.expect(!manager.processInotifyEvents(&buf));
}
