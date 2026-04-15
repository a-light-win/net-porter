const std = @import("std");

pub const TempFile = struct {
    path: []const u8,
    file: std.Io.File,
};

const TempFileManager = @This();

allocator: std.mem.Allocator,
io: std.Io,
dir_prefix: []const u8,
should_clean_file: bool = false,

temp_dir_path: []const u8,
temp_dir: std.Io.Dir,

temp_files: std.ArrayList([]const u8),
opened_files: std.ArrayList(std.Io.File),

pub fn deinit(self: *TempFileManager) void {
    for (self.opened_files.items) |file| {
        file.close(self.io);
    }
    self.opened_files.deinit(self.allocator);

    for (self.temp_files.items) |file| {
        if (self.should_clean_file) {
            self.temp_dir.deleteFile(self.io, file) catch {};
        }
        self.allocator.free(file);
    }
    self.temp_files.deinit(self.allocator);

    self.temp_dir.close(self.io);

    if (self.should_clean_file) {
        std.Io.Dir.cwd().deleteDir(self.io, self.temp_dir_path) catch {};
    }
    self.allocator.free(self.temp_dir_path);
}

pub fn tempFile(self: *TempFileManager, prefix: []const u8, subfix: []const u8) ![]const u8 {
    var prng = std.Random.DefaultPrng.init(@intCast(std.os.linux.getpid()));
    const rand = prng.random().int(u32);
    const file_path = try std.fmt.allocPrint(
        self.allocator,
        "{s}/{s}{x:0>8}{s}",
        .{ self.temp_dir_path, prefix, rand, subfix },
    );
    errdefer self.allocator.free(file_path);
    try self.temp_files.append(self.allocator, file_path);
    return file_path;
}

pub fn openedFile(self: *TempFileManager, prefix: []const u8, subfix: []const u8) !TempFile {
    const file_path = try self.tempFile(prefix, subfix);
    const f = try self.temp_dir.createFile(self.io, file_path, .{});
    errdefer f.close(self.io);
    try self.opened_files.append(self.allocator, f);
    return .{ .path = file_path, .file = f };
}

pub fn newTempFileManager(io: std.Io, allocator: std.mem.Allocator, dir_prefix: []const u8) !TempFileManager {
    var prng = std.Random.DefaultPrng.init(@intCast(std.os.linux.getpid()));
    const rand = prng.random().int(u64);
    const temp_dir_path = try std.fmt.allocPrint(
        allocator,
        "/tmp/{s}{x:0>16}",
        .{ dir_prefix, rand },
    );
    errdefer allocator.free(temp_dir_path);
    try std.Io.Dir.cwd().createDirPath(io, temp_dir_path);
    const temp_dir = try std.Io.Dir.cwd().openDir(io, temp_dir_path, .{});

    return TempFileManager{
        .allocator = allocator,
        .io = io,
        .dir_prefix = dir_prefix,

        .temp_dir_path = temp_dir_path,
        .temp_dir = temp_dir,

        .temp_files = std.ArrayList([]const u8).empty,
        .opened_files = std.ArrayList(std.Io.File).empty,
    };
}
