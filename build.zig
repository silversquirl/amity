const std = @import("std");
const mach_core = @import("mach_core");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const deps = .{
        .mach = b.dependency("mach_core", .{
            .target = target,
            .optimize = optimize,
        }),
        .model3d = b.dependency("mach_model3d", .{
            .target = target,
            .optimize = optimize,
        }),
        .zflecs = b.dependency("zflecs", .{
            .target = target,
            .optimize = optimize,
        }),
    };

    const amity = b.addModule("amity", .{
        .root_source_file = .{ .path = "src/root.zig" },
        .target = target,
        .optimize = optimize,
    });
    amity.addImport("mach-core", deps.mach.module("mach-core"));
    amity.addImport("model3d", deps.model3d.module("mach-model3d"));
    amity.addImport("flecs", deps.zflecs.module("zflecs"));

    const app = try mach_core.App.init(b, deps.mach.builder, .{
        .name = "amity",
        .src = "src/main.zig",
        .target = target,
        .optimize = optimize,
        .deps = &.{
            .{ .name = "amity", .module = amity },
        },
    });
    if (b.args) |args| {
        app.run.addArgs(args);
    }
    b.step("run", "Run the app").dependOn(&app.run.step);

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "test/root.zig" },
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("amity", amity);
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
