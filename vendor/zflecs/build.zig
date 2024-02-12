const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const zflecs_c_cpp = b.addStaticLibrary(.{
        .name = "zflecs",
        .target = target,
        .optimize = optimize,
    });
    zflecs_c_cpp.linkLibC();
    zflecs_c_cpp.addIncludePath(.{ .path = "libs/flecs" });
    zflecs_c_cpp.addCSourceFile(.{
        .file = .{ .path = "libs/flecs/flecs.c" },
        .flags = &.{
            "-fno-sanitize=undefined",
            "-DFLECS_NO_CPP",
            "-DFLECS_USE_OS_ALLOC",
            if (@import("builtin").mode == .Debug) "-DFLECS_SANITIZE" else "",
        },
    });

    if (target.result.os.tag == .windows) {
        zflecs_c_cpp.linkSystemLibrary("ws2_32");
    }

    const zflecs = b.addModule("zflecs", .{
        .root_source_file = .{ .path = "src/zflecs.zig" },
    });
    zflecs.linkLibrary(zflecs_c_cpp);

    const tests = b.addTest(.{
        .name = "zflecs-tests",
        .root_source_file = .{ .path = "src/zflecs.zig" },
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("zflecs", zflecs);
    const test_step = b.step("test", "Run zflecs tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
