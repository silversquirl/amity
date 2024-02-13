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

@group(0) @binding(0) var g_buffer: texture_2d<u32>;

// Rendering shader (runs on G-Buffer)
@fragment
fn render(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let normal_material = textureLoad(g_buffer, vec2<u32>(pos.xy), 0);
    let normal = bitcast<vec3<f32>>(normal_material.xyz);
    let material = normal_material.w;
    return vec4<f32>(normal, f32(min(material, 1u)));
}
