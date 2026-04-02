// Classic Viz — Winamp / milkdrop-inspired visualizer.
// Radial spectrum with mirrored waveform, kaleidoscope rotation,
// color-cycling trails. Pure nostalgia.

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
@group(0) @binding(1) var<storage, read> spectrum: array<f32>;

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

fn hsv(h: f32, s: f32, v: f32) -> vec3<f32> {
    let c = v * s;
    let hp = h * 6.0;
    let x = c * (1.0 - abs(hp % 2.0 - 1.0));
    let m = v - c;
    var rgb: vec3<f32>;
    if hp < 1.0 { rgb = vec3<f32>(c, x, 0.0); }
    else if hp < 2.0 { rgb = vec3<f32>(x, c, 0.0); }
    else if hp < 3.0 { rgb = vec3<f32>(0.0, c, x); }
    else if hp < 4.0 { rgb = vec3<f32>(0.0, x, c); }
    else if hp < 5.0 { rgb = vec3<f32>(x, 0.0, c); }
    else { rgb = vec3<f32>(c, 0.0, x); }
    return rgb + m;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let uv = (in.uv - 0.5) * 2.0;
    let aspect = u.resolution.x / u.resolution.y;
    let p = vec2<f32>(uv.x * aspect, uv.y);

    let angle = atan2(p.y, p.x);
    let radius = length(p);

    var col = vec3<f32>(0.0, 0.0, 0.02);

    // === Radial spectrum bars ===
    let num_bars = 64.0;
    let pi = 3.14159265;

    // Kaleidoscope: mirror angle into fewer segments
    let kal_segments = 6.0 + floor(u.mid * 4.0); // 6-10 segments based on mids
    let kal_angle = abs(((angle + pi) / (2.0 * pi) * kal_segments) % 1.0 - 0.5) * 2.0;

    let bar_idx = floor(kal_angle * num_bars);
    let bar_frac = fract(kal_angle * num_bars);
    let bar_gap = smoothstep(0.0, 0.15, bar_frac) * smoothstep(1.0, 0.85, bar_frac);

    let spec_idx = u32(bar_idx * 4.0);
    var spec_val = 0.0;
    if spec_idx < 512u {
        spec_val = spectrum[spec_idx] * 15.0;
    }
    spec_val = clamp(spec_val, 0.0, 1.0);

    // Bar extends outward from inner radius
    let inner_r = 0.15 + u.amplitude * 0.1;
    let outer_r = inner_r + spec_val * 0.8;
    let bar_fill = step(inner_r, radius) * step(radius, outer_r) * bar_gap;

    // Color cycling — classic rainbow
    let hue = fract(bar_idx / num_bars + u.time * 0.1);
    let bar_color = hsv(hue, 0.8, 1.0);
    col += bar_color * bar_fill * 0.9;

    // === Concentric rings (waveform-driven) ===
    let num_rings = 8.0;
    for (var i = 0u; i < 8u; i++) {
        let ring_r = 0.1 + f32(i) * 0.12;
        let ring_spec_idx = u32(f32(i) * 32.0);
        var ring_amp = 0.0;
        if ring_spec_idx < 512u {
            ring_amp = spectrum[ring_spec_idx] * 8.0;
        }

        let wobble = sin(angle * (3.0 + f32(i)) + u.time * (1.0 + f32(i) * 0.3)) * ring_amp * 0.03;
        let ring_dist = abs(radius - ring_r - wobble);
        let ring_line = smoothstep(0.008 + ring_amp * 0.005, 0.0, ring_dist);

        let ring_hue = fract(f32(i) / num_rings + u.time * 0.15 + 0.5);
        col += hsv(ring_hue, 0.6, 0.8) * ring_line * 0.5;
    }

    // === Center orb — pulses with beat ===
    let orb_r = 0.08 + u.beat * 0.06 + u.amplitude * 0.04 + u.onset * 0.4;
    let orb_dist = smoothstep(orb_r, 0.0, radius);
    let orb_hue = fract(u.time * 0.2);
    col += hsv(orb_hue, 0.5, 1.0) * orb_dist;

    // Orb glow
    let glow = exp(-radius * 4.0) * (0.2 + u.beat * 0.5);
    col += hsv(orb_hue, 0.3, 0.6) * glow;

    // === Rotating particle sparkles ===
    let spark_angle = angle + u.time * 0.8;
    let spark_pattern = sin(spark_angle * 20.0) * sin(radius * 30.0 - u.time * 5.0);
    let spark = smoothstep(0.7, 1.0, spark_pattern) * smoothstep(0.2, 0.5, radius) * smoothstep(1.5, 0.8, radius);
    col += vec3<f32>(1.0, 1.0, 1.0) * spark * u.presence * 0.3;

    // === Beat flash ring ===
    if u.beat > 0.3 {
        let flash_r = 0.3 + (1.0 - u.beat) * 0.7; // expands outward as beat decays
        let flash_dist = abs(radius - flash_r);
        let flash = smoothstep(0.05, 0.0, flash_dist) * u.beat;
        col += vec3<f32>(1.0, 0.9, 0.8) * flash * 0.6;
    }

    // === Background rotation warp ===
    let warp_angle = angle + sin(radius * 5.0 - u.time) * 0.1 * u.amplitude;
    let bg_pattern = sin(warp_angle * 3.0 + u.time * 0.5) * 0.5 + 0.5;
    col += hsv(fract(bg_pattern * 0.3 + u.time * 0.05), 0.4, 0.05) * smoothstep(0.3, 1.5, radius);

    // Vignette
    col *= 1.0 - radius * 0.25;

    return vec4<f32>(col, 1.0);
}
