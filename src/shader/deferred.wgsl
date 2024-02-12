// Deferred rendering shader

struct GeometryUniforms {
    material_idx: u32,
}

struct GBufferOutput {
    @location(0) normal_material: vec4<u32>,
}

@group(0) @binding(0) var<uniform> gu: GeometryUniforms;

// Geometry vertex shader
@vertex
fn vertex() -> @builtin(position) vec4<f32> {
    return vec4<f32>(0.0, 0.0, 0.0, 1.0);
}

// G-Buffer generation shader (runs on geometry)
@fragment
fn fragment() -> GBufferOutput {
    let normal = vec3<f32>(0.0, 1.0, 0.0);
    let material: u32 = 1;
    return GBufferOutput(
        vec4<u32>(
            bitcast<vec3<u32>>(normal),
            material
        ),
    );
}

// Rendering shader (runs on G-Buffer)
@fragment
fn render() -> @location(0) vec4<f32> {
    return vec4<f32>(1.0, 1.0, 1.0, 1.0);
}
