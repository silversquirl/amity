const std = @import("std");
const flecs = @import("flecs");
const mach = @import("mach-core");
const math = @import("zmath");

const gpu = mach.gpu;
const log = std.log.scoped(.amity_render);

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

// TODO: use camera component
mvp: math.Mat,

// Texture format used for HDR color buffers within the render pipeline
const render_format: gpu.Texture.Format = .rgba16_float;

const black: gpu.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

// TODO: use ECS relationships to avoid duplicating materials for each mesh
pub const OpaqueMaterial = struct {
    _: i32 = undefined,

    fn toGpu(mat: OpaqueMaterial) Gpu {
        _ = mat;
        return .{};
    }

    const Gpu = extern struct {
        _: i32 = undefined,
    };
};

pub const Geometry = struct {
    index_count: u32,
    index_buffer: *gpu.Buffer,
    vertex_count: u32,
    pos_buffer: *gpu.Buffer,
    normal_buffer: *gpu.Buffer,

    pub fn init(indices: []const u32, positions: []const [3]f32, normals: []const [3]f32) Geometry {
        std.debug.assert(positions.len == normals.len);

        const index_buffer = mach.device.createBuffer(&.{
            .usage = .{ .index = true },
            .size = indices.len * @sizeOf(u32),
            .mapped_at_creation = .true,
        });
        {
            const indices_gpu = index_buffer.getMappedRange(u32, 0, indices.len).?;
            defer index_buffer.unmap();
            @memcpy(indices_gpu, indices);
        }

        const pos_buffer = mach.device.createBuffer(&.{
            .usage = .{ .vertex = true },
            .size = positions.len * 3 * @sizeOf(f32),
            .mapped_at_creation = .true,
        });
        {
            const positions_gpu = pos_buffer.getMappedRange([3]f32, 0, positions.len).?;
            defer pos_buffer.unmap();
            @memcpy(positions_gpu, positions);
        }

        const normal_buffer = mach.device.createBuffer(&.{
            .usage = .{ .vertex = true },
            .size = positions.len * 3 * @sizeOf(f32),
            .mapped_at_creation = .true,
        });
        {
            const normals_gpu = normal_buffer.getMappedRange([3]f32, 0, positions.len).?;
            defer normal_buffer.unmap();
            @memcpy(normals_gpu, normals);
        }

        return .{
            .index_count = @intCast(indices.len),
            .index_buffer = index_buffer,
            .vertex_count = @intCast(positions.len),
            .pos_buffer = pos_buffer,
            .normal_buffer = normal_buffer,
        };
    }
};

const GBuffer = struct {
    depth: *gpu.TextureView,
    // Normal in RGB, material ID in alpha
    normal_material: *gpu.TextureView,
    bind: *gpu.BindGroup,

    const targets: []const gpu.ColorTargetState = &.{
        // 0: normal & material
        .{ .format = .rgba32_uint },
    };

    fn init() struct { GBuffer, *gpu.BindGroupLayout } {
        const depth = createSwapchainTexture(.depth24_plus, .{
            .render_attachment = true,
        });
        const normal_material = createSwapchainTexture(.rgba32_uint, .{
            .render_attachment = true,
            .texture_binding = true,
        });

        const bind_layout = mach.device.createBindGroupLayout(&gpu.BindGroupLayout.Descriptor.init(.{
            .entries = &.{
                .{
                    .binding = 0,
                    .visibility = .{ .fragment = true },
                    .texture = .{ .sample_type = .uint },
                },
            },
        }));
        const bind = mach.device.createBindGroup(&gpu.BindGroup.Descriptor.init(.{
            .layout = bind_layout,
            .entries = &.{
                .{ .binding = 0, .texture_view = normal_material, .size = 0 },
            },
        }));

        return .{
            .{
                .depth = depth,
                .normal_material = normal_material,
                .bind = bind,
            },
            bind_layout,
        };
    }

    fn deinit(buf: GBuffer) void {
        buf.depth.release();
        buf.normal_material.release();
        buf.bind.release();
    }
};

const GeometryUniforms = extern struct {
    material_idx: u32,
    transform: [4][4]f32 align(16),
};

