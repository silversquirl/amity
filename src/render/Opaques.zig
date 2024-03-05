const std = @import("std");
const ecs = @import("mach").ecs;
const mach = @import("mach").core;
const math = @import("zmath");

const Renderer = @import("../Renderer.zig");
const common = @import("common.zig");
const gpu = mach.gpu;

pub const Opaques = @This();

material_store: MaterialStore,

geom_pipe: *gpu.RenderPipeline,
geom_bind: *gpu.BindGroup,
geom_uniform_buf: *gpu.Buffer,
shade_pipe: *gpu.ComputePipeline,
shade_bind: *gpu.BindGroup,
shading_data_bind_layout: *gpu.BindGroupLayout,

const GeometryUniforms = extern struct {
    material_idx: u32,
};

// TODO: use ECS relationships to avoid duplicating materials for each mesh
pub const Material = struct {
    color: [3]u8,
    metallic: f32,
    roughness: f32,
    ior: f32,

    fn toGpu(mat: Material) Gpu {
        return .{
            .color = common.packColor(mat.color),
            .metallic = mat.metallic,
            .roughness = mat.roughness,
            .ior = mat.ior,
        };
    }

    const Gpu = extern struct {
        color: u32,
        metallic: f32,
        roughness: f32,
        ior: f32,
    };
};

const MaterialStore = struct {
    buf: common.UploadBuffer(Material.Gpu, .{ .storage = true }) = .{},

    pub fn bindGroupLayoutEntry(binding: u32) gpu.BindGroupLayout.Entry {
        return .{
            .binding = binding,
            .visibility = .{ .fragment = true, .compute = true },
            .buffer = .{
                .type = .read_only_storage,
                .min_binding_size = 0,
            },
        };
    }

    pub fn deinit(store: *MaterialStore) void {
        store.buf.deinit();
    }

    pub fn upload(store: *MaterialStore) void {
        store.buf.upload();
    }

    pub fn clear(store: *MaterialStore) void {
        store.buf.clearRetainingCapacity();
    }
    pub fn append(store: *MaterialStore, mat: Material) !void {
        try store.buf.append(mat.toGpu());
    }
};

pub fn init(mod: *Renderer.Mod, ini: common.InitData) !Opaques {
    const ren = &mod.state;

    const deferred_shader = mach.device.createShaderModuleWGSL("deferred.wgsl", @embedFile("../shader/deferred.wgsl"));
    defer deferred_shader.release();

    const geom_uniform_layout = mach.device.createBindGroupLayout(&gpu.BindGroupLayout.Descriptor.init(.{
        .entries = &.{
            common.Transforms.bindEntry(0),
            .{
                .binding = 1,
                .visibility = .{ .fragment = true },
                .buffer = .{
                    .type = .uniform,
                    .min_binding_size = @sizeOf(GeometryUniforms),
                },
            },
        },
    }));
    defer geom_uniform_layout.release();

    const geom_layout = mach.device.createPipelineLayout(&gpu.PipelineLayout.Descriptor.init(.{
        .bind_group_layouts = &.{geom_uniform_layout},
    }));
    defer geom_layout.release();

    const geom_pipe = mach.device.createRenderPipeline(&.{
        .layout = geom_layout,

        .vertex = gpu.VertexState.init(.{
            .module = deferred_shader,
            .entry_point = "vertex",
            .buffers = &.{
                gpu.VertexBufferLayout.init(.{
                    .array_stride = 3 * @sizeOf(f32),
                    .attributes = &.{
                        .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
                    },
                }),
                gpu.VertexBufferLayout.init(.{
                    .array_stride = 3 * @sizeOf(f32),
                    .attributes = &.{
                        .{ .format = .float32x3, .offset = 0, .shader_location = 1 },
                    },
                }),
            },
        }),

        .depth_stencil = &.{
            .format = .depth24_plus,
            .depth_write_enabled = .true,
            .depth_compare = .less,
        },

        .fragment = &gpu.FragmentState.init(.{
            .module = deferred_shader,
            .entry_point = "fragment",
            .targets = common.GBuffer.targets,
        }),
    });
    errdefer geom_pipe.release();

    const geom_uniform_buf = mach.device.createBuffer(&.{
        .size = @sizeOf(GeometryUniforms),
        .usage = .{ .copy_dst = true, .uniform = true },
    });
    errdefer geom_uniform_buf.release();

    const geom_bind = mach.device.createBindGroup(&gpu.BindGroup.Descriptor.init(.{
        .layout = geom_pipe.getBindGroupLayout(0),
        .entries = &.{
            .{ .binding = 0, .buffer = ren.trans_uniform_buf, .size = @sizeOf(common.Transforms) },
            .{ .binding = 1, .buffer = geom_uniform_buf, .size = @sizeOf(GeometryUniforms) },
        },
    }));

    const shade_bind_layout = mach.device.createBindGroupLayout(&gpu.BindGroupLayout.Descriptor.init(.{
        .entries = &.{.{
            .binding = 0,
            .visibility = .{ .fragment = true, .compute = true },
            .buffer = .{
                .type = .uniform,
                .min_binding_size = @sizeOf(common.Transforms),
            },
        }},
    }));
    defer shade_bind_layout.release();

    const shading_data_bind_layout = mach.device.createBindGroupLayout(&gpu.BindGroupLayout.Descriptor.init(.{
        .entries = &.{
            MaterialStore.bindGroupLayoutEntry(0),
            common.LightStore.bindGroupLayoutEntry(1),
        },
    }));
    errdefer shading_data_bind_layout.release();

    const shade_bind = mach.device.createBindGroup(&gpu.BindGroup.Descriptor.init(.{
        .layout = shade_bind_layout,
        .entries = &.{
            .{ .binding = 0, .buffer = ren.trans_uniform_buf, .size = @sizeOf(common.Transforms) },
        },
    }));

    const shade_layout = mach.device.createPipelineLayout(&gpu.PipelineLayout.Descriptor.init(.{
        .bind_group_layouts = &.{
            shade_bind_layout,
            ini.g_buffer_layout,
            shading_data_bind_layout,
            ini.post_storage_bind_layout,
        },
    }));
    defer shade_layout.release();

    const shade_pipe = mach.device.createComputePipeline(&.{
        .layout = shade_layout,
        .compute = mach.gpu.ProgrammableStageDescriptor.init(.{
            .module = deferred_shader,
            .entry_point = "render",
        }),
    });
    errdefer shade_pipe.release();

    return .{
        .material_store = .{},
        .geom_pipe = geom_pipe,
        .geom_bind = geom_bind,
        .geom_uniform_buf = geom_uniform_buf,
        .shade_pipe = shade_pipe,
        .shade_bind = shade_bind,
        .shading_data_bind_layout = shading_data_bind_layout,
    };
}

