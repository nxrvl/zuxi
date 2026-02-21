const std = @import("std");

pub const BuildMode = enum {
    lite,
    full,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build configuration: "lite" vs "full"
    const build_mode = b.option(
        BuildMode,
        "mode",
        "Build configuration: lite (core commands only) or full (all commands + TUI)",
    ) orelse .full;

    const options = b.addOptions();
    options.addOption(BuildMode, "build_mode", build_mode);

    // Root module
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.addOptions("build_options", options);

    // Executable
    const exe = b.addExecutable(.{
        .name = "zuxi",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Build and run Zuxi");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.addOptions("build_options", options);

    const main_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_main_tests = b.addRunArtifact(main_tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_main_tests.step);
}
