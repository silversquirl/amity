const std = @import("std");
const flecs = @import("flecs");
const mach = @import("mach-core");

const gpu = mach.gpu;

// TODO: rendering state should be handled through a few global entities, for better extensibility.
//        - Postprocessor: contains post-processing data such as attachment double-buffer and post-processing vertex shader
//        - do we need more? probably
//       Rendering systems can then use those entities to do rendering in a completely modular way

const Renderer = @This();
phase: flecs.entity_t,
color_correct_pipe: *gpu.RenderPipeline,

post_attach: [2]gpu.RenderPassColorAttachment,
post_attach_idx: u1 = 0,

pub const OpaqueMaterial = struct {
    _: i32,
};
pub const Geometry = struct {
    _: i32,
};

pub fn init(world: *flecs.world_t) !void {
    const post_vertex_shader = mach.device.createShaderModuleWGSL("post_vertex.wgsl", @embedFile("shader/post_vertex.wgsl"));
    defer post_vertex_shader.release();

    const color_correct_shader = mach.device.createShaderModuleWGSL("color_correct.wgsl", @embedFile("shader/color_correct.wgsl"));
    defer color_correct_shader.release();

    const color_correct_pipe = mach.device.createRenderPipeline(&.{
        .fragment = &gpu.FragmentState.init(.{
            .module = color_correct_shader,
            .entry_point = "fragment",
            .targets = &.{
                .{
                    .format = mach.descriptor.format,
                    .blend = &.{},
                },
            },
        }),

        .vertex = gpu.VertexState.init(.{
            .module = post_vertex_shader,
            .entry_point = "vertex",
        }),
    });
    errdefer color_correct_pipe.release();

    var post_attach: [2]gpu.RenderPassColorAttachment = undefined;
    for (&post_attach) |*a| {
        a.* = .{
            .view = createRenderTexture(),
            .clear_value = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 },
            .load_op = .clear,
            .store_op = .store,
        };
    }
    errdefer for (post_attach) |a| {
        a.view.?.release();
    };

    const ren = try mach.allocator.create(Renderer);
    ren.* = .{
        .phase = flecs.new_w_id(world, flecs.Phase),
        .color_correct_pipe = color_correct_pipe,
        .post_attach = post_attach,
    };
    errdefer deinit(ren);

    flecs.COMPONENT(world, OpaqueMaterial);
    flecs.COMPONENT(world, Geometry);

    // TODO: enforce strict ordering
    {
        var desc: flecs.system_desc_t = .{
            .callback = geometry,
            .ctx = ren,
        };
        desc.query.filter.terms[0] = .{ .id = flecs.id(OpaqueMaterial) };
        desc.query.filter.terms[1] = .{ .id = flecs.id(Geometry) };

        flecs.SYSTEM(world, "amity/render/deferred/geometry", ren.phase, &desc);
    }

    {
        var desc: flecs.system_desc_t = .{
            .callback = shade,
            .ctx = ren,
        };

        flecs.SYSTEM(world, "amity/render/deferred/shade", ren.phase, &desc);
    }

    {
        var desc: flecs.system_desc_t = .{
            .callback = colorCorrect,
            .ctx = ren,
            .ctx_free = deinit,
        };

        flecs.SYSTEM(world, "amity/render/color_correct", ren.phase, &desc);
    }

    std.debug.print("registered render system\n", .{});
}

fn deinit(ctx: ?*anyopaque) callconv(.C) void {
    const ren: *Renderer = @ptrCast(@alignCast(ctx.?));
    ren.color_correct_pipe.release();
    mach.allocator.destroy(ren);
}

/// Create an HDR RGBA texture the same size as the swapchain, and suitable for postprocessing use
fn createRenderTexture() *gpu.TextureView {
    const size = mach.size();
    const tex = mach.device.createTexture(&.{
        .usage = .{
            .render_attachment = true,
            .texture_binding = true,
        },
        .size = .{
            .width = size.width,
            .height = size.height,
            .depth_or_array_layers = 1,
        },
        .format = .rgba16_float,
    });
    defer tex.release();
    return tex.createView(null);
}

//// Rendering phases ////

fn geometry(it: *flecs.iter_t) callconv(.C) void {
    const ren: *Renderer = @ptrCast(@alignCast(it.param.?));
    _ = ren;
}

fn shade(it: *flecs.iter_t) callconv(.C) void {
    const ren: *Renderer = @ptrCast(@alignCast(it.param.?));
    _ = ren;
}

fn colorCorrect(it: *flecs.iter_t) callconv(.C) void {
    const ren: *Renderer = @ptrCast(@alignCast(it.param.?));

    const dest = mach.swap_chain.getCurrentTextureView().?;
    defer dest.release();

    const encoder = mach.device.createCommandEncoder(null);
    defer encoder.release();

    {
        const pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
            .color_attachments = &.{.{
                .view = dest,
                .clear_value = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
                .load_op = .clear,
                .store_op = .store,
            }},
        }));
        defer pass.release();
        pass.setPipeline(ren.color_correct_pipe);
        pass.draw(3, 1, 0, 0);
        pass.end();
    }

    mach.queue.submit(&.{encoder.finish(null)});

    mach.swap_chain.present();
}
