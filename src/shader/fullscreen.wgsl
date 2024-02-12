@vertex
fn vertex(@builtin(vertex_index) idx: u32) -> @builtin(position) vec4<f32> {
    let ipos = vec2<u32>(idx & 1, (idx >> 1) & 1);
    return vec4<f32>(
        vec2<f32>(ipos) * 4.0 - 1.0,
        0.0, 1.0,
    );
}
