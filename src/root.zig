const std = @import("std");
const flecs = @import("flecs");
const mach = @import("mach-core");
const math = @import("zmath");
const c = @cImport({
    @cInclude("assimp/cimport.h");
    @cInclude("assimp/scene.h");
    @cInclude("assimp/postprocess.h");
});

const Camera = @import("Camera.zig");
const Renderer = @import("Renderer.zig");

pub const Engine = struct {
    world: *flecs.world_t,

    pub const InitOptions = packed struct {
        renderer: bool = true,
    };

    pub fn init(opts: InitOptions) !Engine {
        const world = flecs.init();
        errdefer _ = flecs.fini(world);

        flecs.COMPONENT(world, Camera);

        if (opts.renderer) {
            try Renderer.init(world);
        }

        try loadScene(world, "../../assets/cube.obj");

        // Add sun
        // TODO: light importing
        {
            const sun = flecs.new_entity(world, "Sun");
            _ = flecs.set(world, sun, Renderer.light.Directional, .{
                .color = .{ 255, 255, 255 },
                .dir = math.normalize3(math.f32x4(-1.0, -2.0, -1.0, 0.0)),
            });
        }

        // Add camera
        {
            const cam = flecs.new_entity(world, "Camera");
            _ = flecs.set(world, cam, Camera, .{
                .pos = .{ 0.5, 0.5, 0.5 },
            });
        }

        // Spin camera
        {
            var desc: flecs.system_desc_t = .{ .callback = spinCamera };
            desc.query.filter.terms[0] = .{ .id = flecs.id(Camera) };

            flecs.SYSTEM(world, "amity/camera", flecs.OnUpdate, &desc);
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
        var corrected_dt = dt;
        if (dt == 0) {
            std.log.debug("zero dt, correcting to small value", .{});
            corrected_dt = std.math.floatEps(f32);
        }
        return !flecs.progress(eng.world, dt);
    }
};

fn spinCamera(it: *flecs.iter_t) callconv(.C) void {
    const dt = it.delta_time;
    const q = math.quatFromNormAxisAngle(math.f32x4(0, 1, 0, 0), dt * std.math.tau / 8);
    for (flecs.field(it, Camera, 1).?, it.entities()) |cam, e| {
        var new = cam;
        math.storeArr3(&new.pos, math.rotate(q, math.loadArr3(cam.pos)));
        _ = flecs.set(it.world, e, Camera, new);
    }
}

fn loadScene(world: *flecs.world_t, path: [:0]const u8) !void {
    const scene = c.aiImportFile(
        path,
        c.aiProcess_Triangulate |
            c.aiProcess_JoinIdenticalVertices |
            c.aiProcess_PreTransformVertices |
            c.aiProcess_ImproveCacheLocality |
            c.aiProcess_RemoveRedundantMaterials |
            c.aiProcess_OptimizeMeshes |
            c.aiProcess_SortByPType,
    ) orelse {
        const msg = c.aiGetErrorString();
        std.log.err("Failed to load scene: {s}: {s}", .{ path, std.mem.span(msg) });
        return error.MeshLoadFailed;
    };
    defer c.aiReleaseImport(scene);

    const materials = try mach.allocator.alloc(Renderer.OpaqueMaterial, scene.*.mNumMaterials);
    defer mach.allocator.free(materials);
    for (materials, scene.*.mMaterials) |*mat, ai_mat| {
        mat.color = a: {
            var color: c.aiColor4D = undefined;
            if (c.aiGetMaterialColor(ai_mat, "$clr.base", 0, 0, &color) != c.aiReturn_SUCCESS) {
                if (c.aiGetMaterialColor(ai_mat, "$clr.diffuse", 0, 0, &color) != c.aiReturn_SUCCESS) {
                    std.log.warn("{s}: Missing base/diffuse color, defaulting to white", .{path});
                    break :a .{ 0xff, 0xff, 0xff };
                } else {
                    std.log.info("{s}: Missing base color, using diffuse instead", .{path});
                }
            }
            break :a .{
                @intFromFloat(color.r * 0xff),
                @intFromFloat(color.g * 0xff),
                @intFromFloat(color.b * 0xff),
            };
        };

        if (c.aiGetMaterialFloat(ai_mat, "$mat.metallicFactor", 0, 0, &mat.metallic) != c.aiReturn_SUCCESS) {
            std.log.warn("{s}: Missing metallic factor, defaulting to 0", .{path});
            mat.metallic = 0;
        }
        if (c.aiGetMaterialFloat(ai_mat, "$mat.roughnessFactor", 0, 0, &mat.roughness) != c.aiReturn_SUCCESS) {
            std.log.warn("{s}: Missing roughness factor, defaulting to 0", .{path});
            mat.roughness = 0;
        }
        if (c.aiGetMaterialFloat(ai_mat, "$mat.refracti", 0, 0, &mat.ior) != c.aiReturn_SUCCESS) {
            std.log.warn("{s}: Missing IOR, defaulting to 1", .{path});
            mat.ior = 1;
        }
    }

    var indices = std.ArrayList(u32).init(mach.allocator);
    defer indices.deinit();
    var name_buf = std.ArrayList(u8).init(mach.allocator);
    defer name_buf.deinit();
    for (scene.*.mMeshes[0..scene.*.mNumMeshes], 0..) |mesh, mesh_index| {
        indices.clearRetainingCapacity();
        for (mesh.*.mFaces[0..mesh.*.mNumFaces]) |face| {
            std.debug.assert(face.mNumIndices == 3); // We triangulated already so this should be true
            for (face.mIndices[0..face.mNumIndices]) |index| {
                try indices.append(index);
            }
        }

        const normals: [][3]f32 = @ptrCast(mesh.*.mNormals[0..mesh.*.mNumVertices]);
        const vertices: [][3]f32 = @ptrCast(mesh.*.mVertices[0..mesh.*.mNumVertices]);

        name_buf.clearRetainingCapacity();
        try name_buf.appendSlice("mesh");
        if (mesh.*.mName.length > 0) {
            const name = mesh.*.mName;
            try name_buf.writer().print(": {s}", .{
                name.data[0..name.length],
            });
        } else {
            try name_buf.writer().print(" #{}", .{mesh_index});
        }
        try name_buf.append(0);

        const entity = flecs.new_entity(world, name_buf.items[0 .. name_buf.items.len - 1 :0]);
        _ = flecs.set(world, entity, Renderer.Geometry, Renderer.Geometry.init(indices.items, vertices, normals));
        _ = flecs.set(world, entity, Renderer.OpaqueMaterial, materials[mesh.*.mMaterialIndex]);
    }
}
