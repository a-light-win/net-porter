//! Worker-side ACL manager.
//!
//! Loads a single user's ACL file + referenced group ACLs.
//! Watches the ACL directory for changes and hot-reloads.
//!
//! ACL file naming convention:
//!   User:  acl.d/<username>.json   — grants + optional "groups" field
//!   Group: acl.d/@<groupname>.json — grants only (rule collections)
//!
//! User ACL format:
//!   {
//!     "grants": [ { "resource": "tenant-a", "ips": [...] } ],
//!     "groups": ["dhcp-users", "static-users"]
//!   }
//!
//! Group ACL format:
//!   {
//!     "grants": [ { "resource": "dhcp-net" } ]
//!   }
//!
//! Effective permissions = user grants ∪ all referenced group grants.

const std = @import("std");
const log = std.log.scoped(.worker);
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const AclFile = @import("../server/AclFile.zig");
const Acl = @import("../server/Acl.zig");
const ArenaAllocator = @import("../utils/ArenaAllocator.zig");
const WorkerAclManager = @This();

const max_acl_file_size: usize = 64 * 1024;

// inotify bits
const IN_CREATE: u32 = 0x00000100;
const IN_DELETE: u32 = 0x00000200;
const IN_MODIFY: u32 = 0x00000002;
const IN_MOVED_FROM: u32 = 0x00000040;
const IN_MOVED_TO: u32 = 0x00000080;
const IN_CLOSE_WRITE: u32 = 0x00000008;
const IN_NONBLOCK: u32 = 0x800;
const IN_CLOEXEC: u32 = 0x80000;

arena: ArenaAllocator,
allocator: Allocator,
io: std.Io,
acl_dir: []const u8,
username: []const u8,
uid: u32,
/// Effective ACLs: user grants + all referenced group grants.
acls: std.ArrayList(Acl),
/// Group names referenced by the user ACL.
group_names: std.ArrayList([]const u8),
/// inotify fd for watching acl_dir.
inotify_fd: ?std.posix.fd_t = null,
mutex: std.Io.Mutex = .init,

pub fn init(allocator: Allocator, io: std.Io, acl_dir: []const u8, username: []const u8, uid: u32) WorkerAclManager {
    return .{
        .arena = ArenaAllocator.init(allocator) catch unreachable,
        .allocator = allocator,
        .io = io,
        .acl_dir = acl_dir,
        .username = username,
        .uid = uid,
        .acls = .empty,
        .group_names = .empty,
    };
}

pub fn deinit(self: *WorkerAclManager) void {
    self.deinitAcls();
    if (self.inotify_fd) |fd| {
        _ = linux.close(fd);
    }
    self.arena.deinit();
}

fn deinitAcls(self: *WorkerAclManager) void {
    const arena_alloc = self.arena.allocator();
    for (self.acls.items) |*acl| {
        acl.deinit();
    }
    self.acls.deinit(arena_alloc);
    self.group_names.deinit(arena_alloc);
}

/// Load user ACL + referenced groups. Should be called once at startup.
pub fn load(self: *WorkerAclManager) void {
    self.doLoad();
    self.setupInotify();
}

/// Reload from disk (e.g. after inotify event).
pub fn reload(self: *WorkerAclManager) void {
    log.info("Reloading ACL for uid={d} (username={s})", .{ self.uid, self.username });
    self.mutex.lock(self.io) catch return;
    defer self.mutex.unlock(self.io);

    self.deinitAcls();
    self.arena.deinit();
    self.arena = ArenaAllocator.init(self.allocator) catch return;
    self.acls = .empty;
    self.group_names = .empty;

    self.doLoad();
}

