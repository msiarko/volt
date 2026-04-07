const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const http = b.addModule("http", .{
        .root_source_file = b.path("src/http/server.zig"),
        .target = target,
        .optimize = optimize,
    });

    const extract = b.addModule("extract", .{
        .root_source_file = b.path("src/extract/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    http.addImport("extract", extract);

    const mod = b.addModule("volt", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "extract", .module = extract },
            .{ .name = "http", .module = http },
        },
    });

    const http_tests = b.addTest(.{
        .root_module = http,
    });

    const extractors_tests = b.addTest(.{
        .root_module = extract,
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_http_tests = b.addRunArtifact(http_tests);
    const run_extractors_tests = b.addRunArtifact(extractors_tests);
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");

    test_step.dependOn(&run_http_tests.step);
    test_step.dependOn(&run_extractors_tests.step);
    test_step.dependOn(&run_mod_tests.step);
}
