// Post-processing: VHS / analog degrade.
// Tracking jitter, chroma bleed, rolling tape distortion, scanlines and tape
// noise — the nostalgic worn-cassette look. Onsets jolt the tracking, highs
// add hiss. Chain late (a CRT pass after it completes the retro stack).

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

fn hash(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    var uv = in.uv;

    // Per-line horizontal tracking jitter; onsets jolt it harder.
    let line = floor(uv.y * u.resolution.y);
    let jitter = (hash(vec2<f32>(line, floor(u.time * 24.0))) - 0.5)
        * (0.003 + u.onset * 0.02);

    // Rolling tracking band that sweeps up the frame and warps a strip.
    let band_pos = fract(uv.y + u.time * 0.08);
    let band = smoothstep(0.06, 0.0, abs(band_pos - 0.5));
    let warp = band * 0.02 * (0.5 + u.onset);

    uv.x = uv.x + jitter + warp;

    // Chroma bleed: split the colour channels horizontally.
    let bleed = 0.004 + band * 0.006;
    let r = textureSample(prev_frame, prev_sampler, uv + vec2<f32>(bleed, 0.0)).r;
    let g = textureSample(prev_frame, prev_sampler, uv).g;
    let b = textureSample(prev_frame, prev_sampler, uv - vec2<f32>(bleed, 0.0)).b;
    var col = vec3<f32>(r, g, b);

    // Slight desaturation toward worn tape.
    let gray = dot(col, vec3<f32>(0.299, 0.587, 0.114));
    col = mix(col, vec3<f32>(gray), 0.12);

    // Scanlines + tape hiss.
    let scan = 0.85 + 0.15 * sin(uv.y * u.resolution.y * 1.5);
    col = col * scan;
    let noise = hash(uv * u.resolution + u.time) - 0.5;
    col = col + noise * (0.05 + u.high * 0.08);

    // Tracking band lifts brightness like a dropout streak.
    col = col + band * 0.12;

    return vec4<f32>(col, 1.0);
}
