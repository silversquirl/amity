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

g_buffer: GBuffer,
material_store: MaterialStore,
geom_pipe: *gpu.RenderPipeline,
geom_uniform_buf: *gpu.Buffer,
geom_uniform_bind: *gpu.BindGroup,
shade_pipe: *gpu.RenderPipeline,

post: DoubleBuffer,
color_correct_pipe: *gpu.RenderPipeline,

// Texture format used for HDR color buffers within the render pipeline
const render_format: gpu.Texture.Format = .rgba16_float;

pub const OpaqueMaterial = struct {
    _: i32 = undefined,

    fn toGpu(mat: OpaqueMaterial) Gpu {
        _ = mat;
        return .{};
    }

    const Gpu = struct {
        _: i32 = undefined,
    };
};
pub const Geometry = struct {
    vertex_count: u32,
    pos_buffer: *gpu.Buffer,
    normal_buffer: *gpu.Buffer,
};
const vec32_align = 4 * @sizeOf(f32);

const GBuffer = struct {
    depth: *gpu.TextureView,
    // Normal in RGB, material ID in alpha
    normal_material: *gpu.TextureView,

    const targets: []const gpu.ColorTargetState = &.{
        // 0: normal & material
        .{ .format = .rgba32_uint },
    };
};

const GeometryUniforms = struct {
    material_idx: u32,
};

const DoubleBuffer = struct {
    buf: [2]gpu.RenderPassColorAttachment,
    idx: u1 = 0,

    fn init() DoubleBuffer {
        var buf: [2]gpu.RenderPassColorAttachment = undefined;
        for (&buf) |*a| {
            a.* = .{
                .view = createSwapchainTexture(render_format, .{
                    .render_attachment = true,
                    .texture_binding = true,
                }),
                .clear_value = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 },
                .load_op = .clear,
                .store_op = .store,
            };
        }
        return .{ .buf = buf };
    }
    fn deinit(post: DoubleBuffer) void {
        for (post.buf) |a| {
            a.view.?.release();
        }
    }

    fn flip(post: *DoubleBuffer) void {
        post.idx = 1 - post.idx;
    }
    fn target(post: DoubleBuffer) gpu.RenderPassColorAttachment {
        return post.buf[post.idx];
    }
    fn source(post: DoubleBuffer) gpu.RenderPassColorAttachment {
        return post.buf[1 - post.idx];
    }
};

pub const MaterialStore = struct {
    items: std.ArrayListUnmanaged(OpaqueMaterial.Gpu) = .{},
    usage: gpu.Buffer.UsageFlags,
    buf: ?*gpu.Buffer = null,
    buf_capacity: usize = 0,
    bind_layout: *gpu.BindGroupLayout,

    pub fn init(usage: gpu.Buffer.UsageFlags) MaterialStore {
        return .{
            .usage = usage,
            .bind_layout = mach.device.createBindGroupLayout(&gpu.BindGroupLayout.Descriptor.init(.{
                .entries = &.{
                    .{
                        .binding = 0,
                        .visibility = .{ .fragment = true },
                        .buffer = .{
                            .type = .storage,
                            .min_binding_size = 0,
                        },
                    },
                },
            })),
        };
    }

    pub fn deinit(store: *MaterialStore) void {
        store.items.deinit(mach.allocator);
        store.bind_layout.release();
        if (store.buf_capacity > 0) {
            store.buf.?.release();
        }
    }

    pub fn upload(store: *MaterialStore) void {
        if (store.buf_capacity != store.items.capacity) {
            if (store.buf_capacity > 0) {
                store.buf.?.release();
            }
            if (store.items.capacity == 0) {
                store.buf = null;
                return;
            }

            store.buf = mach.device.createBuffer(&.{
                .size = store.items.capacity * @sizeOf(OpaqueMaterial.Gpu),
                .usage = store.usage,
            });
        }

        // TODO: partial updates
        mach.queue.writeBuffer(store.buf.?, 0, store.items.items);
    }

    pub fn bindGroup(store: MaterialStore) *gpu.BindGroup {
        // TODO: caching
        return mach.device.createBindGroup(&gpu.BindGroup.Descriptor.init(.{
            .layout = store.bind_layout,
            .entries = &.{
                .{ .binding = 0, .buffer = store.buf.?, .size = store.items.items.len * @sizeOf(OpaqueMaterial.Gpu) },
            },
        }));
    }

    pub fn clearRetainingCapacity(store: *MaterialStore) void {
        store.items.clearRetainingCapacity();
    }
    pub fn append(store: *MaterialStore, item: OpaqueMaterial.Gpu) !void {
        try store.items.append(mach.allocator, item);
    }
};

