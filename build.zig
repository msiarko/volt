const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core = b.addModule("core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const extract = b.addModule("extract", .{
        .root_source_file = b.path("src/extract/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core },
        },
    });

    const mod = b.addModule("volt", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core },
            .{ .name = "extract", .module = extract },
        },
    });

    const core_tests = b.addTest(.{
        .root_module = core,
        .name = "core",
    });

    const extract_tests = b.addTest(.{
        .root_module = extract,
        .name = "extract",
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .name = "mod",
    });
    const run_core_tests = b.addRunArtifact(core_tests);
    const run_extract_tests = b.addRunArtifact(extract_tests);
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_extract_tests.step);
    test_step.dependOn(&run_mod_tests.step);
}
