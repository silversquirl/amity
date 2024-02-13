// Deferred rendering shader

struct GeometryUniforms {
    material_idx: u32,
    transform: mat4x4<f32>,
}

struct VertexInput {
    @location(0) pos: vec3<f32>,
    @location(1) normal: vec3<f32>
}
struct VertexOutput {
    @builtin(position) pos: vec4<f32>,
    @location(0) normal: vec3<f32>,
}
struct GBufferOutput {
    @location(0) normal_material: vec4<u32>,
}

@group(0) @binding(0) var<uniform> gu: GeometryUniforms;

// Geometry vertex shader
@vertex
fn vertex(in: VertexInput) -> VertexOutput {
    let pos = gu.transform * vec4<f32>(in.pos, 1.0);
    let normal = gu.transform * vec4<f32>(in.normal, 0.0);
    return VertexOutput(pos, normal.xyz);
}

// G-Buffer generation shader (runs on geometry)
@fragment
fn fragment(@location(0) normal: vec3<f32>) -> GBufferOutput {
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

@group(0) @binding(0) var g_buffer: texture_2d<u32>;
@group(1) @binding(0) var<storage> materials: array<Material>;

// Rendering shader (runs on G-Buffer)
@fragment
fn render(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let normal_material = textureLoad(g_buffer, vec2<u32>(pos.xy), 0);
    let normal = bitcast<vec3<f32>>(normal_material.xyz);
    let material_id = normal_material.w;

    if material_id == 0 {
        // OPTIM: check whether discard would be faster. then again we'll normally be rendering a skybox. And on that note...
        // TODO: sky material (or maybe it's faster to do that in a separate pass?)
        return vec4<f32>(0.0);
    }

    let mat = materials[material_id - 1];
    let color = unpackColor(mat.color);

    return vec4<f32>(color, 1.0);
}

fn unpackColor(color: u32) -> vec3<f32> {
    let i = vec3<u32>(
        (color >> (2 * 8)) & 0xff,
        (color >> (1 * 8)) & 0xff,
        (color >> (0 * 8)) & 0xff,
    );
    return vec3<f32>(i) / 255.0;
}
