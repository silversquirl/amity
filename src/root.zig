const std = @import("std");
const ecs = @import("mach").ecs;
const mach = @import("mach").core;
const math = @import("zmath");
const c = @cImport({
    @cInclude("assimp/cimport.h");
    @cInclude("assimp/scene.h");
    @cInclude("assimp/postprocess.h");
});

pub const Renderer = @import("Renderer.zig");

// TODO: config
pub const World = ecs.World(.{
    Engine,
    Renderer,
});

pub const Engine = struct {
    pub const name = .amity_engine;
    pub const components = struct {};
    pub const Mod = World.Mod(Engine);

    pub fn init(mod: *Mod, ren: *Renderer.Mod) !void {
        try loadScene(ren, "../../assets/cube.obj");

        // Add sun
        // TODO: light importing
        {
            const sun = try mod.newEntity();
            try ren.set(sun, .light_directional, .{
                .color = .{ 255, 255, 255 },
                .dir = math.normalize3(math.f32x4(-1.0, -2.0, -1.0, 0.0)),
            });
        }

        // Add random lights
        var rand = std.rand.DefaultPrng.init(0);
        const rng = rand.random();
        for (0..100) |_| {
            const light = try mod.newEntity();
            try ren.set(light, .light_directional, .{
                .color = .{ 10, 10, 10 },
                .dir = math.normalize3(math.f32x4(
                    rng.floatNorm(f32),
                    rng.floatNorm(f32),
                    rng.floatNorm(f32),
                    0.0,
                )),
            });
        }

        // Add camera
        {
            const cam = try mod.newEntity();
            try ren.set(cam, .camera, .{
                .pos = .{ 0.5, 0.5, 0.5 },
            });
            try ren.set(cam, .dirty, {});
        }
    }

    pub fn tick(mod: *Mod, ren: *Renderer.Mod, dt: f32) !void {
        // Spin camera
        const q = math.quatFromNormAxisAngle(math.f32x4(0, 1, 0, 0), dt * std.math.tau / 16);
        var it = mod.entities.query(.{ .all = &.{
            .{ .amity_renderer = &.{.camera} },
        } });
        while (it.next()) |arche| {
            for (arche.slice(.entity, .id), arche.slice(.amity_renderer, .camera)) |id, cam| {
                var new = cam;
                math.storeArr3(&new.pos, math.rotate(q, math.loadArr3(cam.pos)));
                try ren.set(id, .camera, new);
                try ren.set(id, .dirty, {});
            }
        }
    }
};

fn loadScene(ren: *Renderer.Mod, path: [:0]const u8) !void {
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

    const materials = try mach.allocator.alloc(Renderer.Opaques.Material, scene.*.mNumMaterials);
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
    for (scene.*.mMeshes[0..scene.*.mNumMeshes]) |mesh| {
        indices.clearRetainingCapacity();
        for (mesh.*.mFaces[0..mesh.*.mNumFaces]) |face| {
            std.debug.assert(face.mNumIndices == 3); // We triangulated already so this should be true
            for (face.mIndices[0..face.mNumIndices]) |index| {
                try indices.append(index);
            }
        }

        const normals: [][3]f32 = @ptrCast(mesh.*.mNormals[0..mesh.*.mNumVertices]);
        const vertices: [][3]f32 = @ptrCast(mesh.*.mVertices[0..mesh.*.mNumVertices]);

        const entity = try ren.newEntity();
        try ren.set(entity, .geometry, Renderer.Geometry.init(indices.items, vertices, normals));
        try ren.set(entity, .opaque_material, materials[mesh.*.mMaterialIndex]);
    }
}
