const std = @import("std");
const LogSettings = @import("LogSettings.zig");
const Logger = @This();

const LogBufferedWriter = std.io.BufferedWriter(8192, std.fs.File.Writer);

info_writer: LogBufferedWriter,
error_writer: LogBufferedWriter,
log_settings: ?LogSettings = null,

pub fn log(
    logger: *Logger,
    comptime message_level: std.log.Level,
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!logger.logEnabled(message_level, scope)) {
        return;
    }

    const level_txt = comptime message_level.asText();
    const scope_txt = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    var bufferedWriter = switch (message_level) {
        .err => logger.error_writer,
        .warn => logger.error_writer,
        .info => logger.info_writer,
        .debug => logger.info_writer,
    };
    const writer = bufferedWriter.writer();

    nosuspend {
        writer.print("{}ms ", .{std.time.milliTimestamp()}) catch return;
        writer.print(level_txt ++ scope_txt ++ format ++ "\n", args) catch return;
        bufferedWriter.flush() catch return;
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

    var buf: [1024]u8 = undefined;
    {
        const f = try std.fs.cwd().openFile(infoFile.path, .{});
        defer f.close();

        const len = try f.reader().readAll(&buf);
        try std.testing.expectEqual(true, len > 0);
        const infoLog = buf[0..len];
        try std.testing.expectEqual(
            true,
            std.mem.indexOf(u8, infoLog, "info message") != null,
        );
    }

    {
        const f = try std.fs.cwd().openFile(errFile.path, .{});
        defer f.close();

        const warnLen = try f.reader().readAll(&buf);
        const warnLog = buf[0..warnLen];
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
    comptime scope: @Type(.EnumLiteral),
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
    return newFileLogger(std.io.getStdOut(), std.io.getStdErr());
}

pub fn newFileLogger(infoFile: std.fs.File, errorFile: std.fs.File) Logger {
    const infoWriter = infoFile.writer();
    const errorWriter = errorFile.writer();

    return .{
        .info_writer = LogBufferedWriter{ .unbuffered_writer = infoWriter },
        .error_writer = LogBufferedWriter{ .unbuffered_writer = errorWriter },
    };
}
