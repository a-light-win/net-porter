const std = @import("std");

/// Extract version string from build.zig.zon content at comptime.
/// Looks for the pattern `.version = "..."` and returns the quoted string.
fn extractVersion(zon: []const u8) []const u8 {
    const marker = ".version = \"";
    const start = std.mem.indexOf(u8, zon, marker) orelse
        @panic("version not found in build.zig.zon");
    const version_start = start + marker.len;
    const end = std.mem.indexOfScalar(u8, zon[version_start..], '"') orelse
        @panic("version end not found in build.zig.zon");
    return zon[version_start .. version_start + end];
}

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Extract version from build.zig.zon at comptime — single source of truth
    const version = comptime extractVersion(@embedFile("build.zig.zon"));

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .os_tag = .linux,
            .abi = .musl,
        },
    });

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // Create build_options module so source code can access version via
    // @import("build_options").version
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    const build_options_mod = build_options.createModule();

    const zigcli_pkg = b.dependency("cli", .{ .target = target });
    const zigcli_mod = zigcli_pkg.module("cli");

    const exe_root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zig-cli", .module = zigcli_mod },
            .{ .name = "build_options", .module = build_options_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "net-porter",
        .root_module = exe_root_mod,
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running "zig build").
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zig-cli", .module = zigcli_mod },
            .{ .name = "build_options", .module = build_options_mod },
        },
    });

    const exe_unit_tests = b.addTest(.{
        .root_module = test_root_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&exe.step);

    // coverage
    const run_cover = b.addSystemCommand(&.{
        "kcov",
        "--clean",
        "--exclude-path=/usr/",
        "--exclude-pattern=test.zig",
        b.pathJoin(&.{ b.install_path, "cover" }),
    });
    run_cover.addArtifactArg(exe_unit_tests);

    const clean_coverage = b.addSystemCommand(&.{
        "rm",
        "-rf",
        b.pathJoin(&.{ b.install_path, "cover" }),
    });

    const cover_step = b.step("cover", "Generate test coverage report");
    cover_step.dependOn(&clean_coverage.step);
    cover_step.dependOn(&run_cover.step);
}
