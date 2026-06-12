const std = @import("std");
const json = std.json;
const log = std.log.scoped(.cni);
const Allocator = std.mem.Allocator;
const ArenaAllocator = @import("../utils/ArenaAllocator.zig");
const CniConfig = @import("CniConfig.zig").CniConfig;

const max_plugin_output: usize = 4 * 1024 * 1024; // 4 MB

pub const max_stderr_log: usize = 2048;

/// Hard cap on CNI plugin execution time. A hanging plugin would otherwise
/// block a worker handler thread indefinitely; with max_concurrent_handlers=64,
/// 64 hanging plugins exhaust the handler pool and cause denial of service.
pub const CNI_PLUGIN_TIMEOUT_MS: i32 = 60_000;

pub fn shadowCopy(allocator: Allocator, src: json.ObjectMap) !json.ObjectMap {
    var new_obj = try json.ObjectMap.init(allocator, &.{}, &.{});
    var it = src.iterator();
    while (it.next()) |entry| {
        try new_obj.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), entry.value_ptr.*);
    }
    return new_obj;
}

pub const PluginConf = struct {
    conf: json.ObjectMap,
    arena: ?ArenaAllocator = null,
    result: ?std.ArrayList(u8) = null,
    stderr_result: ?std.ArrayList(u8) = null,

    pub const ValidateError = error{
        PluginTypeMissing,
        PluginTypeNotString,
    };

    pub fn init(root_allocator: Allocator, cni_config: CniConfig, obj: json.ObjectMap) !PluginConf {
        var arena = try ArenaAllocator.init(root_allocator);
        errdefer arena.deinit();

        const allocator = arena.allocator();
        const conf = try shadowCopy(allocator, obj);

        var plugin_conf = PluginConf{
            .arena = arena,
            .conf = conf,
        };

        try plugin_conf.setName(cni_config.name);
        try plugin_conf.setCniVersion(cni_config.cniVersion);

        return plugin_conf;
    }

    pub fn deinit(self: *PluginConf) void {
        const alloc = self.arena.?.allocator();
        self.conf.deinit(alloc);

        if (self.result) |*result| {
            const allocator = self.arena.?.allocator();
            result.deinit(allocator);
        }

        if (self.stderr_result) |*sr| {
            const allocator = self.arena.?.allocator();
            sr.deinit(allocator);
        }

        if (self.arena) |*arena| {
            arena.deinit();
        }
    }

    pub fn validate(self: PluginConf, cni_name: []const u8) ValidateError!void {
        const type_value = self.conf.get("type") orelse {
            log.warn(
                "The plugin type in cni config '{s}' is missing",
                .{cni_name},
            );
            return error.PluginTypeMissing;
        };

        switch (type_value) {
            .string => {},
            else => {
                log.warn(
                    "The plugin type in cni config '{s}' is not string",
                    .{cni_name},
                );
                return error.PluginTypeNotString;
            },
        }
    }

    pub fn getName(self: PluginConf) ?[]const u8 {
        const name = self.conf.get("name") orelse return null;
        return switch (name) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn getCniVersion(self: PluginConf) ?[]const u8 {
        const version = self.conf.get("cniVersion") orelse return null;
        return switch (version) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn getType(self: PluginConf) ?[]const u8 {
        const plugin_type = self.conf.get("type") orelse return null;
        return switch (plugin_type) {
            .string => |s| s,
            else => null,
        };
    }

    fn getIpamType(self: PluginConf) ?[]const u8 {
        const ipam = self.conf.get("ipam") orelse return null;
        const ipam_obj = switch (ipam) {
            .object => |obj| obj,
            else => return null,
        };
        const ipam_type = ipam_obj.get("type") orelse return null;
        return switch (ipam_type) {
            .string => |s| s,
            else => null,
        };
    }

    fn getIpamObject(self: PluginConf) ?json.ObjectMap {
        const ipam = self.conf.get("ipam") orelse return null;
        return switch (ipam) {
            .object => |obj| obj,
            else => null,
        };
    }

    pub fn getDhcpSocketPath(self: PluginConf) []const u8 {
        if (self.getIpamObject()) |ipam_obj| {
            if (ipam_obj.get("daemonSocketPath")) |socket| {
                if (socket == .string) return socket.string;
            }
        }
        return "/run/cni/dhcp.sock";
    }

    pub fn setDhcpSocketPath(self: *PluginConf, uid: u32) !void {
        const allocator = self.arena.?.allocator();

        const ipam_obj = self.getIpamObject() orelse return;

        if (ipam_obj.get("daemonSocketPath")) |_| {
            return;
        }

        const type_str = self.getIpamType() orelse return;

        const path = try std.fmt.allocPrint(
            allocator,
            "/run/net-porter/workers/{d}/dhcp.sock",
            .{uid},
        );

        var new_ipam = try json.ObjectMap.init(allocator, &.{}, &.{});
        try new_ipam.put(allocator, "type", .{ .string = type_str });
        try new_ipam.put(allocator, "daemonSocketPath", .{ .string = path });

        try self.conf.put(allocator, "ipam", .{ .object = new_ipam });
    }

    pub fn isDhcp(self: PluginConf) bool {
        const type_str = self.getIpamType() orelse return false;
        return std.mem.eql(u8, "dhcp", type_str);
    }

    pub fn isStatic(self: PluginConf) bool {
        const type_str = self.getIpamType() orelse return false;
        return std.mem.eql(u8, "static", type_str);
    }

    pub fn isMacvlan(self: PluginConf) bool {
        const plugin_type = self.getType() orelse return false;
        return std.mem.eql(u8, "macvlan", plugin_type);
    }

    fn isIpv6(addr: []const u8) bool {
        return std.mem.indexOf(u8, addr, ":") != null;
    }

    /// Find the index of a template address entry matching the given IP's address family.
    fn findMatchingSubnet(ip: []const u8, template_addrs: []const json.Value) ?usize {
        const ip_v6 = isIpv6(ip);
        for (template_addrs, 0..) |addr_val, i| {
            const addr_obj = switch (addr_val) {
                .object => |o| o,
                else => continue,
            };
            const addr_str = switch (addr_obj.get("address") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            if (isIpv6(addr_str) == ip_v6) return i;
        }
        return null;
    }

    /// Set the MAC address in the plugin's JSON config.
    /// The macvlan CNI plugin reads the "mac" key from its config and applies it
    /// at link creation time (before the interface is brought UP). This is the
    /// preferred injection method over CNI_ARGS because:
    ///   - Consistent with how patchAddresses() injects IPs into JSON config
    ///   - The MAC naturally appears in prevResult from ADD, available for DEL
    ///   - No string-injection risk from CNI_ARGS concatenation
    pub fn patchMacAddress(self: *PluginConf, mac: []const u8) !void {
        const allocator = self.arena.?.allocator();
        const mac_copy = try allocator.dupe(u8, mac);
        try self.conf.put(allocator, "mac", .{ .string = mac_copy });
        log.info("patched mac '{s}' into plugin config", .{mac_copy});
    }

    /// Replace template addresses in the ipam config with actual IPs.
    /// Requires an addresses array with CIDR templates in the CNI config.
    /// Routes, DNS, and other ipam fields are preserved from the CNI config as-is.
    pub fn patchAddresses(self: *PluginConf, ips: []const []const u8) !void {
        const allocator = self.arena.?.allocator();

        // Read ipam from this plugin's own config JSON
        const ipam = self.conf.get("ipam") orelse {
            log.debug("no ipam section, skipping patchAddresses", .{});
            return;
        };
        const ipam_obj = switch (ipam) {
            .object => |obj| obj,
            else => {
                log.debug("ipam is not an object, skipping", .{});
                return;
            },
        };

        // Only applicable to static IPAM
        const ipam_type = ipam_obj.get("type") orelse return;
        if (ipam_type != .string or !std.mem.eql(u8, "static", ipam_type.string)) {
            if (ipam_type == .string) {
                log.debug("ipam type is '{s}', not static, skipping", .{ipam_type.string});
            }
            return;
        }

        // Check for template addresses in the CNI config's ipam
        const maybe_template = ipam_obj.get("addresses") orelse {
            log.warn("ipam.addresses is missing in CNI config; static IPAM requires an addresses array with CIDR template", .{});
            return;
        };

        const template_addrs = switch (maybe_template) {
            .array => |a| a.items,
            else => {
                log.debug("ipam.addresses is not an array, skipping", .{});
                return;
            },
        };

        // Build actual addresses by matching requested IPs to template subnets by address family
        var new_addrs = try json.Array.initCapacity(allocator, ips.len);
        for (ips) |ip| {
            const idx = findMatchingSubnet(ip, template_addrs) orelse {
                log.warn("no matching subnet family for IP '{s}', skipping", .{ip});
                continue;
            };
            const tmpl_obj = template_addrs[idx].object;
            const tmpl_addr = switch (tmpl_obj.get("address") orelse continue) {
                .string => |s| s,
                else => {
                    log.warn("template address entry has non-string 'address' field, skipping", .{});
                    continue;
                },
            };

            // Extract prefix from template address (e.g. "192.168.1.0/24" → "24")
            const slash_pos = std.mem.lastIndexOf(u8, tmpl_addr, "/") orelse {
                log.warn("template address '{s}' has no prefix separator, skipping", .{tmpl_addr});
                continue;
            };
            const prefix = tmpl_addr[slash_pos + 1 ..];

            // Build actual address: "192.168.1.15/24"
            const actual_addr = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ip, prefix });

            var addr_obj = try json.ObjectMap.init(allocator, &.{}, &.{});
            try addr_obj.put(allocator, "address", .{ .string = actual_addr });
            // Copy gateway from template if present
            if (tmpl_obj.get("gateway")) |gw| {
                try addr_obj.put(allocator, "gateway", gw);
            }
            new_addrs.appendAssumeCapacity(.{ .object = addr_obj });
        }

        // Build new ipam: shadow-copy existing fields, replace only addresses
        var new_ipam = try shadowCopy(allocator, ipam_obj);
        try new_ipam.put(allocator, "addresses", .{ .array = new_addrs });
        try self.conf.put(allocator, "ipam", .{ .object = new_ipam });

        log.info("patched {d} address(es) into ipam config", .{new_addrs.items.len});
    }

    test "getName() returns null when field is missing" {
        const root_allocator = std.testing.allocator;
        var arena = try ArenaAllocator.init(root_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var plugin_conf = PluginConf{ .conf = try json.ObjectMap.init(allocator, &.{}, &.{}) };
        try std.testing.expect(plugin_conf.getName() == null);
    }

    test "getName() returns null when field is not a string" {
        const root_allocator = std.testing.allocator;
        var arena = try ArenaAllocator.init(root_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var plugin_conf = PluginConf{ .conf = try json.ObjectMap.init(allocator, &.{}, &.{}) };
        try plugin_conf.conf.put(allocator, "name", json.Value{ .integer = 42 });
        try std.testing.expect(plugin_conf.getName() == null);
    }

    test "getName() returns the string when valid" {
        const root_allocator = std.testing.allocator;
        var arena = try ArenaAllocator.init(root_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var plugin_conf = PluginConf{ .conf = try json.ObjectMap.init(allocator, &.{}, &.{}) };
        try plugin_conf.conf.put(allocator, "name", json.Value{ .string = "net1" });
        try std.testing.expectEqualSlices(u8, "net1", plugin_conf.getName().?);
    }

    test "getCniVersion() returns null when field is missing" {
        const root_allocator = std.testing.allocator;
        var arena = try ArenaAllocator.init(root_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var plugin_conf = PluginConf{ .conf = try json.ObjectMap.init(allocator, &.{}, &.{}) };
        try std.testing.expect(plugin_conf.getCniVersion() == null);
    }

    test "getCniVersion() returns null when field is not a string" {
        const root_allocator = std.testing.allocator;
        var arena = try ArenaAllocator.init(root_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var plugin_conf = PluginConf{ .conf = try json.ObjectMap.init(allocator, &.{}, &.{}) };
        try plugin_conf.conf.put(allocator, "cniVersion", json.Value{ .bool = true });
        try std.testing.expect(plugin_conf.getCniVersion() == null);
    }

    test "getCniVersion() returns the string when valid" {
        const root_allocator = std.testing.allocator;
        var arena = try ArenaAllocator.init(root_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var plugin_conf = PluginConf{ .conf = try json.ObjectMap.init(allocator, &.{}, &.{}) };
        try plugin_conf.conf.put(allocator, "cniVersion", json.Value{ .string = "1.0.0" });
        try std.testing.expectEqualSlices(u8, "1.0.0", plugin_conf.getCniVersion().?);
    }

    test "getType() returns null when field is missing" {
        const root_allocator = std.testing.allocator;
        var arena = try ArenaAllocator.init(root_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var plugin_conf = PluginConf{ .conf = try json.ObjectMap.init(allocator, &.{}, &.{}) };
        try std.testing.expect(plugin_conf.getType() == null);
    }

    test "getType() returns null when field is not a string" {
        const root_allocator = std.testing.allocator;
        var arena = try ArenaAllocator.init(root_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var plugin_conf = PluginConf{ .conf = try json.ObjectMap.init(allocator, &.{}, &.{}) };
        try plugin_conf.conf.put(allocator, "type", json.Value{ .integer = 42 });
        try std.testing.expect(plugin_conf.getType() == null);
    }

    test "getType() returns the string when valid" {
        const root_allocator = std.testing.allocator;
        var arena = try ArenaAllocator.init(root_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var plugin_conf = PluginConf{ .conf = try json.ObjectMap.init(allocator, &.{}, &.{}) };
        try plugin_conf.conf.put(allocator, "type", json.Value{ .string = "macvlan" });
        try std.testing.expectEqualSlices(u8, "macvlan", plugin_conf.getType().?);
    }

    test "isDhcp() will return false if the ipam type is not dhcp" {
        const root_allocator = std.testing.allocator;
        var arena = try ArenaAllocator.init(root_allocator);
        const allocator = arena.allocator();
        defer arena.deinit();

        // No ipam field
        var plugin_conf = PluginConf{ .conf = try json.ObjectMap.init(allocator, &.{}, &.{}) };
        try std.testing.expect(!plugin_conf.isDhcp());

        // Ipam field is not object type
        try plugin_conf.conf.put(allocator, "ipam", json.Value{ .bool = true });
        try std.testing.expect(!plugin_conf.isDhcp());

        // Have ipam field but no type field
        try plugin_conf.conf.put(allocator, "ipam", json.Value{ .object = try json.ObjectMap.init(allocator, &.{}, &.{}) });
        try std.testing.expect(!plugin_conf.isDhcp());

        // Ipam type field is not string type
        try plugin_conf.conf.getPtr("ipam").?.object.put(allocator, "type", json.Value{ .bool = true });
        try std.testing.expect(!plugin_conf.isDhcp());

        // Ipam type field is not 'dhcp'
        try plugin_conf.conf.getPtr("ipam").?.object.put(allocator, "type", json.Value{ .string = "static" });
        try std.testing.expect(!plugin_conf.isDhcp());
    }

    test "isDhcp() will return true if the type is dhcp" {
        const root_allocator = std.testing.allocator;
        var arena = try ArenaAllocator.init(root_allocator);
        const allocator = arena.allocator();
        defer arena.deinit();

        var plugin_conf = PluginConf{ .conf = try json.ObjectMap.init(allocator, &.{}, &.{}) };
        try plugin_conf.conf.put(allocator, "ipam", json.Value{ .object = try json.ObjectMap.init(allocator, &.{}, &.{}) });
        try plugin_conf.conf.getPtr("ipam").?.object.put(allocator, "type", json.Value{ .string = "dhcp" });

        try std.testing.expect(plugin_conf.isDhcp());
    }

    test "isStatic() will return true if the type is static" {
        const root_allocator = std.testing.allocator;
        var arena = try ArenaAllocator.init(root_allocator);
        const allocator = arena.allocator();
        defer arena.deinit();

        var plugin_conf = PluginConf{ .conf = try json.ObjectMap.init(allocator, &.{}, &.{}) };
        try plugin_conf.conf.put(allocator, "ipam", json.Value{ .object = try json.ObjectMap.init(allocator, &.{}, &.{}) });
        try plugin_conf.conf.getPtr("ipam").?.object.put(allocator, "type", json.Value{ .string = "static" });

        try std.testing.expect(plugin_conf.isStatic());
    }

    test "isStatic() will return false if the type is dhcp" {
        const root_allocator = std.testing.allocator;
        var arena = try ArenaAllocator.init(root_allocator);
        const allocator = arena.allocator();
        defer arena.deinit();

        var plugin_conf = PluginConf{ .conf = try json.ObjectMap.init(allocator, &.{}, &.{}) };
        try plugin_conf.conf.put(allocator, "ipam", json.Value{ .object = try json.ObjectMap.init(allocator, &.{}, &.{}) });
        try plugin_conf.conf.getPtr("ipam").?.object.put(allocator, "type", json.Value{ .string = "dhcp" });

        try std.testing.expect(!plugin_conf.isStatic());
    }

    test "isMacvlan() returns true when plugin type is macvlan" {
        const root_allocator = std.testing.allocator;
        var arena = try ArenaAllocator.init(root_allocator);
        const allocator = arena.allocator();
        defer arena.deinit();

        var plugin_conf = PluginConf{ .conf = try json.ObjectMap.init(allocator, &.{}, &.{}) };
        try plugin_conf.conf.put(allocator, "type", json.Value{ .string = "macvlan" });
        try std.testing.expect(plugin_conf.isMacvlan());
    }

    test "isMacvlan() returns false when plugin type is not macvlan" {
        const root_allocator = std.testing.allocator;
        var arena = try ArenaAllocator.init(root_allocator);
        const allocator = arena.allocator();
        defer arena.deinit();

        var plugin_conf = PluginConf{ .conf = try json.ObjectMap.init(allocator, &.{}, &.{}) };
        try plugin_conf.conf.put(allocator, "type", json.Value{ .string = "firewall" });
        try std.testing.expect(!plugin_conf.isMacvlan());
    }

    test "isMacvlan() returns false when type field is missing" {
        const root_allocator = std.testing.allocator;
        var arena = try ArenaAllocator.init(root_allocator);
        const allocator = arena.allocator();
        defer arena.deinit();

        var plugin_conf = PluginConf{ .conf = try json.ObjectMap.init(allocator, &.{}, &.{}) };
        try std.testing.expect(!plugin_conf.isMacvlan());
    }

    pub fn stringify(self: PluginConf, io: std.Io, stream: std.Io.File) !void {
        var write_buffer: [4096]u8 = undefined;
        var file_writer = stream.writer(io, &write_buffer);
        try json.Stringify.value(
            json.Value{ .object = self.conf },
            .{ .whitespace = .indent_2 },
            &file_writer.interface,
        );
        try file_writer.end();
    }

    test "stringify() will success" {
        const allocator = std.testing.allocator;
        const io = std.testing.io;
        const raw_data =
            \\{
            \\    "cniVersion": "1.0.0",
            \\    "name": "test",
            \\    "type": "macvlan"
            \\}
        ;
        const parsed_data = try json.parseFromSlice(
            json.Value,
            allocator,
            raw_data,
            .{},
        );
        defer parsed_data.deinit();

        const exec_config = PluginConf{ .conf = parsed_data.value.object };

        var fds: [2]i32 = undefined;
        const rc = std.os.linux.pipe(&fds);
        if (rc != 0) return error.Unexpected;
        var in = std.Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } };
        defer in.close(io);

        var out = std.Io.File{ .handle = fds[1], .flags = .{ .nonblocking = false } };
        try exec_config.stringify(io, out);
        out.close(io);

        const buf = blk: {
            var read_buffer: [1024]u8 = undefined;
            var file_reader = in.reader(io, &read_buffer);
            break :blk try file_reader.interface.allocRemaining(allocator, .limited(1024));
        };
        defer allocator.free(buf);

        try std.testing.expect(buf.len > 0);
    }

    fn setName(self: *PluginConf, name: []const u8) !void {
        try self.conf.put(self.arena.?.allocator(), "name", json.Value{ .string = name });
    }

    fn setCniVersion(self: *PluginConf, version: []const u8) !void {
        try self.conf.put(self.arena.?.allocator(), "cniVersion", json.Value{ .string = version });
    }

    /// Inject a prevResult into the plugin config from a CNI result JSON string.
    /// The result is parsed into a proper json.Value so it serializes as a nested JSON object.
    pub fn setPrevResult(self: *PluginConf, result: []const u8) !void {
        const allocator = self.arena.?.allocator();
        // Parse the result JSON string into a json.Value
        const parsed = try json.parseFromSlice(json.Value, allocator, result, .{
            .ignore_unknown_fields = true,
        });
        // Insert parsed value into conf. Memory lives in the arena; no need to deinit parsed.
        try self.conf.put(allocator, "prevResult", parsed.value);
    }

    /// Execute the CNI plugin binary, bounded by `timeout_ms`.
    ///
    /// On Linux >= 5.3, the child is monitored via a pidfd so that a hanging
    /// plugin can be detected and killed without blocking the caller. Either
    /// way, `process.wait` is always invoked so the child is reaped and never
    /// becomes a zombie.
    ///
    /// Note: on Linux < 5.3 where pidfd_open is unavailable, both the pipe
    /// reads (allocRemaining on stdout/stderr) and process.wait() block
    /// indefinitely. The timeout protection is only effective on Linux >= 5.3.
    ///
    /// Errors: returns `error.CniPluginTimeout` when the child has not exited
    /// within `timeout_ms` (child is killed and reaped before returning). All
    /// other errors are propagated from `std.process.spawn`, `std.posix.poll`,
    /// `std.process.Child.wait`, and pipe I/O.
    pub fn exec(
        self: *PluginConf,
        io: std.Io,
        tentative_allocator: Allocator,
        cmd: []const u8,
        env_map: std.process.Environ.Map,
        timeout_ms: i32,
    ) !std.process.Child.Term {
        _ = tentative_allocator;
        const allocator = self.arena.?.allocator();

        // Execute CNI plugin directly in host namespace.
        // No nsenter — the binary path is resolved from the host filesystem,
        // and CNI_NETNS has been resolved to a host-valid path via NetnsResolver.
        var process = try std.process.spawn(io, .{
            .argv = &[_][]const u8{cmd},
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .environ_map = &env_map,
        });
        // Ensure child process is cleaned up on any error between spawn and wait.
        // Without this, pipe fds leak and the child becomes a zombie process.
        // The id-check guards against double-reap when an error path has already
        // called wait(io) (e.g. timeout).
        errdefer {
            if (process.stdin) |f| f.close(io);
            if (process.stdout) |f| f.close(io);
            if (process.stderr) |f| f.close(io);
            if (process.id != null) {
                if (process.wait(io)) |_| {} else |_| {} // reap zombie
            }
        }

        var stdout = std.ArrayListUnmanaged(u8).empty;
        defer stdout.deinit(allocator);
        var stderr = std.ArrayListUnmanaged(u8).empty;
        defer stderr.deinit(allocator);

        try self.stringify(io, process.stdin.?);
        process.stdin.?.close(io);
        process.stdin = null;

        // Bound the wait for the child to exit. pidfd_open gives us a pollable
        // fd that becomes readable when the child terminates.
        const pid = process.id.?;
        const pidfd_raw = std.os.linux.pidfd_open(pid, 0);
        const have_pidfd = (std.posix.errno(pidfd_raw) == .SUCCESS);
        if (have_pidfd) {
            const pidfd: std.posix.fd_t = @intCast(pidfd_raw);
            defer _ = std.os.linux.close(pidfd);

            var poll_fds = [_]std.posix.pollfd{.{
                .fd = pidfd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const n_ready = std.posix.poll(&poll_fds, timeout_ms) catch |err| {
                // poll failed — kill the child defensively and propagate.
                _ = std.os.linux.kill(pid, std.os.linux.SIG.KILL);
                _ = process.wait(io) catch {};
                return err;
            };
            if (n_ready == 0) {
                log.warn(
                    "CNI plugin '{s}' timed out after {d}ms; killing pid={d}",
                    .{ self.getType() orelse "unknown", timeout_ms, pid },
                );
                _ = std.os.linux.kill(pid, std.os.linux.SIG.KILL);
                _ = process.wait(io) catch {};
                // Attempt to read stderr that was captured before the timeout
                if (process.stderr) |err_file| {
                    var read_buffer: [4096]u8 = undefined;
                    var file_reader = err_file.reader(io, &read_buffer);
                    if (file_reader.interface.allocRemaining(allocator, .limited(max_plugin_output))) |data| {
                        if (data.len > 0) {
                            const truncated = if (data.len > max_stderr_log) data[0..max_stderr_log] else data;
                            log.warn(
                                "CNI plugin '{s}' stderr before timeout: {s}",
                                .{ self.getType() orelse "unknown", truncated },
                            );
                            self.stderr_result = std.ArrayList(u8).fromOwnedSlice(data);
                        } else {
                            allocator.free(data);
                        }
                    } else |_| {}
                }
                return error.CniPluginTimeout;
            }
            // n_ready > 0: pidfd is readable, child has exited. Fall through
            // to read pipes and reap normally.
        }
        // If pidfd_open was unsupported (kernel < 5.3), behave as before:
        // block in `wait(io)` until the child exits.

        // Read stdout and stderr into buffers
        if (process.stdout) |out_file| {
            var read_buffer: [4096]u8 = undefined;
            var file_reader = out_file.reader(io, &read_buffer);
            const data = try file_reader.interface.allocRemaining(allocator, .limited(max_plugin_output));
            stdout = std.ArrayListUnmanaged(u8).fromOwnedSlice(data);
        }
        if (process.stderr) |err_file| {
            var read_buffer: [4096]u8 = undefined;
            var file_reader = err_file.reader(io, &read_buffer);
            const data = try file_reader.interface.allocRemaining(allocator, .limited(max_plugin_output));
            stderr = std.ArrayListUnmanaged(u8).fromOwnedSlice(data);
        }
        const stderr_data = try stderr.toOwnedSlice(allocator);
        if (stderr_data.len > 0) {
            self.stderr_result = std.ArrayList(u8).fromOwnedSlice(stderr_data);
        } else {
            allocator.free(stderr_data);
        }

        const result = try process.wait(io);

        self.result = std.ArrayList(u8).fromOwnedSlice(try stdout.toOwnedSlice(allocator));
        return result;
    }
};

// -- Tests for setPrevResult + stringify --

test "setPrevResult + stringify produces JSON with embedded prevResult object" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Create a PluginConf with basic config
    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var conf = try json.ObjectMap.init(a, &.{}, &.{});
    try conf.put(a, "cniVersion", json.Value{ .string = "1.0.0" });
    try conf.put(a, "name", json.Value{ .string = "test" });
    try conf.put(a, "type", json.Value{ .string = "macvlan" });

    var plugin_conf = PluginConf{
        .arena = arena,
        .conf = conf,
    };

    // Set prevResult from a CNI result JSON string
    const result_json =
        \\{"cniVersion":"1.0.0","interfaces":[{"name":"eth0","mac":"aa:bb:cc:dd:ee:ff"}],"ips":[{"version":"4","address":"10.0.0.5/24","interface":0}]}
    ;
    try plugin_conf.setPrevResult(result_json);

    // Stringify to pipe and verify prevResult appears as a JSON object
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.pipe(&fds);
    try std.testing.expect(rc == 0);
    var in_file = std.Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    defer in_file.close(io);
    var out_file = std.Io.File{ .handle = fds[1], .flags = .{ .nonblocking = false } };

    try plugin_conf.stringify(io, out_file);
    out_file.close(io);

    const buf = blk: {
        var read_buffer: [8192]u8 = undefined;
        var file_reader = in_file.reader(io, &read_buffer);
        break :blk try file_reader.interface.allocRemaining(allocator, .limited(8192));
    };
    defer allocator.free(buf);

    // Verify the output contains prevResult key
    try std.testing.expect(std.mem.indexOf(u8, buf, "\"prevResult\"") != null);
    // Verify prevResult value is a proper JSON object (not an escaped string)
    // If escaped, we'd see: "{\\\"cniVersion\\\":\\\"1.0.0\\\"...}"
    // As a proper object, we see nested interfaces and ips
    try std.testing.expect(std.mem.indexOf(u8, buf, "\"interfaces\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf, "\"eth0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf, "10.0.0.5") != null);
}

// -- Tests for patchAddresses --

test "patchAddresses injects address with subnet prefix" {
    const allocator = std.testing.allocator;
    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Build ipam with template address + routes
    var addr_obj = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try addr_obj.put(arena_alloc, "address", .{ .string = "192.168.1.0/24" });
    try addr_obj.put(arena_alloc, "gateway", .{ .string = "192.168.1.1" });

    var addrs = try json.Array.initCapacity(arena_alloc, 1);
    addrs.appendAssumeCapacity(.{ .object = addr_obj });

    var route_obj = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try route_obj.put(arena_alloc, "dst", .{ .string = "0.0.0.0/0" });
    var routes = try json.Array.initCapacity(arena_alloc, 1);
    routes.appendAssumeCapacity(.{ .object = route_obj });

    var ipam_obj = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try ipam_obj.put(arena_alloc, "type", .{ .string = "static" });
    try ipam_obj.put(arena_alloc, "addresses", .{ .array = addrs });
    try ipam_obj.put(arena_alloc, "routes", .{ .array = routes });

    var conf = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try conf.put(arena_alloc, "type", .{ .string = "macvlan" });
    try conf.put(arena_alloc, "name", .{ .string = "test" });
    try conf.put(arena_alloc, "cniVersion", .{ .string = "1.0.0" });
    try conf.put(arena_alloc, "ipam", .{ .object = ipam_obj });

    var plugin_conf = PluginConf{ .arena = arena, .conf = conf };

    const ips = &[_][]const u8{"192.168.1.15"};
    try plugin_conf.patchAddresses(ips);

    // Verify addresses were patched
    const result_ipam = plugin_conf.conf.get("ipam").?.object;
    const addresses = result_ipam.get("addresses").?.array;
    try std.testing.expectEqual(@as(usize, 1), addresses.items.len);

    const result_addr = addresses.items[0].object;
    try std.testing.expectEqualSlices(u8, "192.168.1.15/24", result_addr.get("address").?.string);
    try std.testing.expectEqualSlices(u8, "192.168.1.1", result_addr.get("gateway").?.string);

    // Verify routes were preserved by shadowCopy
    const result_routes = result_ipam.get("routes").?.array;
    try std.testing.expectEqual(@as(usize, 1), result_routes.items.len);
    try std.testing.expectEqualSlices(u8, "0.0.0.0/0", result_routes.items[0].object.get("dst").?.string);
}

test "patchAddresses with no gateway omits gateway field" {
    const allocator = std.testing.allocator;
    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var addr_obj = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try addr_obj.put(arena_alloc, "address", .{ .string = "10.0.0.0/8" });

    var addrs = try json.Array.initCapacity(arena_alloc, 1);
    addrs.appendAssumeCapacity(.{ .object = addr_obj });

    var ipam_obj = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try ipam_obj.put(arena_alloc, "type", .{ .string = "static" });
    try ipam_obj.put(arena_alloc, "addresses", .{ .array = addrs });

    var conf = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try conf.put(arena_alloc, "type", .{ .string = "macvlan" });
    try conf.put(arena_alloc, "name", .{ .string = "test" });
    try conf.put(arena_alloc, "cniVersion", .{ .string = "1.0.0" });
    try conf.put(arena_alloc, "ipam", .{ .object = ipam_obj });

    var plugin_conf = PluginConf{ .arena = arena, .conf = conf };

    const ips = &[_][]const u8{"10.0.0.5"};
    try plugin_conf.patchAddresses(ips);

    const result_ipam = plugin_conf.conf.get("ipam").?.object;
    const result_addr = result_ipam.get("addresses").?.array.items[0].object;
    try std.testing.expectEqualSlices(u8, "10.0.0.5/8", result_addr.get("address").?.string);
    try std.testing.expect(result_addr.get("gateway") == null);

    // No routes configured — routes key should not exist
    try std.testing.expect(result_ipam.get("routes") == null);
}

test "patchAddresses preserves multiple routes via shadowCopy" {
    const allocator = std.testing.allocator;
    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var addr_obj = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try addr_obj.put(arena_alloc, "address", .{ .string = "192.168.1.0/24" });
    try addr_obj.put(arena_alloc, "gateway", .{ .string = "192.168.1.1" });
    var addrs = try json.Array.initCapacity(arena_alloc, 1);
    addrs.appendAssumeCapacity(.{ .object = addr_obj });

    var route1 = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try route1.put(arena_alloc, "dst", .{ .string = "0.0.0.0/0" });
    var route2 = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try route2.put(arena_alloc, "dst", .{ .string = "10.0.0.0/8" });
    var routes = try json.Array.initCapacity(arena_alloc, 2);
    routes.appendAssumeCapacity(.{ .object = route1 });
    routes.appendAssumeCapacity(.{ .object = route2 });

    var ipam_obj = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try ipam_obj.put(arena_alloc, "type", .{ .string = "static" });
    try ipam_obj.put(arena_alloc, "addresses", .{ .array = addrs });
    try ipam_obj.put(arena_alloc, "routes", .{ .array = routes });

    var conf = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try conf.put(arena_alloc, "type", .{ .string = "macvlan" });
    try conf.put(arena_alloc, "name", .{ .string = "test" });
    try conf.put(arena_alloc, "cniVersion", .{ .string = "1.0.0" });
    try conf.put(arena_alloc, "ipam", .{ .object = ipam_obj });

    var plugin_conf = PluginConf{ .arena = arena, .conf = conf };

    const ips = &[_][]const u8{"192.168.1.50"};
    try plugin_conf.patchAddresses(ips);

    const result_ipam = plugin_conf.conf.get("ipam").?.object;
    const result_routes = result_ipam.get("routes").?.array;
    try std.testing.expectEqual(@as(usize, 2), result_routes.items.len);
    try std.testing.expectEqualSlices(u8, "0.0.0.0/0", result_routes.items[0].object.get("dst").?.string);
    try std.testing.expectEqualSlices(u8, "10.0.0.0/8", result_routes.items[1].object.get("dst").?.string);
}

test "patchAddresses with empty template addresses does nothing" {
    const allocator = std.testing.allocator;
    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var ipam_obj = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try ipam_obj.put(arena_alloc, "type", .{ .string = "static" });
    // No addresses key — should warn and return without creating anything

    var conf = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try conf.put(arena_alloc, "type", .{ .string = "macvlan" });
    try conf.put(arena_alloc, "name", .{ .string = "test" });
    try conf.put(arena_alloc, "cniVersion", .{ .string = "1.0.0" });
    try conf.put(arena_alloc, "ipam", .{ .object = ipam_obj });

    var plugin_conf = PluginConf{ .arena = arena, .conf = conf };

    const ips = &[_][]const u8{"192.168.1.50"};
    try plugin_conf.patchAddresses(ips);

    const result_ipam = plugin_conf.conf.get("ipam").?.object;
    // addresses should remain null — nothing was created
    try std.testing.expect(result_ipam.get("addresses") == null);
}

test "patchAddresses with dual-stack IPv4 and IPv6" {
    const allocator = std.testing.allocator;
    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var addr4 = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try addr4.put(arena_alloc, "address", .{ .string = "192.168.1.0/24" });
    try addr4.put(arena_alloc, "gateway", .{ .string = "192.168.1.1" });

    var addr6 = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try addr6.put(arena_alloc, "address", .{ .string = "2001:db8::/64" });
    try addr6.put(arena_alloc, "gateway", .{ .string = "2001:db8::1" });

    var addrs = try json.Array.initCapacity(arena_alloc, 2);
    addrs.appendAssumeCapacity(.{ .object = addr4 });
    addrs.appendAssumeCapacity(.{ .object = addr6 });

    var route1 = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try route1.put(arena_alloc, "dst", .{ .string = "0.0.0.0/0" });
    var route2 = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try route2.put(arena_alloc, "dst", .{ .string = "::/0" });
    var routes = try json.Array.initCapacity(arena_alloc, 2);
    routes.appendAssumeCapacity(.{ .object = route1 });
    routes.appendAssumeCapacity(.{ .object = route2 });

    var ipam_obj = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try ipam_obj.put(arena_alloc, "type", .{ .string = "static" });
    try ipam_obj.put(arena_alloc, "addresses", .{ .array = addrs });
    try ipam_obj.put(arena_alloc, "routes", .{ .array = routes });

    var conf = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try conf.put(arena_alloc, "type", .{ .string = "macvlan" });
    try conf.put(arena_alloc, "name", .{ .string = "test" });
    try conf.put(arena_alloc, "cniVersion", .{ .string = "1.0.0" });
    try conf.put(arena_alloc, "ipam", .{ .object = ipam_obj });

    var plugin_conf = PluginConf{ .arena = arena, .conf = conf };

    const ips = &[_][]const u8{ "192.168.1.15", "2001:db8::10" };
    try plugin_conf.patchAddresses(ips);

    const result_ipam = plugin_conf.conf.get("ipam").?.object;
    const addresses = result_ipam.get("addresses").?.array;
    try std.testing.expectEqual(@as(usize, 2), addresses.items.len);

    // IPv4 address
    try std.testing.expectEqualSlices(u8, "192.168.1.15/24", addresses.items[0].object.get("address").?.string);
    try std.testing.expectEqualSlices(u8, "192.168.1.1", addresses.items[0].object.get("gateway").?.string);

    // IPv6 address
    try std.testing.expectEqualSlices(u8, "2001:db8::10/64", addresses.items[1].object.get("address").?.string);
    try std.testing.expectEqualSlices(u8, "2001:db8::1", addresses.items[1].object.get("gateway").?.string);

    // Routes preserved
    const result_routes = result_ipam.get("routes").?.array;
    try std.testing.expectEqual(@as(usize, 2), result_routes.items.len);
    try std.testing.expectEqualSlices(u8, "0.0.0.0/0", result_routes.items[0].object.get("dst").?.string);
    try std.testing.expectEqualSlices(u8, "::/0", result_routes.items[1].object.get("dst").?.string);
}

test "patchAddresses skips IP with no matching subnet family" {
    const allocator = std.testing.allocator;
    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Only IPv4 subnet configured
    var addr4 = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try addr4.put(arena_alloc, "address", .{ .string = "192.168.1.0/24" });
    try addr4.put(arena_alloc, "gateway", .{ .string = "192.168.1.1" });
    var addrs = try json.Array.initCapacity(arena_alloc, 1);
    addrs.appendAssumeCapacity(.{ .object = addr4 });

    var ipam_obj = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try ipam_obj.put(arena_alloc, "type", .{ .string = "static" });
    try ipam_obj.put(arena_alloc, "addresses", .{ .array = addrs });

    var conf = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try conf.put(arena_alloc, "type", .{ .string = "macvlan" });
    try conf.put(arena_alloc, "name", .{ .string = "test" });
    try conf.put(arena_alloc, "cniVersion", .{ .string = "1.0.0" });
    try conf.put(arena_alloc, "ipam", .{ .object = ipam_obj });

    var plugin_conf = PluginConf{ .arena = arena, .conf = conf };

    // Request both IPv4 and IPv6, but only IPv4 has a matching subnet
    const ips = &[_][]const u8{ "192.168.1.15", "2001:db8::10" };
    try plugin_conf.patchAddresses(ips);

    const result_ipam = plugin_conf.conf.get("ipam").?.object;
    const addresses = result_ipam.get("addresses").?.array;
    // Only IPv4 address should be injected
    try std.testing.expectEqual(@as(usize, 1), addresses.items.len);
    try std.testing.expectEqualSlices(u8, "192.168.1.15/24", addresses.items[0].object.get("address").?.string);
}

test "patchAddresses with IPv6 only" {
    const allocator = std.testing.allocator;
    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var addr6 = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try addr6.put(arena_alloc, "address", .{ .string = "2001:db8::/64" });
    try addr6.put(arena_alloc, "gateway", .{ .string = "2001:db8::1" });
    var addrs = try json.Array.initCapacity(arena_alloc, 1);
    addrs.appendAssumeCapacity(.{ .object = addr6 });

    var ipam_obj = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try ipam_obj.put(arena_alloc, "type", .{ .string = "static" });
    try ipam_obj.put(arena_alloc, "addresses", .{ .array = addrs });

    var conf = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try conf.put(arena_alloc, "type", .{ .string = "macvlan" });
    try conf.put(arena_alloc, "name", .{ .string = "test" });
    try conf.put(arena_alloc, "cniVersion", .{ .string = "1.0.0" });
    try conf.put(arena_alloc, "ipam", .{ .object = ipam_obj });

    var plugin_conf = PluginConf{ .arena = arena, .conf = conf };

    const ips = &[_][]const u8{"2001:db8::42"};
    try plugin_conf.patchAddresses(ips);

    const result_ipam = plugin_conf.conf.get("ipam").?.object;
    const addresses = result_ipam.get("addresses").?.array;
    try std.testing.expectEqual(@as(usize, 1), addresses.items.len);
    try std.testing.expectEqualSlices(u8, "2001:db8::42/64", addresses.items[0].object.get("address").?.string);
    try std.testing.expectEqualSlices(u8, "2001:db8::1", addresses.items[0].object.get("gateway").?.string);
}

// -- Tests for patchMacAddress --

test "patchMacAddress adds mac key to plugin config" {
    const allocator = std.testing.allocator;
    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var conf = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try conf.put(arena_alloc, "type", .{ .string = "macvlan" });
    try conf.put(arena_alloc, "name", .{ .string = "test" });
    try conf.put(arena_alloc, "cniVersion", .{ .string = "1.0.0" });

    var plugin_conf = PluginConf{ .arena = arena, .conf = conf };
    try plugin_conf.patchMacAddress("02:42:c0:a8:01:64");

    const mac_val = plugin_conf.conf.get("mac").?;
    try std.testing.expectEqualSlices(u8, "02:42:c0:a8:01:64", mac_val.string);
}

test "patchMacAddress overwrites existing mac key" {
    const allocator = std.testing.allocator;
    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var conf = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try conf.put(arena_alloc, "type", .{ .string = "macvlan" });
    try conf.put(arena_alloc, "mac", .{ .string = "00:00:00:00:00:00" });

    var plugin_conf = PluginConf{ .arena = arena, .conf = conf };
    try plugin_conf.patchMacAddress("02:42:c0:a8:01:64");

    const mac_val = plugin_conf.conf.get("mac").?;
    try std.testing.expectEqualSlices(u8, "02:42:c0:a8:01:64", mac_val.string);
}

test "patchMacAddress preserves other config keys" {
    const allocator = std.testing.allocator;
    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var conf = try json.ObjectMap.init(arena_alloc, &.{}, &.{});
    try conf.put(arena_alloc, "type", .{ .string = "macvlan" });
    try conf.put(arena_alloc, "name", .{ .string = "mynet" });
    try conf.put(arena_alloc, "cniVersion", .{ .string = "1.0.0" });
    try conf.put(arena_alloc, "master", .{ .string = "eth0" });

    var plugin_conf = PluginConf{ .arena = arena, .conf = conf };
    try plugin_conf.patchMacAddress("aa:bb:cc:dd:ee:ff");

    try std.testing.expectEqualSlices(u8, "macvlan", plugin_conf.conf.get("type").?.string);
    try std.testing.expectEqualSlices(u8, "mynet", plugin_conf.conf.get("name").?.string);
    try std.testing.expectEqualSlices(u8, "eth0", plugin_conf.conf.get("master").?.string);
    try std.testing.expectEqualSlices(u8, "aa:bb:cc:dd:ee:ff", plugin_conf.conf.get("mac").?.string);
}

// -- Tests for exec timeout --

test "exec returns CniPluginTimeout when plugin hangs" {
    // This test verifies the DoS fix: a hanging CNI plugin must be killed and
    // exec must return error.CniPluginTimeout rather than blocking forever.
    const test_utils = @import("../test_utils.zig");
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Skip on kernels without pidfd_open (Linux < 5.3, or restricted by
    // seccomp/yama). On those kernels the fallback path performs a blocking
    // wait and the timeout is ineffective, so this test would hang for the
    // full sleep duration and then fail.
    {
        const self_pid = std.os.linux.getpid();
        const pidfd_raw = std.os.linux.pidfd_open(self_pid, 0);
        if (std.posix.errno(pidfd_raw) != .SUCCESS) {
            return error.SkipZigTest;
        }
        _ = std.os.linux.close(@intCast(pidfd_raw));
    }

    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var conf = try json.ObjectMap.init(a, &.{}, &.{});
    try conf.put(a, "cniVersion", json.Value{ .string = "1.0.0" });
    try conf.put(a, "name", json.Value{ .string = "exec-timeout-test" });
    try conf.put(a, "type", json.Value{ .string = "hang" });

    var plugin_conf = PluginConf{
        .arena = arena,
        .conf = conf,
    };

    // Create a temp shell script that sleeps for 10s — long enough to exceed
    // any reasonable test timeout, short enough to limit orphan risk if the
    // test runner is killed before exec()'s SIGKILL reaches the child.
    // Random suffix keeps parallel test runs from colliding.
    const script_path = try test_utils.uniqueTempPath(
        io,
        allocator,
        ".net-porter-test-hang-",
        ".sh",
    );
    defer allocator.free(script_path);
    defer std.Io.Dir.deleteFileAbsolute(io, script_path) catch {};

    {
        const file = try std.Io.Dir.createFileAbsolute(io, script_path, .{
            .permissions = @enumFromInt(0o755),
        });
        defer file.close(io);
        try file.writeStreamingAll(io, "#!/bin/sh\nexec sleep 10\n");
    }

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    // 500ms timeout — well below the 60s sleep, generous enough to avoid
    // false positives on slow CI.
    var ts_before: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts_before);
    const result = plugin_conf.exec(io, allocator, script_path, env_map, 500);
    var ts_after: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts_after);
    const elapsed_ms: i64 =
        (@as(i64, ts_after.sec) - @as(i64, ts_before.sec)) * std.time.ms_per_s +
        (@divFloor(@as(i64, ts_after.nsec), std.time.ns_per_ms) -
            @divFloor(@as(i64, ts_before.nsec), std.time.ns_per_ms));

    try std.testing.expectError(error.CniPluginTimeout, result);
    // Returned within a few seconds (not 60s) — proves the child was killed
    // and we did not block waiting for it to exit on its own.
    try std.testing.expect(elapsed_ms < 5_000);
}

test "exec succeeds when plugin exits before timeout" {
    // Sanity check: a plugin that exits quickly must not be falsely flagged
    // as timed out.
    const test_utils = @import("../test_utils.zig");
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var conf = try json.ObjectMap.init(a, &.{}, &.{});
    try conf.put(a, "cniVersion", json.Value{ .string = "1.0.0" });
    try conf.put(a, "name", json.Value{ .string = "exec-success-test" });
    try conf.put(a, "type", json.Value{ .string = "true" });

    var plugin_conf = PluginConf{
        .arena = arena,
        .conf = conf,
    };

    // A trivial "exit 0" script with a random suffix to avoid collisions
    // between parallel test runs.
    const script_path = try test_utils.uniqueTempPath(
        io,
        allocator,
        ".net-porter-test-exit-",
        ".sh",
    );
    defer allocator.free(script_path);
    defer std.Io.Dir.deleteFileAbsolute(io, script_path) catch {};

    {
        const file = try std.Io.Dir.createFileAbsolute(io, script_path, .{
            .permissions = @enumFromInt(0o755),
        });
        defer file.close(io);
        try file.writeStreamingAll(io, "#!/bin/sh\nexit 0\n");
    }

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    // 5s timeout — much longer than the script needs; the test should
    // succeed long before this fires.
    const term = try plugin_conf.exec(io, allocator, script_path, env_map, 5_000);
    try std.testing.expectEqual(@as(u8, 0), term.exited);
}

// -- Tests for exec stderr capture --

test "exec captures stderr from child process that writes to stderr" {
    const test_utils = @import("../test_utils.zig");
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var conf = try json.ObjectMap.init(a, &.{}, &.{});
    try conf.put(a, "cniVersion", json.Value{ .string = "1.0.0" });
    try conf.put(a, "name", json.Value{ .string = "exec-stderr-test" });
    try conf.put(a, "type", json.Value{ .string = "stderr" });

    var plugin_conf = PluginConf{
        .arena = arena,
        .conf = conf,
    };

    const script_path = try test_utils.uniqueTempPath(
        io,
        allocator,
        ".net-porter-test-stderr-",
        ".sh",
    );
    defer allocator.free(script_path);
    defer std.Io.Dir.deleteFileAbsolute(io, script_path) catch {};

    {
        const file = try std.Io.Dir.createFileAbsolute(io, script_path, .{
            .permissions = @enumFromInt(0o755),
        });
        defer file.close(io);
        try file.writeStreamingAll(io, "#!/bin/sh\necho 'plugin error' >&2\nexit 0\n");
    }

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    const term = try plugin_conf.exec(io, allocator, script_path, env_map, 5_000);
    try std.testing.expectEqual(@as(u8, 0), term.exited);

    try std.testing.expect(plugin_conf.stderr_result != null);
    try std.testing.expectEqualSlices(u8, "plugin error\n", plugin_conf.stderr_result.?.items);
}

test "stderr_result is freed by deinit" {
    const test_utils = @import("../test_utils.zig");
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var arena = try ArenaAllocator.init(allocator);
    const a = arena.allocator();

    var conf = try json.ObjectMap.init(
        a,
        &.{},
        &.{},
    );
    try conf.put(a, "cniVersion", json.Value{ .string = "1.0.0" });
    try conf.put(a, "name", json.Value{ .string = "exec-deinit-test" });
    try conf.put(a, "type", json.Value{ .string = "stderr" });

    var plugin_conf = PluginConf{
        .arena = arena,
        .conf = conf,
    };

    const script_path = try test_utils.uniqueTempPath(
        io,
        allocator,
        ".net-porter-test-deinit-",
        ".sh",
    );
    defer allocator.free(script_path);
    defer std.Io.Dir.deleteFileAbsolute(io, script_path) catch {};

    {
        const file = try std.Io.Dir.createFileAbsolute(io, script_path, .{
            .permissions = @enumFromInt(0o755),
        });
        defer file.close(io);
        try file.writeStreamingAll(io, "#!/bin/sh\necho 'leak check payload' >&2\nexit 0\n");
    }

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    const term = try plugin_conf.exec(io, allocator, script_path, env_map, 5_000);
    try std.testing.expectEqual(@as(u8, 0), term.exited);
    try std.testing.expect(plugin_conf.stderr_result != null);
    try std.testing.expect(plugin_conf.stderr_result.?.items.len > 0);

    plugin_conf.deinit();
    // If stderr_result memory leaks, std.testing.allocator will report it.
}

test "stderr_result is null when child writes nothing to stderr" {
    const test_utils = @import("../test_utils.zig");
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var conf = try json.ObjectMap.init(a, &.{}, &.{});
    try conf.put(a, "cniVersion", json.Value{ .string = "1.0.0" });
    try conf.put(a, "name", json.Value{ .string = "exec-no-stderr-test" });
    try conf.put(a, "type", json.Value{ .string = "silent" });

    var plugin_conf = PluginConf{
        .arena = arena,
        .conf = conf,
    };

    const script_path = try test_utils.uniqueTempPath(
        io,
        allocator,
        ".net-porter-test-silent-",
        ".sh",
    );
    defer allocator.free(script_path);
    defer std.Io.Dir.deleteFileAbsolute(io, script_path) catch {};

    {
        const file = try std.Io.Dir.createFileAbsolute(io, script_path, .{
            .permissions = @enumFromInt(0o755),
        });
        defer file.close(io);
        try file.writeStreamingAll(io, "#!/bin/sh\necho 'stdout only'\nexit 0\n");
    }

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    const term = try plugin_conf.exec(io, allocator, script_path, env_map, 5_000);
    try std.testing.expectEqual(@as(u8, 0), term.exited);
    try std.testing.expect(plugin_conf.stderr_result == null);
}

test "exec captures stderr when plugin exits with non-zero code" {
    const test_utils = @import("../test_utils.zig");
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var conf = try json.ObjectMap.init(a, &.{}, &.{});
    try conf.put(a, "cniVersion", json.Value{ .string = "1.0.0" });
    try conf.put(a, "name", json.Value{ .string = "exec-fail-stderr-test" });
    try conf.put(a, "type", json.Value{ .string = "fail-stderr" });

    var plugin_conf = PluginConf{
        .arena = arena,
        .conf = conf,
    };

    const script_path = try test_utils.uniqueTempPath(
        io,
        allocator,
        ".net-porter-test-fail-stderr-",
        ".sh",
    );
    defer allocator.free(script_path);
    defer std.Io.Dir.deleteFileAbsolute(io, script_path) catch {};

    {
        const file = try std.Io.Dir.createFileAbsolute(io, script_path, .{
            .permissions = @enumFromInt(0o755),
        });
        defer file.close(io);
        try file.writeStreamingAll(io, "#!/bin/sh\necho 'fatal: missing interface' >&2\nexit 1\n");
    }

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    const term = try plugin_conf.exec(io, allocator, script_path, env_map, 5_000);
    try std.testing.expectEqual(@as(u8, 1), term.exited);

    try std.testing.expect(plugin_conf.stderr_result != null);
    try std.testing.expectEqualSlices(u8, "fatal: missing interface\n", plugin_conf.stderr_result.?.items);
}

test "exec captures stdout and stderr separately when plugin succeeds with stderr output" {
    const test_utils = @import("../test_utils.zig");
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var arena = try ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var conf = try json.ObjectMap.init(a, &.{}, &.{});
    try conf.put(a, "cniVersion", json.Value{ .string = "1.0.0" });
    try conf.put(a, "name", json.Value{ .string = "exec-mixed-output-test" });
    try conf.put(a, "type", json.Value{ .string = "mixed" });

    var plugin_conf = PluginConf{
        .arena = arena,
        .conf = conf,
    };

    const script_path = try test_utils.uniqueTempPath(
        io,
        allocator,
        ".net-porter-test-mixed-",
        ".sh",
    );
    defer allocator.free(script_path);
    defer std.Io.Dir.deleteFileAbsolute(io, script_path) catch {};

    {
        const file = try std.Io.Dir.createFileAbsolute(io, script_path, .{
            .permissions = @enumFromInt(0o755),
        });
        defer file.close(io);
        try file.writeStreamingAll(io, "#!/bin/sh\necho '{\"cniVersion\":\"1.0.0\"}'\necho 'diagnostic line' >&2\nexit 0\n");
    }

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    const term = try plugin_conf.exec(io, allocator, script_path, env_map, 5_000);
    try std.testing.expectEqual(@as(u8, 0), term.exited);

    try std.testing.expect(plugin_conf.result != null);
    try std.testing.expectEqualSlices(u8, "{\"cniVersion\":\"1.0.0\"}\n", plugin_conf.result.?.items);

    try std.testing.expect(plugin_conf.stderr_result != null);
    try std.testing.expectEqualSlices(u8, "diagnostic line\n", plugin_conf.stderr_result.?.items);
}
