// Point Cloud — renders video/image content as scattered luminous particles.
// Quiet: points coalesce into the source image like a ghost materializing.
// Audio: bass scatters points outward, onset explodes them, presence sparkles.
// Looks like a holographic ghost of the source content.
//
// Uses prev_frame for video content (pair with video_player sources).

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

    // Point grid density — more points = more defined image
    let density = 80.0 + u.amplitude * 20.0; // 80-100 points per axis
    let cell = floor(uv * density);
    let cell_uv = fract(uv * density);
    let cell_center = (cell + 0.5) / density;

    // Sample the source image at this grid point
    let src = textureSample(prev_frame, prev_sampler, cell_center);
    let brightness = dot(src.rgb, vec3<f32>(0.299, 0.587, 0.114));

    // Only show points where there's content (brightness threshold)
    // More audio = lower threshold = more points visible
    let threshold = 0.08 - u.amplitude * 0.05;
    if brightness < threshold {
        // Dark areas: show faint background
        return vec4<f32>(0.005, 0.005, 0.01, 1.0);
    }

    // === Point displacement ===
    let point_seed = hash2(cell);

    // Bass: radial scatter from center
    let to_center = cell_center - 0.5;
    let bass_scatter = to_center * u.bass * 0.08;

    // Onset: explosive random scatter
    let onset_scatter = point_seed * u.onset * 0.04;

    // Sub-bass: slow drift/breathing
    let sub_drift = vec2<f32>(
        sin(t * 0.3 + point_seed.x * 6.283) * u.sub_bass * 0.01,
        cos(t * 0.25 + point_seed.y * 6.283) * u.sub_bass * 0.01
    );

    // High: jitter/vibration
    let jitter = hash2(cell + floor(t * 15.0)) * u.high * 0.008;

    // Total displacement
    let displacement = bass_scatter + onset_scatter + sub_drift + jitter;

    // Displaced point position within the cell
    let displaced_center = vec2<f32>(0.5) + displacement * density;

    // Distance from pixel to the displaced point center
    let dist = length(cell_uv - displaced_center);

    // Point size: brighter source = larger point, bass makes all points bigger
    let base_size = 0.15 + brightness * 0.2 + u.bass * 0.08;
    let point = smoothstep(base_size, base_size * 0.3, dist);

    if point < 0.01 {
        return vec4<f32>(0.005, 0.005, 0.01, 1.0);
    }

    // === Point color ===
    // Ghost tint: source color with ethereal blue-white shift
    let ghost_tint = vec3<f32>(0.4, 0.5, 0.7); // cool ethereal
    var point_col = mix(src.rgb, ghost_tint, 0.3 - brightness * 0.2);

    // Brighter points are more white (hot core)
    point_col = mix(point_col, vec3<f32>(0.9, 0.95, 1.0), brightness * brightness * 0.5);

    // Audio color shifts
    point_col += vec3<f32>(0.1, 0.0, 0.05) * u.bass; // warm on bass
    point_col += vec3<f32>(0.0, 0.05, 0.1) * u.presence; // cool on presence

    // Beat: all points flash brighter
    point_col *= 1.0 + u.beat * 0.3;

    // Onset: flash to white briefly
    point_col = mix(point_col, vec3<f32>(1.0), u.onset * 0.2);

    // Apply point shape
    var col = point_col * point;

    // Point glow (soft halo around each point)
    let glow = exp(-dist * dist * 60.0) * 0.15 * brightness;
    col += point_col * glow;

    // Presence sparkle: random extra-bright points
    let sparkle = step(0.98, hash1(cell + floor(t * 8.0))) * u.presence;
    col += vec3<f32>(0.8, 0.9, 1.0) * sparkle * 0.5;

    // Background: near-black
    col = max(col, vec3<f32>(0.005, 0.005, 0.01));

    return vec4<f32>(col, 1.0);
}