fn doLoad(self: *WorkerAclManager) void {
    const arena_alloc = self.arena.allocator();

    // 1. Load user ACL file: <acl_dir>/<username>.json
    const user_path = std.fmt.allocPrint(arena_alloc, "{s}/{s}.json", .{ self.acl_dir, self.username }) catch return;

    const user_entry = self.parseAclFile(user_path) catch |err| {
        log.warn("Failed to load user ACL {s}: {s}", .{ user_path, @errorName(err) });
        return;
    };
    defer user_entry.deinit();

    // 2. Add user grants as ACLs
    self.addGrantsFromEntry(arena_alloc, user_entry.value) catch return;

    // 3. Load referenced groups
    if (user_entry.value.groups) |groups| {
        for (groups) |group_name| {
            // Store the group name for later reference
            const name_copy = arena_alloc.dupe(u8, group_name) catch continue;
            self.group_names.append(arena_alloc, name_copy) catch continue;

            // Load group file: <acl_dir>/@<groupname>.json
            const group_path = std.fmt.allocPrint(arena_alloc, "{s}/@{s}.json", .{ self.acl_dir, group_name }) catch continue;
            const group_entry = self.parseAclFile(group_path) catch |err| {
                log.warn("Group '@{s}' not found ({s}), skipping", .{ group_name, @errorName(err) });
                continue;
            };
            defer group_entry.deinit();

            self.addGrantsFromEntry(arena_alloc, group_entry.value) catch continue;
            log.info("Loaded group '@{s}': {} grants", .{ group_name, group_entry.value.grants.len });
        }
    }

    log.info("Loaded ACL for uid={d}: {} grants, {} groups", .{ self.uid, self.acls.items.len, self.group_names.items.len });
}

