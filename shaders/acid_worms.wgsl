// Acid Worms — writhing tendrils of light that react to audio.
// Raymarched SDF worm shapes that twist and pulse. Each worm
// responds to a different frequency band.

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

// Worm SDF: a thick sine wave in 2D
fn worm(p: vec2<f32>, freq: f32, amp: f32, phase: f32, thickness: f32) -> f32 {
    let wave_y = sin(p.x * freq + phase) * amp;
    return abs(p.y - wave_y) - thickness;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let uv = in.uv;
    let aspect = u.resolution.x / u.resolution.y;
    let p = vec2<f32>((uv.x - 0.5) * aspect, uv.y - 0.5) * 2.0;
    let t = u.time;

    var col = vec3<f32>(0.01, 0.005, 0.02); // near-black background

    let num_worms = 8;
    for (var i = 0; i < num_worms; i++) {
        let fi = f32(i);
        let seed = fi * 1.618; // golden ratio spread

        // Each worm has unique frequency, amplitude, phase, color
        let base_freq = 2.0 + fi * 0.7;
        let base_amp = 0.15 + fi * 0.03;
        let phase = t * (0.5 + fi * 0.2) + seed * 6.283;

        // Audio modulation: different worms respond to different bands
        var audio_mod = 0.0;
        if i < 3 {
            audio_mod = u.bass;        // first 3 worms: bass
        } else if i < 6 {
            audio_mod = u.mid;         // middle 3: mids
        } else {
            audio_mod = u.high;        // last 2: highs
        }

        let freq = base_freq + audio_mod * 2.0;
        let amp = base_amp + audio_mod * 0.1 + u.sub_bass * 0.05;
        let thick = 0.02 + u.amplitude * 0.015 + u.onset * 0.01;

        // Rotate the coordinate space per worm for variety
        let angle = seed * 3.14159 + t * 0.05;
        let ca = cos(angle);
        let sa = sin(angle);
        let rp = vec2<f32>(p.x * ca - p.y * sa, p.x * sa + p.y * ca);

        // SDF
        let d = worm(rp, freq, amp, phase, thick);

        // Glow: exponential falloff from the worm surface
        let glow = exp(-max(d, 0.0) * 30.0);
        let core = smoothstep(0.005, 0.0, d);

        // Color per worm: spread across the acid rainbow
        let hue = fract(fi / f32(num_worms) + t * 0.02 + audio_mod * 0.1);
        let worm_col = acid_rainbow(hue);

        col += worm_col * glow * 0.12;
        col += worm_col * core * (0.3 + u.amplitude * 0.4);
    }

    // Onset: flash overlay
    col += vec3<f32>(0.15, 0.1, 0.2) * u.onset * 0.3;

    // Beat: subtle pulse
    col *= 1.0 + u.beat * 0.08;

    // Presence: fine grain overlay
    let grain = fract(sin(dot(floor(p * 100.0), vec2<f32>(12.9898, 78.233))) * 43758.5453);
    col += vec3<f32>(grain) * u.presence * 0.03;

    // Vignette
    let d = length(uv - 0.5) * 1.4;
    col *= 1.0 - d * d * 0.4;

    // Scanlines
    let scan = 0.94 + 0.06 * sin(uv.y * u.resolution.y * 3.14159);
    col *= scan;

    return vec4<f32>(col, 1.0);
}

fn acid_rainbow(t: f32) -> vec3<f32> {
    let r = sin(t * 6.283 + 0.0) * 0.5 + 0.5;
    let g = sin(t * 6.283 + 2.094) * 0.5 + 0.5;
    let b = sin(t * 6.283 + 4.189) * 0.5 + 0.5;
    return vec3<f32>(r, g, b) * 1.2; // slightly overbright for neon feel
}
