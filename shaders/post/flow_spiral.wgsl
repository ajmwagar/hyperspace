// Post-processing: spiral flow field distortion with decay.
// Reads prev_frame, warps UVs in a spiral pattern, applies slight decay.
// Creates swirling trail effects when chained after any content shader.

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
    let centered = in.uv - 0.5;
    let angle = atan2(centered.y, centered.x);
    let r = length(centered);

    let speed = 0.02 * (1.0 + u.bass * 0.5);
    let pull = -0.005 * (1.0 + u.amplitude * 0.3);

    let flow = vec2<f32>(
        cos(angle + 1.5708) * speed + centered.x * pull,
        sin(angle + 1.5708) * speed + centered.y * pull
    );

    let warped = clamp(in.uv + flow, vec2<f32>(0.001), vec2<f32>(0.999));
    let prev = textureSample(prev_frame, prev_sampler, warped);

    let decay = 0.96 + u.bass * 0.02;
    return vec4<f32>(prev.rgb * decay, 1.0);
}
