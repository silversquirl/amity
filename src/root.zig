const std = @import("std");
const flecs = @import("flecs");
const mach = @import("mach-core");

const Renderer = @import("Renderer.zig");

pub const Engine = struct {
    world: *flecs.world_t,

    pub const InitOptions = packed struct {
        renderer: bool = true,
    };

    pub fn init(opts: InitOptions) !Engine {
        const world = flecs.init();

        if (opts.renderer) {
            try Renderer.init(world);
        }

        _ = flecs.progress(world, 0);
        return .{
            .world = world,
        };
    }

    pub fn deinit(eng: *Engine) void {
        _ = flecs.fini(eng.world);
    }

    pub fn update(eng: *Engine, dt: f32) !bool {
        return !flecs.progress(eng.world, dt);
    }
};