pub fn init(world: *flecs.world_t) !void {
    const g_buffer: GBuffer = .{
        .depth = createSwapchainTexture(.depth24_plus, .{
            .render_attachment = true,
        }),
        .normal_material = createSwapchainTexture(.rgba32_uint, .{
            .render_attachment = true,
            .texture_binding = true,
        }),
    };
    errdefer {
        g_buffer.depth.release();
        g_buffer.normal_material.release();
    }

    var material_store = MaterialStore.init(.{
        .copy_dst = true,
        .uniform = true,
    });
    errdefer material_store.deinit();

    const deferred_shader = mach.device.createShaderModuleWGSL("deferred.wgsl", @embedFile("shader/deferred.wgsl"));
    defer deferred_shader.release();

    const geom_uniform_layout = mach.device.createBindGroupLayout(&gpu.BindGroupLayout.Descriptor.init(.{
        .entries = &.{
            .{
                .binding = 0,
                .visibility = .{
                    .vertex = true,
                    .fragment = true,
                },
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
            },
        }),

        .fragment = &gpu.FragmentState.init(.{
            .module = deferred_shader,
            .entry_point = "fragment",
            .targets = GBuffer.targets,
        }),
    });
    errdefer geom_pipe.release();

    const geom_uniform_buf = mach.device.createBuffer(&.{
        .size = @sizeOf(GeometryUniforms),
        .usage = .{ .copy_dst = true, .uniform = true },
    });
    const geom_uniform_bind = mach.device.createBindGroup(&gpu.BindGroup.Descriptor.init(.{
        .layout = geom_pipe.getBindGroupLayout(0),
        .entries = &.{
            .{ .binding = 0, .buffer = geom_uniform_buf, .size = @sizeOf(GeometryUniforms) },
        },
    }));

    const fullscreen_shader = mach.device.createShaderModuleWGSL("fullscreen.wgsl", @embedFile("shader/fullscreen.wgsl"));
    defer fullscreen_shader.release();

    const shade_layout = mach.device.createPipelineLayout(&gpu.PipelineLayout.Descriptor.init(.{
        .bind_group_layouts = &.{material_store.bind_layout},
    }));
    defer shade_layout.release();
    const shade_pipe = mach.device.createRenderPipeline(&.{
        .layout = shade_layout,

        .vertex = gpu.VertexState.init(.{
            .module = fullscreen_shader,
            .entry_point = "vertex",
        }),

        .fragment = &gpu.FragmentState.init(.{
            .module = deferred_shader,
            .entry_point = "render",
            .targets = &.{
                .{ .format = render_format },
            },
        }),
    });
    errdefer shade_pipe.release();

    const post = DoubleBuffer.init();
    errdefer post.deinit();

    const color_correct_shader = mach.device.createShaderModuleWGSL("color_correct.wgsl", @embedFile("shader/color_correct.wgsl"));
    defer color_correct_shader.release();

    const color_correct_pipe = mach.device.createRenderPipeline(&.{
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
    errdefer color_correct_pipe.release();

    const ren = try mach.allocator.create(Renderer);
    ren.* = .{
        .phase = flecs.new_w_id(world, flecs.Phase),

        .g_buffer = g_buffer,
        .material_store = material_store,
        .geom_pipe = geom_pipe,
        .geom_uniform_buf = geom_uniform_buf,
        .geom_uniform_bind = geom_uniform_bind,
        .shade_pipe = shade_pipe,

        .post = post,
        .color_correct_pipe = color_correct_pipe,
    };
    errdefer deinit(ren);

    flecs.COMPONENT(world, OpaqueMaterial);
    flecs.COMPONENT(world, Geometry);

    // TODO: enforce strict ordering
    {
        var desc: flecs.system_desc_t = .{
            .callback = opaqueGeometry,
            .ctx = ren,
        };
        desc.query.filter.terms[0] = .{ .id = flecs.id(OpaqueMaterial) };
        desc.query.filter.terms[1] = .{ .id = flecs.id(Geometry) };

        flecs.SYSTEM(world, "amity/render/deferred/opaque", ren.phase, &desc);
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

    ren.g_buffer.depth.release();
    ren.g_buffer.normal_material.release();
    ren.material_store.deinit();

    ren.geom_pipe.release();
    ren.shade_pipe.release();

    ren.post.deinit();
    ren.color_correct_pipe.release();

    mach.allocator.destroy(ren);
}

/// Create a texture the same size as the swapchain
fn createSwapchainTexture(format: gpu.Texture.Format, usage: gpu.Texture.UsageFlags) *gpu.TextureView {
    const size = mach.size();
    const tex = mach.device.createTexture(&.{
        .usage = usage,
        .size = .{
            .width = size.width,
            .height = size.height,
            .depth_or_array_layers = 1,
        },
        .format = format,
    });
    defer tex.release();
    return tex.createView(null);
}

//// Rendering phases ////

fn opaqueGeometry(it: *flecs.iter_t) callconv(.C) void {
    const ren: *Renderer = @ptrCast(@alignCast(it.param.?));

    const mat = flecs.field(it, OpaqueMaterial, 1).?;
    const geom = flecs.field(it, Geometry, 2).?;

    // TODO: cache material data
    ren.material_store.clearRetainingCapacity();
    for (mat) |m| {
        ren.material_store.append(m.toGpu()) catch @panic("OOM");
    }
    ren.material_store.upload();

    // Draw to g-buffer
    // TODO: batching
    for (geom, 0..) |g, i| {
        // TODO: cache uniform data
        mach.queue.writeBuffer(ren.geom_uniform_buf, 0, &[_]GeometryUniforms{.{
            .material_idx = @intCast(i),
        }});

        const encoder = mach.device.createCommandEncoder(null);
        defer encoder.release();

        const pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
            .color_attachments = &.{.{
                .view = ren.g_buffer.normal_material,
                .clear_value = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
                .load_op = .clear,
                .store_op = .store,
            }},
            .depth_stencil_attachment = &.{
                .view = ren.g_buffer.depth,
            },
        }));
        defer pass.release();

        pass.setPipeline(ren.geom_pipe);
        pass.setBindGroup(0, ren.geom_uniform_bind, &.{});
        pass.setVertexBuffer(0, g.pos_buffer, 0, g.vertex_count * 3 * @sizeOf(f32));
        pass.setVertexBuffer(1, g.normal_buffer, 0, g.vertex_count * 3 * @sizeOf(f32));
        pass.draw(g.vertex_count, 1, 0, 0);
        pass.end();

        mach.queue.submit(&.{encoder.finish(null)});
    }

    // Shade drawn geometry
    {
        const encoder = mach.device.createCommandEncoder(null);
        defer encoder.release();

        const pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
            .color_attachments = &.{
                ren.post.target(),
            },
        }));
        defer pass.release();
        ren.post.flip();

        const bind = ren.material_store.bindGroup();
        defer bind.release();

        pass.setPipeline(ren.shade_pipe);
        pass.setBindGroup(0, bind, &.{});
        pass.draw(3, 1, 0, 0);
        pass.end();

        mach.queue.submit(&.{encoder.finish(null)});
    }
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
                .clear_value = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 },
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
