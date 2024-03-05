const std = @import("std");
const ecs = @import("mach").ecs;
const mach = @import("mach").core;
const math = @import("zmath");

const amity = @import("root.zig");
const common = @import("render/common.zig");
pub const Opaques = @import("render/Opaques.zig");
pub const Camera = @import("Camera.zig");

pub const Geometry = common.Geometry;

const gpu = mach.gpu;
const log = std.log.scoped(.amity_render);

g_buffer: common.GBuffer,
light_store: common.LightStore,
trans_uniform_buf: *gpu.Buffer,

post: common.DoubleBuffer,
color_correct_pipe: *gpu.RenderPipeline,

opaques: Opaques,

// ECS module defs
pub const name = .amity_renderer;
pub const components = struct {
    // Add this component if the entity needs re-uploaded to the GPU
    pub const dirty = void;
    pub const camera = Camera;
    pub const opaque_material = Opaques.Material;
    pub const geometry = Geometry;
    pub const light_directional = common.light.Directional;
};
pub const Mod = amity.World.Mod(@This());

pub fn init(mod: *Mod) !void {
    const ren = &mod.state;
    var ini: common.InitData = undefined;

    ren.g_buffer, ini.g_buffer_layout = common.GBuffer.init();
    errdefer ren.g_buffer.deinit();
    defer ini.g_buffer_layout.release();

    ren.light_store = .{};

    ren.trans_uniform_buf = mach.device.createBuffer(&.{
        .size = @sizeOf(common.Transforms),
        .usage = .{ .copy_dst = true, .uniform = true },
    });

    ren.post, ini.post_bind_layout, ini.post_storage_bind_layout = common.DoubleBuffer.init();
    errdefer ren.post.deinit();
    defer {
        ini.post_bind_layout.release();
        ini.post_storage_bind_layout.release();
    }

    const fullscreen_shader = mach.device.createShaderModuleWGSL("fullscreen.wgsl", @embedFile("shader/fullscreen.wgsl"));
    defer fullscreen_shader.release();

    const color_correct_shader = mach.device.createShaderModuleWGSL("color_correct.wgsl", @embedFile("shader/color_correct.wgsl"));
    defer color_correct_shader.release();

    const color_correct_layout = mach.device.createPipelineLayout(&gpu.PipelineLayout.Descriptor.init(.{
        .bind_group_layouts = &.{ini.post_bind_layout},
    }));
    defer color_correct_layout.release();

    ren.color_correct_pipe = mach.device.createRenderPipeline(&.{
        .layout = color_correct_layout,

        .vertex = gpu.VertexState.init(.{
            .module = fullscreen_shader,
            .entry_point = "vertex",
        }),

        .fragment = &gpu.FragmentState.init(.{
            .module = color_correct_shader,
            .entry_point = "fragment",
            .targets = &.{
                .{ .format = mach.descriptor.format },
            },
        }),
    });
    errdefer ren.color_correct_pipe.release();

    ren.opaques = try Opaques.init(mod, ini);

    log.debug("init", .{});
}

pub fn deinit(mod: *Mod) error{}!void {
    const ren = &mod.state;

    ren.g_buffer.deinit();
    ren.light_store.deinit();
    ren.trans_uniform_buf.release();

    ren.post.deinit();
    ren.color_correct_pipe.release();

    ren.opaques.deinit();
}

pub fn tick(mod: *Mod) !void {
    updateTransforms(mod);
    try mod.state.opaques.drawOpaques(mod);
    try mod.state.opaques.shadeOpaques(mod);
    colorCorrect(mod);

    // Remove dirty flags
    var it = mod.entities.query(.{ .all = &.{
        .{ .amity_renderer = &.{.dirty} },
    } });
    while (it.next()) |arche| {
        for (arche.slice(.entity, .id)) |id| {
            try mod.remove(id, .dirty);
        }
    }
}

fn updateTransforms(mod: *Mod) void {
    var it = mod.entities.query(.{ .all = &.{
        .{ .amity_renderer = &.{ .dirty, .camera } },
    } });
    var done = false;
    while (it.next()) |arche| {
        for (arche.slice(.amity_renderer, .camera)) |cam| {
            std.debug.assert(!done); // We don't yet support multiple cameras per scene
            done = true;

            const view = cam.view();
            const proj = cam.proj(mach.size());
            const vp = math.mul(view, proj);
            const inv_vp = math.inverse(vp);

            mach.queue.writeBuffer(mod.state.trans_uniform_buf, 0, &[_]common.Transforms{.{
                .view = view,
                .vp = vp,
                .inv_vp = inv_vp,
            }});
        }
    }
}

fn colorCorrect(mod: *Mod) void {
    const ren = &mod.state;

    const dest = mach.swap_chain.getCurrentTextureView().?;
    defer dest.release();

    const encoder = mach.device.createCommandEncoder(null);
    defer encoder.release();

    {
        const pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
            .color_attachments = &.{.{
                .view = dest,
                .clear_value = common.black,
                .load_op = .clear,
                .store_op = .store,
            }},
        }));
        defer pass.release();
        pass.setPipeline(ren.color_correct_pipe);
        pass.setBindGroup(0, ren.post.sourceBind(), null);
        pass.draw(3, 1, 0, 0);
        pass.end();
    }

    mach.queue.submit(&.{encoder.finish(null)});

    mach.swap_chain.present();
}
