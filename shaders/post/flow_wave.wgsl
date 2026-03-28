// Post-processing: horizontal sine wave displacement.
// Applies undulating horizontal distortion with frequency driven by mid.
// Creates rippling, water-like trail effects.

struct Uniforms {
    time: f32,
    delta_time: f32,
    resolution: vec2<f32>,
    amplitude: f32,
    beat: f32,
    bass: f32,
    mid: f32,
    high: f32,
    cv: array<vec4<f32>, 2>,
    scene_id: u32,
    amplitude_l: f32,
    amplitude_r: f32,
    bass_l: f32,
    bass_r: f32,
    mid_l: f32,
    mid_r: f32,
    high_l: f32,
    high_r: f32,
};

@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(3) var prev_sampler: sampler;
@group(0) @binding(4) var prev_frame: texture_2d<f32>;

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) idx: u32) -> VertexOutput {
    var pos = array<vec2<f32>, 3>(
        vec2<f32>(-1.0, -1.0),
        vec2<f32>(3.0, -1.0),
        vec2<f32>(-1.0, 3.0),
    );
    var out: VertexOutput;
    out.position = vec4<f32>(pos[idx], 0.0, 1.0);
    out.uv = pos[idx] * 0.5 + 0.5;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    // Wave frequency driven by mid, with a comfortable base
    let freq = 4.0 + u.mid * 8.0;

    // Wave amplitude driven by bass and overall amplitude
    let wave_amp = 0.008 * (1.0 + u.bass * 0.6 + u.amplitude * 0.4);

    // Horizontal displacement: sine wave along Y axis, scrolling over time
    let phase = u.time * 0.5;
    let dx = sin(in.uv.y * freq + phase) * wave_amp;

    // Subtle vertical displacement for organic feel, driven by high
    let dy = cos(in.uv.x * freq * 0.7 + phase * 1.3) * wave_amp * 0.3 * (1.0 + u.high * 0.5);

    let flow = vec2<f32>(dx, dy);
    let warped = clamp(in.uv + flow, vec2<f32>(0.001), vec2<f32>(0.999));
    let prev = textureSample(prev_frame, prev_sampler, warped);

    let decay = 0.95 + u.bass * 0.02;
    return vec4<f32>(prev.rgb * decay, 1.0);
}
