@group(0) @binding(0) var tex: texture_2d<f32>;

@fragment
fn fragment(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let color = textureLoad(tex, vec2<u32>(pos.xy), 0);
    return color;
}
