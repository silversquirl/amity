// Deferred rendering shader

struct GeometryUniforms {
    material_idx: u32,
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
    return VertexOutput(
        vec4<f32>(in.pos, 1.0),
        in.normal,
    );
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

// Rendering shader (runs on G-Buffer)
@fragment
fn render() -> @location(0) vec4<f32> {
    return vec4<f32>(1.0, 1.0, 1.0, 1.0);
}