const DoubleBuffer = struct {
    attach: [2]gpu.RenderPassColorAttachment,
    bind: [2]*gpu.BindGroup,
    idx: u1 = 0,

    fn init() struct { DoubleBuffer, *gpu.BindGroupLayout } {
        const bind_layout = mach.device.createBindGroupLayout(&gpu.BindGroupLayout.Descriptor.init(.{
            .entries = &.{
                .{
                    .binding = 0,
                    .visibility = .{ .fragment = true },
                    .texture = .{ .sample_type = .float },
                },
            },
        }));

        var attach: [2]gpu.RenderPassColorAttachment = undefined;
        var bind: [2]*gpu.BindGroup = undefined;
        for (&attach, &bind) |*a, *b| {
            const tex = createSwapchainTexture(render_format, .{
                .render_attachment = true,
                .texture_binding = true,
            });

            a.* = .{
                .view = tex,
                .clear_value = black,
                .load_op = .clear,
                .store_op = .store,
            };

            b.* = mach.device.createBindGroup(&gpu.BindGroup.Descriptor.init(.{
                .layout = bind_layout,
                .entries = &.{
                    .{ .binding = 0, .texture_view = tex, .size = 0 },
                },
            }));
        }

        return .{ .{ .attach = attach, .bind = bind }, bind_layout };
    }

    fn deinit(buf: DoubleBuffer) void {
        for (buf.attach, buf.bind) |a, b| {
            a.view.?.release();
            b.release();
        }
    }

    fn flip(buf: *DoubleBuffer) void {
        buf.idx = 1 - buf.idx;
    }
    fn targetAttach(buf: DoubleBuffer) gpu.RenderPassColorAttachment {
        return buf.attach[buf.idx];
    }
    fn sourceBind(buf: DoubleBuffer) *gpu.BindGroup {
        return buf.bind[1 - buf.idx];
    }
};

pub const MaterialStore = struct {
    items: std.ArrayListUnmanaged(OpaqueMaterial.Gpu) = .{},
    buf: ?*gpu.Buffer = null,
    buf_capacity: usize = 0,
    bind_layout: *gpu.BindGroupLayout,

    pub fn init() MaterialStore {
        return .{
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
                .usage = .{
                    .copy_dst = true,
                    .storage = true,
                },
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
    const g_buffer, const g_buffer_layout = GBuffer.init();
    errdefer g_buffer.deinit();
    defer g_buffer_layout.release();

    var material_store = MaterialStore.init();
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
                        .{ .format = .float32x3, .offset = 0, .shader_location = 1 },
                    },
                }),
            },
        }),

        .depth_stencil = &.{
            .format = .depth24_plus,
            .depth_write_enabled = .true,
        },

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
        .bind_group_layouts = &.{ g_buffer_layout, material_store.bind_layout },
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

    const post, const post_bind_layout = DoubleBuffer.init();
    errdefer post.deinit();
    defer post_bind_layout.release();

    const color_correct_shader = mach.device.createShaderModuleWGSL("color_correct.wgsl", @embedFile("shader/color_correct.wgsl"));
    defer color_correct_shader.release();

    const color_correct_layout = mach.device.createPipelineLayout(&gpu.PipelineLayout.Descriptor.init(.{
        .bind_group_layouts = &.{post_bind_layout},
    }));
    defer color_correct_layout.release();

    const color_correct_pipe = mach.device.createRenderPipeline(&.{
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
    errdefer color_correct_pipe.release();

    const mvp = a: {
        const view = math.lookAtRh(
            math.f32x4(0.5, 0.5, 0.5, 1),
            math.f32x4(0, 0, 0, 1),
            math.f32x4(0, 1, 0, 0),
        );
        const size = mach.size();
        const width: f32 = @floatFromInt(size.width);
        const height: f32 = @floatFromInt(size.height);
        const proj = math.perspectiveFovRh(std.math.tau / 8.0, width / height, 0.1, 100);
        break :a math.mul(view, proj);
    };

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

        .mvp = mvp,
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

    log.debug("init", .{});
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

    // TODO: use events to update material store rather than re-uploading every time
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
            .transform = ren.mvp,
        }});

        const encoder = mach.device.createCommandEncoder(null);
        defer encoder.release();

        const pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
            .color_attachments = &.{.{
                .view = ren.g_buffer.normal_material,
                .clear_value = black,
                .load_op = if (i == 0) .clear else .load,
                .store_op = .store,
            }},
            .depth_stencil_attachment = &.{
                .view = ren.g_buffer.depth,
                .depth_load_op = if (i == 0) .clear else .load,
                .depth_store_op = .store,
            },
        }));
        defer pass.release();

        pass.setPipeline(ren.geom_pipe);
        pass.setBindGroup(0, ren.geom_uniform_bind, &.{});
        pass.setIndexBuffer(g.index_buffer, .uint32, 0, g.index_count * @sizeOf(u32));
        pass.setVertexBuffer(0, g.pos_buffer, 0, g.vertex_count * 3 * @sizeOf(f32));
        pass.setVertexBuffer(1, g.normal_buffer, 0, g.vertex_count * 3 * @sizeOf(f32));
        pass.drawIndexed(g.index_count, 1, 0, 0, 0);
        pass.end();

        mach.queue.submit(&.{encoder.finish(null)});
    }

    // Shade drawn geometry
    {
        const encoder = mach.device.createCommandEncoder(null);
        defer encoder.release();

        const pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
            .color_attachments = &.{
                ren.post.targetAttach(),
            },
        }));
        defer pass.release();
        ren.post.flip();

        const bind = ren.material_store.bindGroup();
        defer bind.release();

        pass.setPipeline(ren.shade_pipe);
        pass.setBindGroup(0, ren.g_buffer.bind, null);
        pass.setBindGroup(1, bind, null);
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
                .clear_value = black,
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
