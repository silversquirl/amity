pub const std = @import("std");
const flecs = @import("flecs");
const mach = @import("mach").core;
const math = @import("zmath");

pos: [3]f32,
target: [3]f32 = .{ 0, 0, 0 },
up: [3]f32 = .{ 0, 1, 0 },

fov: f32 = std.math.tau / 8.0,
near: f32 = 0.1,
far: f32 = 100,

const Camera = @This();

pub fn view(cam: Camera) math.Mat {
    return math.lookAtRh(
        math.loadArr3w(cam.pos, 1),
        math.loadArr3w(cam.target, 1),
        math.loadArr3(cam.up),
    );
}

pub fn proj(cam: Camera, size: mach.Size) math.Mat {
    const width: f32 = @floatFromInt(size.width);
    const height: f32 = @floatFromInt(size.height);

    return math.perspectiveFovRh(cam.fov, width / height, cam.near, cam.far);
}
