const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const extract_enabled = b.option(bool, "extract", "Enable built-in extractors") orelse false;
    const testing_enabled = b.option(bool, "testing", "Enable built-in testing tools") orelse false;
    const middleware_enabled = b.option(bool, "middleware", "Enable built-in middleware system") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "extract_enabled", extract_enabled);
    options.addOption(bool, "testing_enabled", testing_enabled);
    options.addOption(bool, "middleware_enabled", middleware_enabled);

    const options_mod = options.createModule();

    const core = b.addModule("core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const core_tests = b.addTest(.{
        .root_module = core,
        .name = "core",
    });
    const run_core_tests = b.addRunArtifact(core_tests);
    const core_test_step = b.step("core test", "Run core tests");
    core_test_step.dependOn(&run_core_tests.step);

    var extract: ?*std.Build.Module = null;
    var run_extract_tests: ?*std.Build.Step.Run = null;
    if (extract_enabled) {
        const extract_mod = b.addModule("extract", .{
            .root_source_file = b.path("src/extract/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "core", .module = core }},
        });
        const extract_tests = b.addTest(.{
            .root_module = extract_mod,
            .name = "extract",
        });

        const extract_tests_art = b.addRunArtifact(extract_tests);

        const extract_test_step = b.step("extract test", "Run extract tests");
        extract_test_step.dependOn(&extract_tests_art.step);
        extract = extract_mod;
        run_extract_tests = extract_tests_art;
    }

    const mod = b.addModule("volt", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("options", options_mod);
    mod.addImport("core", core);
    if (extract) |extract_mod| {
        mod.addImport("extract", extract_mod);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .name = "mod",
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_core_tests.step);
    if (run_extract_tests) |extract_tests| {
        test_step.dependOn(&extract_tests.step);
    }
    test_step.dependOn(&run_mod_tests.step);
}
