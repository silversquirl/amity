const std = @import("std");
const mach = @import("mach").core;
const math = @import("zmath");
const gpu = mach.gpu;

// Texture format used for HDR color buffers within the render pipeline
pub const render_format: gpu.Texture.Format = .rgba16_float;

pub const black: gpu.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

pub const Transforms = extern struct {
    view: [4][4]f32 align(16),
    vp: [4][4]f32 align(16),
    inv_vp: [4][4]f32 align(16),

    pub fn bindEntry(binding: u32) gpu.BindGroupLayout.Entry {
        return .{
            .binding = binding,
            .visibility = .{ .vertex = true },
            .buffer = .{
                .type = .uniform,
                .min_binding_size = @sizeOf(Transforms),
            },
        };
    }
};

pub fn packColor(color: [3]u8) u32 {
    var out: u32 = 0;
    var i: u5 = 0;
    while (i < color.len) : (i += 1) {
        const c: u32 = color[i];
        out |= c << 8 * (2 - i);
    }
    return out;
}

pub const InitData = struct {
    g_buffer_layout: *gpu.BindGroupLayout,
    post_bind_layout: *gpu.BindGroupLayout,
    post_storage_bind_layout: *gpu.BindGroupLayout,
};

/// Create a texture the same size as the swapchain
pub fn createSwapchainTexture(format: gpu.Texture.Format, usage: gpu.Texture.UsageFlags) *gpu.TextureView {
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

pub const light = struct {
    pub const Directional = struct {
        color: [3]u8,
        dir: math.Vec,

        fn toGpu(l: Directional) Gpu {
            return .{
                .color = packColor(l.color),
                .dir = math.vecToArr3(l.dir),
            };
        }

        const Gpu = extern struct {
            color: u32,
            dir: [3]f32 align(16),
        };
    };
};

pub const GBuffer = struct {
    depth: *gpu.TextureView,
    // Normal in RGB, material ID in alpha
    normal_material: *gpu.TextureView,
    bind: *gpu.BindGroup,

    pub const targets: []const gpu.ColorTargetState = &.{
        // 0: normal & material
        .{ .format = .rgba32_uint },
    };

    pub fn init() struct { GBuffer, *gpu.BindGroupLayout } {
        const depth = createSwapchainTexture(.depth24_plus, .{
            .render_attachment = true,
            .texture_binding = true,
        });
        const normal_material = createSwapchainTexture(.rgba32_uint, .{
            .render_attachment = true,
            .texture_binding = true,
        });

        const bind_layout = mach.device.createBindGroupLayout(&gpu.BindGroupLayout.Descriptor.init(.{
            .entries = &.{
                .{
                    .binding = 0,
                    .visibility = .{ .fragment = true, .compute = true },
                    .texture = .{ .sample_type = .depth },
                },
                .{
                    .binding = 1,
                    .visibility = .{ .fragment = true, .compute = true },
                    .texture = .{ .sample_type = .uint },
                },
            },
        }));
        const bind = mach.device.createBindGroup(&gpu.BindGroup.Descriptor.init(.{
            .layout = bind_layout,
            .entries = &.{
                .{ .binding = 0, .texture_view = depth, .size = 0 },
                .{ .binding = 1, .texture_view = normal_material, .size = 0 },
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

    pub fn deinit(buf: GBuffer) void {
        buf.depth.release();
        buf.normal_material.release();
        buf.bind.release();
    }
};

pub const DoubleBuffer = struct {
    attach: [2]gpu.RenderPassColorAttachment,
    bind: [2]*gpu.BindGroup,
    storage_bind: [2]*gpu.BindGroup,
    idx: u1 = 0,

    pub fn init() struct { DoubleBuffer, *gpu.BindGroupLayout, *gpu.BindGroupLayout } {
        const bind_layout = mach.device.createBindGroupLayout(&gpu.BindGroupLayout.Descriptor.init(.{
            .entries = &.{
                .{
                    .binding = 0,
                    .visibility = .{ .fragment = true, .compute = true },
                    .texture = .{ .sample_type = .float },
                },
            },
        }));

        const storage_bind_layout = mach.device.createBindGroupLayout(&gpu.BindGroupLayout.Descriptor.init(.{
            .entries = &.{
                .{
                    .binding = 0,
                    .visibility = .{ .compute = true },
                    .storage_texture = .{
                        .access = .write_only,
                        .format = render_format,
                        .view_dimension = .dimension_2d,
                    },
                },
            },
        }));

        var attach: [2]gpu.RenderPassColorAttachment = undefined;
        var bind: [2]*gpu.BindGroup = undefined;
        var storage_bind: [2]*gpu.BindGroup = undefined;
        for (&attach, &bind, &storage_bind) |*a, *b, *sb| {
            const tex = createSwapchainTexture(render_format, .{
                .render_attachment = true,
                .texture_binding = true,
                .storage_binding = true,
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

            sb.* = mach.device.createBindGroup(&gpu.BindGroup.Descriptor.init(.{
                .layout = storage_bind_layout,
                .entries = &.{
                    .{ .binding = 0, .texture_view = tex, .size = 0 },
                },
            }));
        }

        return .{
            .{ .attach = attach, .bind = bind, .storage_bind = storage_bind },
            bind_layout,
            storage_bind_layout,
        };
    }

    pub fn deinit(buf: DoubleBuffer) void {
        for (buf.attach, buf.bind) |a, b| {
            a.view.?.release();
            b.release();
        }
    }

    pub fn flip(buf: *DoubleBuffer) void {
        buf.idx = 1 - buf.idx;
    }
    pub fn targetAttach(buf: DoubleBuffer) gpu.RenderPassColorAttachment {
        return buf.attach[buf.idx];
    }
    pub fn targetBind(buf: DoubleBuffer) *gpu.BindGroup {
        return buf.storage_bind[buf.idx];
    }
    pub fn sourceBind(buf: DoubleBuffer) *gpu.BindGroup {
        return buf.bind[1 - buf.idx];
    }
};

pub fn UploadBuffer(comptime T: type, comptime usage_: gpu.Buffer.UsageFlags) type {
    comptime var usage = usage_;
    // Required for uploading
    usage.copy_dst = true;

    return struct {
        items: std.ArrayListUnmanaged(T) = .{},
        buf: ?*gpu.Buffer = null,
        buf_capacity: usize = 0,

        const Self = @This();

        pub fn deinit(buf: *Self) void {
            buf.items.deinit(mach.allocator);
            if (buf.buf) |b| {
                b.release();
            }
        }

        pub fn upload(buf: *Self) void {
            if (buf.buf_capacity != buf.items.capacity) {
                if (buf.buf) |b| {
                    b.release();
                }
                if (buf.items.capacity == 0) {
                    buf.buf = null;
                    return;
                }
                buf.buf = mach.device.createBuffer(&.{
                    .size = buf.items.capacity * @sizeOf(T),
                    .usage = usage,
                });
            }

            if (buf.buf) |b| {
                // TODO: partial updates
                mach.queue.writeBuffer(b, 0, buf.items.items);
            }
        }

        pub fn clearRetainingCapacity(buf: *Self) void {
            buf.items.clearRetainingCapacity();
        }
        pub fn append(buf: *Self, item: T) !void {
            try buf.items.append(mach.allocator, item);
        }
        pub fn len(buf: Self) u32 {
            return @intCast(buf.items.items.len);
        }
        pub fn byteSize(buf: Self) usize {
            return buf.len() * @sizeOf(T);
        }

        pub fn bindGroupEntry(buf: *Self, binding: u32) gpu.BindGroup.Entry {
            return .{ .binding = binding, .buffer = buf.buf.?, .size = buf.byteSize() };
        }
    };
}

pub const LightStore = struct {
    dir: UploadBuffer(light.Directional.Gpu, .{ .storage = true, .vertex = true }) = .{},

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

    pub fn deinit(store: *LightStore) void {
        store.dir.deinit();
    }

    pub fn upload(store: *LightStore) !void {
        // WebGPU requires buffer bindings be non-empty, which requires a dummy value for empty buffers.
        // For simplicity, we add one to the end of all buffers, not just empty ones.
        try store.dir.append(undefined);

        store.dir.upload();
    }

    pub fn clear(store: *LightStore) void {
        store.dir.clearRetainingCapacity();
    }
    pub fn append(store: *LightStore, l: anytype) !void {
        switch (@TypeOf(l)) {
            light.Directional => try store.dir.append(l.toGpu()),
            else => @compileError("invalid light type " ++ @typeName(@TypeOf(l))),
        }
    }
};
