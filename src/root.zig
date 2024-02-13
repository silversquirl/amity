const std = @import("std");
const flecs = @import("flecs");
const mach = @import("mach-core");
const c = @cImport({
    @cInclude("assimp/cimport.h");
    @cInclude("assimp/scene.h");
    @cInclude("assimp/postprocess.h");
});

const Renderer = @import("Renderer.zig");

pub const Engine = struct {
    world: *flecs.world_t,

    pub const InitOptions = packed struct {
        renderer: bool = true,
    };

    pub fn init(opts: InitOptions) !Engine {
        const world = flecs.init();
        errdefer _ = flecs.fini(world);

        if (opts.renderer) {
            try Renderer.init(world);
        }

        try loadScene(world, "../../assets/bunny.obj");

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
        // TODO
        _ = ai_mat;
        mat.* = .{};
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