pub fn deinit(opaques: *Opaques) void {
    opaques.material_store.deinit();

    opaques.geom_pipe.release();
    opaques.geom_bind.release();
    opaques.shade_pipe.release();
    opaques.shade_bind.release();
    opaques.shading_data_bind_layout.release();
}

pub fn drawOpaques(opaques: *Opaques, mod: *Renderer.Mod) !void {
    const ren = &mod.state;

    // TODO: cache material data
    opaques.material_store.clear();

    const encoder = mach.device.createCommandEncoder(null);
    defer encoder.release();

    // Draw to g-buffer
    // TODO: batching
    var it = mod.entities.query(.{ .all = &.{
        .{ .amity_renderer = &.{ .opaque_material, .geometry } },
    } });
    var i: u32 = 0;
    while (it.next()) |arche| {
        for (arche.slice(.amity_renderer, .opaque_material)) |m| {
            try opaques.material_store.append(m);
        }

        for (arche.slice(.amity_renderer, .geometry)) |g| {
            // TODO: cache uniform data
            mach.queue.writeBuffer(opaques.geom_uniform_buf, 0, &[_]GeometryUniforms{.{
                .material_idx = i,
            }});

            const pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
                .color_attachments = &.{.{
                    .view = ren.g_buffer.normal_material,
                    .clear_value = common.black,
                    .load_op = if (i == 0) .clear else .load,
                    .store_op = .store,
                }},
                .depth_stencil_attachment = &.{
                    .view = ren.g_buffer.depth,
                    .depth_clear_value = 1,
                    .depth_load_op = if (i == 0) .clear else .load,
                    .depth_store_op = .store,
                },
            }));
            defer pass.release();

            pass.setPipeline(opaques.geom_pipe);
            pass.setBindGroup(0, opaques.geom_bind, &.{});
            pass.setIndexBuffer(g.index_buffer, .uint32, 0, g.index_count * @sizeOf(u32));
            pass.setVertexBuffer(0, g.pos_buffer, 0, g.vertex_count * 3 * @sizeOf(f32));
            pass.setVertexBuffer(1, g.normal_buffer, 0, g.vertex_count * 3 * @sizeOf(f32));
            pass.drawIndexed(g.index_count, 1, 0, 0, 0);
            pass.end();

            i += 1;
        }
    }

    mach.queue.submit(&.{encoder.finish(null)});
    opaques.material_store.upload();
}

pub fn shadeOpaques(opaques: *Opaques, mod: *Renderer.Mod) !void {
    const ren = &mod.state;

    // TODO: cache light data
    ren.light_store.clear();
    var it = mod.entities.query(.{ .all = &.{
        .{ .amity_renderer = &.{.light_directional} },
    } });
    while (it.next()) |arche| {
        for (arche.slice(.amity_renderer, .light_directional)) |l| {
            try ren.light_store.append(l);
        }
    }
    try ren.light_store.upload();

    // TODO: caching
    const data_bind = mach.device.createBindGroup(&gpu.BindGroup.Descriptor.init(.{
        .layout = opaques.shading_data_bind_layout,
        .entries = &.{
            opaques.material_store.buf.bindGroupEntry(0),
            ren.light_store.dir.bindGroupEntry(1),
        },
    }));
    defer data_bind.release();

    // Shade drawn geometry
    const encoder = mach.device.createCommandEncoder(null);
    defer encoder.release();
    const pass = encoder.beginComputePass(null);
    defer pass.release();

    pass.setPipeline(opaques.shade_pipe);
    pass.setBindGroup(0, opaques.shade_bind, null);
    pass.setBindGroup(1, ren.g_buffer.bind, null);
    pass.setBindGroup(2, data_bind, null);
    pass.setBindGroup(3, ren.post.targetBind(), null);

    const size = mach.size();
    pass.dispatchWorkgroups(
        (size.width - 1) / 8 + 1,
        (size.height - 1) / 8 + 1,
        1,
    );
    pass.end();
    ren.post.flip();

    mach.queue.submit(&.{encoder.finish(null)});
}
