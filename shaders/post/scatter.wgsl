// Post-processing: scatter/disintegrate effect.
// Breaks the previous image into particles that scatter with audio.
// Light touch version — can chain after any shader to add particle feel.

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
    onset: f32,
    sub_bass: f32,
    presence: f32,
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

fn hash2(p: vec2<f32>) -> vec2<f32> {
    let q = vec2<f32>(dot(p, vec2<f32>(127.1, 311.7)), dot(p, vec2<f32>(269.5, 183.3)));
    return fract(sin(q) * 43758.5453) * 2.0 - 1.0;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let uv = in.uv;

    // Scatter grid
    let grid = 50.0;
    let cell = floor(uv * grid);
    let cell_uv = fract(uv * grid);

    // Per-cell random displacement driven by audio
    let rnd = hash2(cell);
    let scatter_amount = u.bass * 0.06 + u.onset * 0.04;
    let offset = rnd * scatter_amount;

    // Sample source at displaced position
    let sample_uv = clamp(uv + offset, vec2<f32>(0.001), vec2<f32>(0.999));
    let src = textureSample(prev_frame, prev_sampler, sample_uv);

    // Point shape within cell
    let dist = length(cell_uv - 0.5);
    let point_size = 0.35 - u.bass * 0.1; // tighter points on bass
    let point = smoothstep(point_size, point_size * 0.5, dist);

    // Blend: when quiet, show full image. When loud, show scattered points.
    let scatter_mix = u.amplitude * 0.7 + u.onset * 0.3;
    var col = mix(src.rgb, src.rgb * point, scatter_mix);

    // Decay
    col *= 0.97;

    return vec4<f32>(col, 1.0);
}
