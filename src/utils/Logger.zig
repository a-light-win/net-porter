const std = @import("std");
const LogSettings = @import("LogSettings.zig");
const Logger = @This();

info_writer: std.Io.File.Writer = undefined,
error_writer: std.Io.File.Writer = undefined,
info_buffer: [4096]u8 = undefined,
error_buffer: [4096]u8 = undefined,
initialized: bool = false,
io: ?std.Io = null,
log_settings: ?LogSettings = null,

fn ensureInitialized(self: *Logger) void {
    if (!self.initialized) {
        const io = self.io orelse return;
        self.info_writer = std.Io.File.stdout().writer(io, &self.info_buffer);
        self.error_writer = std.Io.File.stderr().writer(io, &self.error_buffer);
        self.initialized = true;
    }
}

pub fn log(
    logger: *Logger,
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    logger.ensureInitialized();
    if (!logger.initialized) return;

    if (!logger.logEnabled(message_level, scope)) {
        return;
    }

    const level_txt = comptime message_level.asText();
    const scope_txt = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    const writer = switch (message_level) {
        .err, .warn => &logger.error_writer,
        .info, .debug => &logger.info_writer,
    };

    const io = logger.io.?;
    const ts = std.Io.Timestamp.now(io, .awake);

    nosuspend {
        writer.interface.print("{d}ms ", .{ts.toMilliseconds()}) catch return;
        writer.interface.print(level_txt ++ scope_txt ++ format ++ "\n", args) catch return;
        writer.interface.flush() catch return;
    }
}

test "log" {
    const test_utils = @import("../test_utils.zig");
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var temp_file_manager = try test_utils.newTempFileManager(
        io,
        allocator,
        "net-porter-test-logger-",
    );
    defer temp_file_manager.deinit();

    const infoFile = try temp_file_manager.openedFile("", "info.log");
    const errFile = try temp_file_manager.openedFile("", "error.log");
    var logger = newFileLogger(io, infoFile.file, errFile.file);

    logger.log(.info, .not_exists, "info message", .{});
    logger.log(.warn, .not_exists, "warn message", .{});

    {
        const f = try std.Io.Dir.cwd().openFile(io, infoFile.path, .{});
        defer f.close(io);

        var read_buffer: [1024]u8 = undefined;
        var file_reader = f.reader(io, &read_buffer);
        const infoLog = try file_reader.interface.allocRemaining(allocator, .limited(1024));
        defer allocator.free(infoLog);
        try std.testing.expectEqual(true, infoLog.len > 0);
        try std.testing.expectEqual(
            true,
            std.mem.indexOf(u8, infoLog, "info message") != null,
        );
    }

    {
        const f = try std.Io.Dir.cwd().openFile(io, errFile.path, .{});
        defer f.close(io);

        var read_buffer: [1024]u8 = undefined;
        var file_reader = f.reader(io, &read_buffer);
        const warnLog = try file_reader.interface.allocRemaining(allocator, .limited(1024));
        defer allocator.free(warnLog);
        try std.testing.expectEqual(
            true,
            std.mem.indexOf(u8, warnLog, "warn message") != null,
        );
    }

    temp_file_manager.should_clean_file = true;
}

pub inline fn logEnabled(
    logger: Logger,
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
) bool {
    if (logger.log_settings) |settings| {
        return settings.logEnabled(message_level, scope);
    }
    return true;
}

test "logEnabled" {
    const allocator = std.testing.allocator;

    const config =
        \\ {
        \\    "level": "info",
        \\    "scope_levels": [
        \\      {"scope": "logger", "level": "warn"}
        \\    ]
        \\ }
    ;

    const parsed = try std.json.parseFromSlice(LogSettings, allocator, config, .{});
    defer parsed.deinit();

    var logger = newLogger();
    try std.testing.expectEqual(true, logger.logEnabled(.warn, .not_exists));

    logger.log_settings = parsed.value;

    try std.testing.expectEqual(true, logger.logEnabled(.warn, .not_exists));
    try std.testing.expectEqual(true, logger.logEnabled(.info, .not_exists));
    try std.testing.expectEqual(false, logger.logEnabled(.debug, .not_exists));

    try std.testing.expectEqual(true, logger.logEnabled(.err, .logger));
    try std.testing.expectEqual(true, logger.logEnabled(.warn, .logger));
    try std.testing.expectEqual(false, logger.logEnabled(.info, .logger));
}

pub fn newLogger() Logger {
    return .{};
}

pub fn newFileLogger(io: std.Io, infoFile: std.Io.File, errorFile: std.Io.File) Logger {
    var logger = Logger{ .io = io };
    logger.info_writer = infoFile.writer(io, &logger.info_buffer);
    logger.error_writer = errorFile.writer(io, &logger.error_buffer);
    logger.initialized = true;
    return logger;
}
