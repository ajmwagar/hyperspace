// Post-processing: chromatic aberration + RGB shift.
// Splits the R/G/B channels radially outward from center, like a cheap lens
// or a stressed CRT. Bass drives the split distance, onsets add a horizontal
// glitch jolt, highs add scanline-locked jitter. Chain after any shader.

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

fn hash(p: f32) -> f32 {
    return fract(sin(p * 78.233) * 43758.5453);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let center = in.uv - 0.5;
    let dist = length(center);
    let dir = center / max(dist, 0.0001);

    // Radial split amount grows with bass and toward the edges.
    var amount = (0.004 + u.bass * 0.02 + u.amplitude * 0.01) * dist;

    // Onset-driven horizontal glitch: shove whole scanlines sideways.
    let line = floor(in.uv.y * 80.0);
    let glitch = (hash(line + floor(u.time * 20.0)) - 0.5) * u.onset * 0.06;
    let jitter = vec2<f32>(glitch, 0.0);

    // High-frequency shimmer on the split.
    amount = amount + u.high * 0.01 * sin(in.uv.y * 200.0 + u.time * 40.0);

    let r = textureSample(prev_frame, prev_sampler, in.uv + dir * amount + jitter).r;
    let g = textureSample(prev_frame, prev_sampler, in.uv + jitter).g;
    let b = textureSample(prev_frame, prev_sampler, in.uv - dir * amount + jitter).b;

    var col = vec3<f32>(r, g, b);

    // Slight edge darkening sells the lens feel.
    col = col * (1.0 - dist * 0.3);

    return vec4<f32>(col, 1.0);
}
