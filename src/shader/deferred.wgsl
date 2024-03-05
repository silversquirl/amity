// Deferred rendering shader

struct Transforms {
    view: mat4x4<f32>,
    vp: mat4x4<f32>,
    inv_vp: mat4x4<f32>,
}

struct GeometryUniforms {
    material_idx: u32,
}

struct VertexInput {
    @location(0) pos: vec3<f32>,
    @location(1) normal: vec3<f32>
}
struct VertexOutput {
    @builtin(position) pos: vec4<f32>,
    // TODO: allow smooth shading
    @interpolate(flat) @location(0) normal: vec3<f32>,
}
struct GBufferOutput {
    @location(0) normal_material: vec4<u32>,
}

@group(0) @binding(0) var<uniform> trans: Transforms;
@group(0) @binding(1) var<uniform> gu: GeometryUniforms;

// Geometry vertex shader
@vertex
fn vertex(in: VertexInput) -> VertexOutput {
    let pos = trans.vp * vec4<f32>(in.pos, 1.0);
    let normal = trans.vp * vec4<f32>(in.normal, 0.0);
    return VertexOutput(pos, normal.xyz);
}

// G-Buffer generation shader (runs on geometry)
@fragment
fn fragment(@interpolate(flat) @location(0) normal: vec3<f32>) -> GBufferOutput {
    return GBufferOutput(
        vec4<u32>(
            bitcast<vec3<u32>>(normalize(normal)),
            gu.material_idx + 1
        ),
    );
}

struct Material {
    color: u32,
    metallic: f32,
    roughness: f32,
    ior: f32,
}

struct DirectionalLight {
    color: u32,
    dir: vec3<f32>,
}

// TODO: more light types
// OPTIN: another approach to lighting occurs to me: draw an instance for every light and accumulate the results with blending.
//        idk if it's faster, but it sure is cool! Removes the loop and turns storage buffers into per-instance vertex data.
//        One issue is that different light types would require different passes, though that could be fixed with a union.

@group(1) @binding(0) var depth_buffer: texture_depth_2d;
@group(1) @binding(1) var g_buffer: texture_2d<u32>;
@group(2) @binding(0) var<storage> materials: array<Material>;
@group(2) @binding(1) var<storage> lights_dir: array<DirectionalLight>;

const pi = radians(180.0);
const ambient_strength = 0.05;

// Rendering shader (runs on G-Buffer)
@fragment
fn render(@builtin(position) frag_pos: vec4<f32>) -> @location(0) vec4<f32> {
    let load_pos = vec2<u32>(frag_pos.xy);
    let normal_material = textureLoad(g_buffer, load_pos, 0);
    let material_id = normal_material.w;
    if material_id == 0 {
        // OPTIM: check whether discard would be faster. then again we'll normally be rendering a skybox. And on that note...
        // TODO: sky material (or maybe it's faster to do that in a separate pass?)
        return vec4<f32>(0.0);
    }
    let mat = materials[material_id - 1];
    let depth = textureLoad(depth_buffer, load_pos, 0);
    let normal = bitcast<vec3<f32>>(normal_material.xyz);

    // Compute position of fragment in world space
    let screen_size = vec2<f32>(textureDimensions(g_buffer).xy);
    let clip_pos = vec3(frag_pos.xy, depth);
    let view_pos = clip_pos * vec3<f32>(2.0 / screen_size, 1.0) - vec3<f32>(1.0, 1.0, 0.0);
    let pos = trans.inv_vp * vec4<f32>(view_pos, 1.0);

    // PBR lighting
    let v = normalize(pos.xyz);
    var l0 = ambient_strength * unpackColor(mat.color);
    for (var i: u32 = 0; i < arrayLength(&lights_dir) - 1; i += 1) {
        let light = lights_dir[i];
        let dir = trans.view * vec4<f32>(light.dir, 0.0);

        let c_light = unpackColor(light.color);
        let l = normalize(dir.xyz);
        l0 += brdf(l, v, normal, mat) * c_light * max(dot(normal, l), 0.0);
    }

    return vec4<f32>(pi * l0, 1.0);
}

@group(3) @binding(0) var output: texture_storage_2d<rgba16float, write>;

@compute @workgroup_size(8, 8)
fn renderCompute(@builtin(global_invocation_id) id: vec3<u32>) {
    let normal_material = textureLoad(g_buffer, id.xy, 0);
    let material_id = normal_material.w;
    if material_id == 0 {
        textureStore(output, id.xy, vec4<f32>(0.0));
        return;
    }
    let mat = materials[material_id - 1];
    let depth = textureLoad(depth_buffer, id.xy, 0);
    let normal = bitcast<vec3<f32>>(normal_material.xyz);

    // Compute position of fragment in world space
    let screen_size = vec2<f32>(textureDimensions(g_buffer).xy);
    let clip_pos = vec3(vec2<f32>(id.xy), depth);
    let view_pos = clip_pos * vec3<f32>(2.0 / screen_size, 1.0) - vec3<f32>(1.0, 1.0, 0.0);
    let pos = trans.inv_vp * vec4<f32>(view_pos, 1.0);

    // PBR lighting
    let v = normalize(pos.xyz);
    var l0 = ambient_strength * unpackColor(mat.color);
    for (var i: u32 = 0; i < arrayLength(&lights_dir) - 1; i += 1) {
        let light = lights_dir[i];
        let dir = trans.view * vec4<f32>(light.dir, 0.0);

        let c_light = unpackColor(light.color);
        let l = normalize(dir.xyz);
        l0 += brdf(l, v, normal, mat) * c_light * max(dot(normal, l), 0.0);
    }

    let color = vec4<f32>(pi * l0, 1.0);
    textureStore(output, id.xy, color);
}

fn brdf(l: vec3<f32>, v: vec3<f32>, normal: vec3<f32>, mat: Material) -> vec3<f32> {
    // Lambertian diffuse
    let color = unpackColor(mat.color);
    let f_diff = color / pi;
    return f_diff;
}

fn unpackColor(color: u32) -> vec3<f32> {
    let i = vec3<u32>(
        (color >> (2 * 8)) & 0xff,
        (color >> (1 * 8)) & 0xff,
        (color >> (0 * 8)) & 0xff,
    );
    return vec3<f32>(i) / 255.0;
}
