const std = @import("std");
const LogSettings = @import("LogSettings.zig");
const Logger = @This();

info_writer: std.fs.File.Writer = undefined,
error_writer: std.fs.File.Writer = undefined,
info_buffer: [4096]u8 = undefined,
error_buffer: [4096]u8 = undefined,
initialized: bool = false,
log_settings: ?LogSettings = null,

fn ensureInitialized(self: *Logger) void {
    if (!self.initialized) {
        self.info_writer = std.fs.File.stdout().writer(&self.info_buffer);
        self.error_writer = std.fs.File.stderr().writer(&self.error_buffer);
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

    if (!logger.logEnabled(message_level, scope)) {
        return;
    }

    const level_txt = comptime message_level.asText();
    const scope_txt = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    const writer = switch (message_level) {
        .err, .warn => &logger.error_writer,
        .info, .debug => &logger.info_writer,
    };

    nosuspend {
        writer.interface.print("{d}ms ", .{std.time.milliTimestamp()}) catch return;
        writer.interface.print(level_txt ++ scope_txt ++ format ++ "\n", args) catch return;
        writer.interface.flush() catch return;
    }
}

test "log" {
    const test_utils = @import("../test_utils.zig");
    const allocator = std.testing.allocator;

    var temp_file_manager = try test_utils.newTempFileManager(
        allocator,
        "net-porter-test-logger-",
    );
    defer temp_file_manager.deinit();

    const infoFile = try temp_file_manager.openedFile("", "info.log");
    const errFile = try temp_file_manager.openedFile("", "error.log");
    var logger = newFileLogger(infoFile.file, errFile.file);

    logger.log(.info, .not_exists, "info message", .{});
    logger.log(.warn, .not_exists, "warn message", .{});

    {
        const f = try std.fs.cwd().openFile(infoFile.path, .{});
        defer f.close();

        var read_buffer: [1024]u8 = undefined;
        var file_reader = f.reader(&read_buffer);
        const infoLog = try file_reader.interface.allocRemaining(allocator, .limited(1024));
        defer allocator.free(infoLog);
        try std.testing.expectEqual(true, infoLog.len > 0);
        try std.testing.expectEqual(
            true,
            std.mem.indexOf(u8, infoLog, "info message") != null,
        );
    }

    {
        const f = try std.fs.cwd().openFile(errFile.path, .{});
        defer f.close();

        var read_buffer: [1024]u8 = undefined;
        var file_reader = f.reader(&read_buffer);
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

pub fn newFileLogger(infoFile: std.fs.File, errorFile: std.fs.File) Logger {
    var logger = Logger{};
    logger.info_writer = infoFile.writer(&logger.info_buffer);
    logger.error_writer = errorFile.writer(&logger.error_buffer);
    logger.initialized = true;
    return logger;
}
