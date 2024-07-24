const std = @import("std");
const user = @import("../user.zig");

pub const DomainSocket = struct {
    path: []const u8 = "/run/net-porter.sock",
    owner: ?[]const u8 = null,
    group: ?[]const u8 = null,
    uid: ?std.posix.uid_t = null,
    gid: ?std.posix.gid_t = null,
    mode: std.posix.mode_t = 0o664,

    pub fn postInit(self: *DomainSocket) void {
        if (self.uid == null) {
            if (self.owner) |value| {
                self.uid = user.getUid(value);
            }
        }
        if (self.gid == null) {
            if (self.group) |value| {
                self.gid = user.getGid(value);
            }
        }
    }

    pub fn connect(self: DomainSocket) !std.net.Stream {
        return try std.net.connectUnixSocket(self.path);
    }

    pub fn listen(self: DomainSocket) !std.net.Server {
        const address = std.net.Address.initUnix(self.path) catch |e| {
            std.log.err(
                "Failed to create address: {s}, error: {s}",
                .{ self.path, @errorName(e) },
            );
            return e;
        };

        // Bind the socket to a file path
        std.fs.cwd().deleteFile(self.path) catch {};
        const server = address.listen(.{ .reuse_address = true }) catch |e| {
            std.log.err(
                "Failed to bind address: {s}, error: {s}",
                .{ self.path, @errorName(e) },
            );
            return e;
        };

        self.setSocketPermissions() catch {};

        return server;
    }

    fn setSocketPermissions(self: DomainSocket) !void {
        const file = std.fs.cwd().openFile(self.path, .{ .mode = .read_only }) catch |e| {
            std.log.err(
                "Failed to open socket file: {s}, error: {s}",
                .{ self.path, @errorName(e) },
            );
            return e;
        };
        defer file.close();

        if (self.uid != null or self.gid != null) {
            file.chown(self.uid, self.gid) catch |e| {
                std.log.err(
                    "Failed to set socket permissions: file: {s}, error: {s}",
                    .{ self.path, @errorName(e) },
                );
                return e;
            };
        }

        file.chmod(self.mode) catch |e| {
            std.log.err(
                "Failed to set socket permissions: file: {s}, error: {s}",
                .{ self.path, @errorName(e) },
            );
            return e;
        };
    }
};

test {
    _ = @import("domain_socket_test.zig");
}
