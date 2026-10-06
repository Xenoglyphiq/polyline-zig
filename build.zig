const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library: `@import("polyline")`.
    const mod = b.addModule("polyline", .{
        .root_source_file = b.path("src/polyline.zig"),
        .target = target,
    });

    // zig build test: unit tests and the fuzz target (`zig build test --fuzz`).
    const tests = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // zig build conformance: every case in the vendored spec's manifest.
    const runner = b.addExecutable(.{
        .name = "conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "polyline", .module = mod }},
        }),
    });
    const run_conformance = b.addRunArtifact(runner);
    run_conformance.addFileArg(b.path(".spec/conformance/manifest.json"));
    const conformance_step = b.step("conformance", "Run the spec's conformance cases");
    conformance_step.dependOn(&run_conformance.step);

    // zig build examples: the three canonical examples.
    const examples_step = b.step("examples", "Run the three canonical examples");
    inline for (.{ "encode_route", "decode_route", "precision_6" }) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "polyline", .module = mod }},
            }),
        });
        examples_step.dependOn(&b.addRunArtifact(exe).step);
    }
}
