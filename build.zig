const std = @import("std");
const mach = @import("mach");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const opts = .{
        .target = target,
        .optimize = optimize,
    };
    const deps = .{
        .mach = b.dependency("mach", .{
            .target = target,
            .optimize = optimize,
            // .core = true, // TODO: waiting for mach build improvements
        }),
        .assimp = b.dependency("assimp", .{
            .target = target,
            .optimize = optimize,
            .formats = @as([]const u8, "Obj,STL,Ply,glTF,glTF2"),
        }),
        .zflecs = b.dependency("zflecs", opts),
        .zmath = b.dependency("zmath", opts),
    };

    const amity = b.addModule("amity", .{
        .root_source_file = .{ .path = "src/root.zig" },
        .target = target,
        .optimize = optimize,
    });
    amity.addImport("mach", deps.mach.module("mach"));
    amity.addImport("flecs", deps.zflecs.module("zflecs"));
    amity.addImport("zmath", deps.zmath.module("zmath"));
    amity.linkLibrary(deps.assimp.artifact("assimp"));

    const app = try mach.CoreApp.init(b, deps.mach.builder, .{
        .name = "amity",
        .src = "src/main.zig",
        .target = target,
        .optimize = optimize,
        .deps = &.{
            .{ .name = "amity", .module = amity },
        },
        .platform = null,
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