fn parseAclFile(self: WorkerAclManager, path: []const u8) !std.json.Parsed(AclFile.Entry) {
    var file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
    defer file.close(self.io);

    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(self.io, &read_buffer);
    const data = try file_reader.interface.allocRemaining(std.heap.page_allocator, .limited(max_acl_file_size));
    defer std.heap.page_allocator.free(data);

    return try std.json.parseFromSlice(AclFile.Entry, std.heap.page_allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

fn addGrantsFromEntry(self: *WorkerAclManager, arena_alloc: Allocator, entry: AclFile.Entry) !void {
    for (entry.grants) |grant| {
        // Copy resource name into arena — parsed data will be freed by caller.
        const resource_name = try arena_alloc.dupe(u8, grant.resource);
        var acl = Acl.init(arena_alloc, resource_name);
        // IP ranges from the grant are associated with this worker's UID.
        if (grant.ips) |ips| {
            const ranges = try Acl.parseIpRanges(arena_alloc, ips);
            try acl.ip_ranges.put(self.uid, ranges);
        }
        try self.acls.append(arena_alloc, acl);
    }
}

fn setupInotify(self: *WorkerAclManager) void {
    const init_rc = linux.inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (std.posix.errno(init_rc) != .SUCCESS) return;
    const ifd: std.posix.fd_t = @intCast(init_rc);
    errdefer _ = linux.close(ifd);

    const acl_dir_z = self.arena.allocator().allocSentinel(u8, self.acl_dir.len, 0) catch return;
    @memcpy(acl_dir_z[0..self.acl_dir.len], self.acl_dir);

    const wd_rc = linux.inotify_add_watch(ifd, acl_dir_z, IN_CREATE | IN_DELETE | IN_MODIFY | IN_MOVED_FROM | IN_MOVED_TO | IN_CLOSE_WRITE);
    if (std.posix.errno(wd_rc) != .SUCCESS) {
        _ = linux.close(ifd);
        return;
    }

    self.inotify_fd = ifd;
    log.info("Watching ACL directory: {s}", .{self.acl_dir});
}

/// Process pending inotify events. Returns true if relevant files changed.
pub fn processInotifyEvents(self: *WorkerAclManager, event_buf: []u8) bool {
    const fd = self.inotify_fd orelse return false;
    var changed = false;

    while (true) {
        const n = std.posix.read(fd, event_buf) catch |err| switch (err) {
            error.WouldBlock => return changed,
            else => return changed,
        };
        if (n == 0) return changed;

        var offset: usize = 0;
        while (offset < n) {
            const event_ptr: *align(4) std.os.linux.inotify_event = @ptrCast(@alignCast(event_buf[offset..].ptr));
            const event = event_ptr.*;
            offset += @sizeOf(std.os.linux.inotify_event) + event.len;

            if (event.len == 0) continue;

            const name_start = offset - event.len;
            const name = std.mem.sliceTo(event_buf[name_start..], 0);

            // Check if the changed file is relevant to this worker:
            // - <username>.json (user's own ACL)
            // - @<groupname>.json where groupname is in our group_names
            if (isRelevantFile(self.username, self.group_names.items, name)) {
                log.info("ACL file changed: {s}, reloading", .{name});
                changed = true;
            }
        }
    }
}

/// Get the inotify fd for polling (returns null if not watching).
pub fn getInotifyFd(self: WorkerAclManager) ?std.posix.fd_t {
    return self.inotify_fd;
}

fn isRelevantFile(username: []const u8, group_names: []const []const u8, filename: []const u8) bool {
    // Check if it's the user's own file: <username>.json
    if (std.mem.endsWith(u8, filename, ".json") and
        std.mem.eql(u8, filename[0 .. filename.len - ".json".len], username))
        return true;

    // Check if it's a referenced group file: @<groupname>.json
    for (group_names) |group_name| {
        if (filename.len > 0 and filename[0] == '@' and
            std.mem.endsWith(u8, filename, ".json") and
            filename.len == 1 + group_name.len + ".json".len and
            std.mem.eql(u8, filename[1 .. filename.len - ".json".len], group_name))
            return true;
    }

    return false;
}

// ============================================================
// Query methods (thread-safe via mutex)
// ============================================================

/// Check if the resource is allowed (per-user daemon: if it exists in ACL, it's allowed).
pub fn isAllowed(self: *WorkerAclManager, name: []const u8) bool {
    self.mutex.lock(self.io) catch return false;
    defer self.mutex.unlock(self.io);

    for (self.acls.items) |acl| {
        if (std.mem.eql(u8, name, acl.name)) {
            return true;
        }
    }
    return false;
}

/// Check if the worker has permission on any resource.
pub fn hasAnyPermission(self: *WorkerAclManager) bool {
    self.mutex.lock(self.io) catch return false;
    defer self.mutex.unlock(self.io);

    return self.acls.items.len > 0;
}

/// Check if a resource is a static IP resource.
pub fn isStaticResource(self: *WorkerAclManager, name: []const u8) bool {
    self.mutex.lock(self.io) catch return false;
    defer self.mutex.unlock(self.io);

    for (self.acls.items) |acl| {
        if (std.mem.eql(u8, name, acl.name)) {
            return acl.isStatic();
        }
    }
    return false;
}

/// Check if a uid is allowed to use the given IP on the specified resource.
pub fn isIpAllowed(self: *WorkerAclManager, name: []const u8, uid: u32, ip: []const u8) bool {
    self.mutex.lock(self.io) catch return false;
    defer self.mutex.unlock(self.io);

    for (self.acls.items) |acl| {
        if (std.mem.eql(u8, name, acl.name)) {
            return acl.isIpAllowed(uid, ip);
        }
    }
    return false;
}

test "isRelevantFile matches user file" {
    const groups = &[_][]const u8{"devops"};
    try std.testing.expect(isRelevantFile("alice", groups, "alice.json"));
    try std.testing.expect(!isRelevantFile("alice", groups, "bob.json"));
}

test "isRelevantFile matches group file" {
    const groups = &[_][]const u8{ "devops", "engineering" };
    try std.testing.expect(isRelevantFile("alice", groups, "@devops.json"));
    try std.testing.expect(isRelevantFile("alice", groups, "@engineering.json"));
    try std.testing.expect(!isRelevantFile("alice", groups, "@finance.json"));
}

test "isRelevantFile rejects non-matching patterns" {
    const groups = &[_][]const u8{"devops"};
    try std.testing.expect(!isRelevantFile("alice", groups, "alice.json.bak"));
    try std.testing.expect(!isRelevantFile("alice", groups, "README.md"));
    try std.testing.expect(!isRelevantFile("alice", groups, "alice"));
    try std.testing.expect(!isRelevantFile("alice", groups, ""));
}
