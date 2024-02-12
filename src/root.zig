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

// const vertex_size = 2 * @sizeOf(f32);

// pub const Test = struct {
//     world: *flecs.world_t,
//     pipeline: *gpu.RenderPipeline,
//     buffer: *gpu.Buffer,
//     verts: [3][2]f32 = undefined,
//     rotation: f32 = 0,

//     pub fn init() !Test {
//         const shader = mach.device.createShaderModuleWGSL("shader.wgsl", @embedFile("shader.wgsl"));
//         defer shader.release();

//         const pipeline = mach.device.createRenderPipeline(&.{
//             .fragment = &gpu.FragmentState.init(.{
//                 .module = shader,
//                 .entry_point = "fragment",
//                 .targets = &.{
//                     .{
//                         .format = mach.descriptor.format,
//                         .blend = &.{},
//                     },
//                 },
//             }),

//             .vertex = gpu.VertexState.init(.{
//                 .module = shader,
//                 .entry_point = "vertex",
//                 .buffers = &.{
//                     gpu.VertexBufferLayout.init(.{
//                         .array_stride = vertex_size,
//                         .attributes = &.{.{
//                             .format = .float32x2,
//                             .offset = 0,
//                             .shader_location = 0,
//                         }},
//                     }),
//                 },
//             }),
//         });

//         return .{
//             .world = flecs.init(),
//             .pipeline = pipeline,
//             .buffer = mach.device.createBuffer(&.{
//                 .usage = .{ .vertex = true, .copy_dst = true },
//                 .size = 3 * vertex_size,
//             }),
//         };
//     }

//     pub fn deinit(t: *Test) void {
//         t.pipeline.release();
//         _ = flecs.fini(t.world);
//     }

//     pub fn update(t: *Test, dt: f32) !void {
//         t.rotation += dt;
//         for (&t.verts, 0..) |*v, i| {
//             const angle = @as(f32, @floatFromInt(i)) * std.math.tau / @as(f32, t.verts.len) + t.rotation;
//             v[0] = @sin(angle) * 0.5;
//             v[1] = @cos(angle) * 0.5;
//         }
//     }

//     pub fn draw(t: *Test, dest: *gpu.TextureView) !void {
//         const buf = t.encodeDraw(.{
//             .view = dest,
//             .clear_value = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
//             .load_op = .clear,
//             .store_op = .store,
//         });
//         mach.queue.submit(&.{buf});
//     }

//     fn encodeDraw(t: *Test, dest: gpu.RenderPassColorAttachment) *gpu.CommandBuffer {
//         mach.queue.writeBuffer(t.buffer, 0, &t.verts);

//         const encoder = mach.device.createCommandEncoder(null);
//         defer encoder.release();

//         {
//             const pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
//                 .color_attachments = &.{dest},
//             }));
//             defer pass.release();
//             pass.setPipeline(t.pipeline);
//             pass.setVertexBuffer(0, t.buffer, 0, 3 * vertex_size);
//             pass.draw(3, 1, 0, 0);
//             pass.end();
//         }

//         return encoder.finish(null);
//     }
// };
