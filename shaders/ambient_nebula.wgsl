// Ambient Nebula — grows slowly with the music.
// Starts near-black. Each sound seeds a wisp of color that drifts
// and accumulates through the feedback loop. Over minutes, the
// canvas fills with layered organic texture. Designed for ambient,
// drone, post-rock, and slow-building music.
//
// Feedback loop is critical: decay is very high (0.995+) so trails
// persist for minutes. New content is drawn faintly on top.

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

// Smooth noise
fn hash(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}

fn noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u2 = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(hash(i), hash(i + vec2<f32>(1.0, 0.0)), u2.x),
        mix(hash(i + vec2<f32>(0.0, 1.0)), hash(i + vec2<f32>(1.0, 1.0)), u2.x),
        u2.y
    );
}

fn fbm(p: vec2<f32>) -> f32 {
    var val = 0.0;
    var amp = 0.5;
    var freq = 1.0;
    var q = p;
    for (var i = 0; i < 5; i++) {
        val += amp * noise(q * freq);
        freq *= 2.0;
        amp *= 0.5;
        q += vec2<f32>(1.3, 1.7);
    }
    return val;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let uv = in.uv;
    let aspect = u.resolution.x / u.resolution.y;
    let p = vec2<f32>((uv.x - 0.5) * aspect, uv.y - 0.5);
    let t = u.time;

    // ========================================================
    // 1. Sample previous frame with very slow drift
    // ========================================================
    let drift_speed = 0.002 + u.sub_bass * 0.001;
    let drift_angle = t * 0.05 + fbm(p * 0.5 + t * 0.01) * 0.5;
    let drift = vec2<f32>(
        cos(drift_angle) * drift_speed,
        sin(drift_angle) * drift_speed
    );

    // Slight zoom out to prevent content collapsing to center
    let zoom = 1.001 + u.amplitude * 0.0005;
    let warped_uv = (uv - 0.5) * zoom + 0.5 + drift;
    let clamped_uv = clamp(warped_uv, vec2<f32>(0.001), vec2<f32>(0.999));
    let prev = textureSample(prev_frame, prev_sampler, clamped_uv);

    // Very high decay — trails persist for minutes
    // Less decay when music is louder (fades faster during climax, slower during quiet)
    let decay = 0.997 - u.amplitude * 0.003;
    var col = prev.rgb * decay;

    // ========================================================
    // 2. Seed new wisps based on audio
    // ========================================================

    // Noise-based wisp positions that slowly evolve
    let wisp_field = fbm(p * 3.0 + t * 0.03);
    let wisp_field2 = fbm(p * 2.0 - t * 0.02 + 10.0);

    // Onset seeds: when a new sound appears, add a burst of color
    // at positions determined by the noise field
    let onset_gate = smoothstep(0.1, 0.5, u.onset);
    let onset_wisp = smoothstep(0.45, 0.55, wisp_field) * onset_gate;

    // Amplitude wisps: continuous gentle addition proportional to level
    let amp_wisp = smoothstep(0.5, 0.6, wisp_field2) * u.amplitude * 0.15;

    // Sub-bass clouds: very large, slow-moving, deep color
    let sub_cloud = smoothstep(0.3, 0.7, fbm(p * 0.8 + t * 0.005)) * u.sub_bass * 0.08;

    // Presence sparkle: tiny bright points on high-frequency content
    let sparkle_pos = hash(floor(p * 60.0) + floor(t * 3.0));
    let sparkle = step(0.97, sparkle_pos) * u.presence * 0.4;

    // ========================================================
    // 3. Color palette — shifts with the character of the music
    // ========================================================

    // Base: deep blues and purples for quiet, shifts to teals and warm
    // tones as the music builds
    let warmth = u.amplitude * 0.5 + u.mid * 0.3; // 0=cold, ~0.5=warm
    let depth = u.sub_bass + u.bass * 0.5; // low-end presence

    // Cold palette: deep navy, indigo, violet
    let cold = vec3<f32>(0.05, 0.08, 0.2) + vec3<f32>(0.1, 0.0, 0.15) * wisp_field;
    // Warm palette: teal, amber, soft pink
    let warm = vec3<f32>(0.1, 0.2, 0.18) + vec3<f32>(0.2, 0.1, 0.05) * wisp_field;
    // Deep palette: for sub-bass clouds
    let deep = vec3<f32>(0.15, 0.02, 0.1) + vec3<f32>(0.05, 0.0, 0.1) * depth;

    let palette = mix(cold, warm, warmth);

    // ========================================================
    // 4. Compose new content onto the accumulated canvas
    // ========================================================

    // Onset wisps: medium brightness, palette color
    col += palette * onset_wisp * 0.25;

    // Amplitude wisps: very faint, continuous
    col += palette * amp_wisp;

    // Sub-bass clouds: deep color, very subtle
    col += deep * sub_cloud;

    // Presence sparkle: bright white points
    col += vec3<f32>(0.7, 0.8, 0.9) * sparkle;

    // Beat: subtle pulse of brightness across existing content
    col *= 1.0 + u.beat * 0.03;

    // ========================================================
    // 5. Gentle post-processing
    // ========================================================

    // Soft vignette (very gentle, ambient doesn't need harsh framing)
    let vig_dist = length(uv - 0.5);
    col *= 1.0 - vig_dist * vig_dist * 0.3;

    // Prevent total darkness — always a faint hint of deep blue
    let floor_col = vec3<f32>(0.008, 0.01, 0.02);
    col = max(col, floor_col);

    // Prevent blowout — soft clamp
    col = col / (col + 0.8) * 1.2;

    return vec4<f32>(col, 1.0);
}
