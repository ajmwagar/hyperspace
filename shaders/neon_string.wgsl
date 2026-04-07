// Neon String — a single luminous arc that vibrates with audio.
// Quiet: a dim, gently breathing neon curve floating in darkness.
// Sound: the string shakes, oscillates, bends with the waveform.
// Designed for guitar, reverb tails, atmospheric sounds.

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

fn get_waveform(idx: u32) -> f32 {
    if idx < 512u { return audio_buf[512u + idx]; }
    return 0.0;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let uv = in.uv;
    let aspect = u.resolution.x / u.resolution.y;
    let p = vec2<f32>((uv.x - 0.5) * aspect, uv.y - 0.5);
    let t = u.time;

    // Pure black background
    var col = vec3<f32>(0.0);

    // === The String ===
    // Multiple strings with slight offsets for a rainbow spread

    let num_strings = 7;
    for (var s = 0; s < num_strings; s++) {
        let si = f32(s);
        let string_spread = (si - 3.0) * 0.012; // vertical offset per string

        // Base curve: gentle sine that breathes slowly
        let base_bend = sin(p.x * 1.5 + t * 0.3 + si * 0.5) * 0.03;

        // Waveform displacement: smoothly interpolated for clean curves
        let sample_x = clamp(uv.x, 0.0, 1.0);
        let wave_pos = sample_x * 510.0;
        let idx0 = u32(floor(wave_pos));
        let idx1 = min(idx0 + 1u, 511u);
        let frac = fract(wave_pos);
        // Cubic hermite interpolation for extra smoothness
        let w0 = get_waveform(idx0);
        let w1 = get_waveform(idx1);
        let w_prev = get_waveform(max(idx0, 1u) - 1u);
        let w_next = get_waveform(min(idx1 + 1u, 511u));
        let t0 = (w1 - w_prev) * 0.5;
        let t1 = (w_next - w0) * 0.5;
        let f2 = frac * frac;
        let f3 = f2 * frac;
        let wave = w0 * (2.0*f3 - 3.0*f2 + 1.0) + t0 * (f3 - 2.0*f2 + frac)
                 + w1 * (-2.0*f3 + 3.0*f2) + t1 * (f3 - f2);

        // Scale by amplitude so silence = flat, loud = wild
        let wave_displacement = wave * (0.15 + u.amplitude * 0.25);

        // Additional harmonic vibrations driven by different bands
        let bass_vib = sin(p.x * 3.0 + t * 2.0 + si) * u.bass * 0.04;
        let mid_vib = sin(p.x * 8.0 + t * 4.0 + si * 2.0) * u.mid * 0.02;
        let high_vib = sin(p.x * 20.0 + t * 8.0 + si * 3.0) * u.high * 0.008;

        // Onset: sharp impulse shake
        let onset_shake = sin(p.x * 15.0 + t * 30.0) * u.onset * 0.03;

        // Total vertical position of the string at this x
        let string_y = string_spread + base_bend + wave_displacement
                     + bass_vib + mid_vib + high_vib + onset_shake;

        // Distance from pixel to the string
        let dist = abs(p.y - string_y);

        // String thickness: thinner when quiet, slightly thicker when loud
        let thickness = 0.003 + u.amplitude * 0.002;

        // Core line
        let core = smoothstep(thickness, thickness * 0.2, dist);

        // Glow: wide soft bloom
        let glow = exp(-dist * dist * 800.0) * 0.4;

        // Outer haze
        let haze = exp(-dist * dist * 100.0) * 0.1;

        // === Color: diminished rainbow ===
        // Each string is a different hue, but muted/dark
        let hue = si / f32(num_strings);
        let string_col = neon_dim(hue, t);

        // Brightness: dim when quiet, vivid when played
        let energy = 0.15 + u.amplitude * 0.85;

        col += string_col * core * energy;
        col += string_col * glow * energy * 0.6;
        col += string_col * haze * energy * 0.3;
    }

    // === Sub-bass: deep pulse behind the strings ===
    let sub_glow = exp(-p.y * p.y * 20.0) * u.sub_bass * 0.04;
    col += vec3<f32>(0.1, 0.0, 0.15) * sub_glow;

    // === Presence: fine shimmer particles ===
    let spark_seed = fract(sin(dot(floor(p * 200.0), vec2<f32>(12.9898, 78.233))) * 43758.5453);
    if spark_seed > 0.997 && u.presence > 0.1 {
        col += vec3<f32>(0.4, 0.5, 0.6) * u.presence * 0.3;
    }

    // === Beat: brief bloom of all strings ===
    col *= 1.0 + u.beat * 0.15;

    // Ensure pure black stays black
    col = max(col, vec3<f32>(0.0));

    return vec4<f32>(col, 1.0);
}

// Diminished neon rainbow: rich but dark. Not pastel, not full-bright.
// Think neon tubes in a dark room — vivid hue but not blinding.
fn neon_dim(hue: f32, t: f32) -> vec3<f32> {
    // Slowly drift the whole rainbow
    let h = fract(hue + t * 0.01) * 6.0;
    let c = 0.7; // saturation — high but not 1.0
    let x = c * (1.0 - abs(h % 2.0 - 1.0));

    var rgb: vec3<f32>;
    if h < 1.0 { rgb = vec3<f32>(c, x, 0.0); }        // red → yellow
    else if h < 2.0 { rgb = vec3<f32>(x, c, 0.0); }    // yellow → green
    else if h < 3.0 { rgb = vec3<f32>(0.0, c, x); }     // green → cyan
    else if h < 4.0 { rgb = vec3<f32>(0.0, x, c); }     // cyan → blue
    else if h < 5.0 { rgb = vec3<f32>(x, 0.0, c); }     // blue → magenta
    else { rgb = vec3<f32>(c, 0.0, x); }                  // magenta → red

    // Dim it down — neon in darkness, not daylight
    return rgb * 0.6;
}
