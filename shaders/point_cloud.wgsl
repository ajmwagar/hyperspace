// Point Cloud — renders video content as scattered luminous particles.
// Quiet: dense points reconstruct the source image clearly.
// Audio: particles scatter, explode, and drift apart.
// Uses prev_frame for video content.

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
@group(0) @binding(1) var<storage, read> audio_buf: array<f32>;
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

fn hash1(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let uv = in.uv;
    let t = u.time;

    // Dense grid — enough points to clearly read the image
    let density = 200.0;
    let cell = floor(uv * density);
    let cell_uv = fract(uv * density);
    let cell_center = (cell + 0.5) / density;

    // Sample the source at this grid point
    let src = textureSample(prev_frame, prev_sampler, cell_center);
    let brightness = dot(src.rgb, vec3<f32>(0.299, 0.587, 0.114));

    // Per-point random seed
    let seed = hash2(cell);
    let seed1 = hash1(cell);

    // === Displacement: scales with audio ===
    // When quiet, displacement is near zero → image is clear
    let scatter_strength = u.bass * 0.12 + u.onset * 0.08 + u.amplitude * 0.02;

    // Radial scatter from center on bass
    let to_center = (cell_center - 0.5) * 2.0;
    let radial = to_center * u.bass * 0.06;

    // Random scatter on onset
    let random_scatter = seed * u.onset * 0.05;

    // Gentle drift on sub-bass
    let drift = vec2<f32>(
        sin(t * 0.4 + seed.x * 6.28) * u.sub_bass * 0.008,
        cos(t * 0.35 + seed.y * 6.28) * u.sub_bass * 0.008
    );

    // Jitter on highs
    let jitter = hash2(cell + floor(t * 20.0)) * u.high * 0.005;

    let total_disp = (radial + random_scatter + drift + jitter) * density;

    // Displaced point position within cell
    let point_pos = vec2<f32>(0.5) + total_disp;
    let dist = length(cell_uv - point_pos);

    // === Point size ===
    // Quiet: large points that nearly touch → reads as solid image
    // Loud: smaller points with gaps → reads as particles
    let quiet_size = 0.48; // nearly fills the cell when quiet
    let loud_size = 0.15;
    let point_size = mix(quiet_size, loud_size, scatter_strength);

    let point = smoothstep(point_size, point_size * 0.4, dist);

    // Skip empty points
    if point < 0.01 && brightness < 0.05 {
        return vec4<f32>(0.005, 0.005, 0.015, 1.0);
    }

    // === Color ===
    // Mostly source color, with ethereal tint at edges
    var col = src.rgb;

    // Edge particles get a ghostly blue-white shift
    let edge_tint = 1.0 - point; // stronger at point edges
    col = mix(col, col + vec3<f32>(0.05, 0.08, 0.15), edge_tint * 0.3);

    // Bass: warm push
    col += vec3<f32>(0.06, 0.02, 0.0) * u.bass;

    // Beat flash
    col *= 1.0 + u.beat * 0.2;

    // Onset: bright flash
    col = mix(col, vec3<f32>(0.9, 0.92, 1.0), u.onset * 0.15);

    // Apply point mask
    col *= point;

    // Soft glow around each point
    let glow = exp(-dist * dist * 40.0) * 0.08 * brightness;
    col += src.rgb * glow;

    // Sparkle on presence
    let sparkle = step(0.985, hash1(cell + floor(t * 10.0)));
    col += vec3<f32>(0.6, 0.7, 0.9) * sparkle * u.presence * 0.4;

    // Floor
    col = max(col, vec3<f32>(0.005, 0.005, 0.015));

    return vec4<f32>(col, 1.0);
}
