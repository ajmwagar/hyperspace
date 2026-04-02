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

// Spectrum analyzer bars with gauge aesthetic
@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let uv = in.uv;
    let aspect = u.resolution.x / u.resolution.y;

    // Background: dark with subtle scan lines (CRT feel)
    let scanline = 0.95 + 0.05 * sin(uv.y * u.resolution.y * 3.14159);
    var bg = vec3<f32>(0.02, 0.03, 0.05) * scanline;

    // Spectrum bars
    let num_bars = 32.0;
    let bar_idx = floor(uv.x * num_bars);
    let bar_frac = fract(uv.x * num_bars);
    let bar_gap = smoothstep(0.0, 0.05, bar_frac) * smoothstep(1.0, 0.95, bar_frac);

    // Sample spectrum at bar position
    let spectrum_idx = u32(bar_idx * 512.0 / num_bars);
    var bar_height = 0.0;
    if spectrum_idx < 512u {
        bar_height = spectrum[spectrum_idx] * 15.0; // scale up for visibility
    }
    bar_height = clamp(bar_height, 0.0, 1.0);

    // Bar fill
    let filled = step(1.0 - uv.y, bar_height);

    // Color gradient: green -> yellow -> red based on height
    let bar_color = mix(
        vec3<f32>(0.0, 1.0, 0.3),
        mix(
            vec3<f32>(1.0, 1.0, 0.0),
            vec3<f32>(1.0, 0.1, 0.0),
            smoothstep(0.6, 0.9, 1.0 - uv.y)
        ),
        smoothstep(0.3, 0.6, 1.0 - uv.y)
    );

    // Gauge tick marks on the sides
    let tick_y = fract(uv.y * 10.0);
    let tick = smoothstep(0.0, 0.02, tick_y) * smoothstep(0.04, 0.02, tick_y);
    let tick_vis = step(uv.x, 0.02) + step(0.98, uv.x);
    let tick_color = vec3<f32>(0.3, 0.4, 0.3) * tick * tick_vis;

    // Bass meter (bottom bar)
    let bass_bar = step(0.95, uv.y) * step(uv.x, u.bass * 3.0) * (1.0 + u.sub_bass * 2.0);
    let bass_color = vec3<f32>(0.8, 0.2, 0.1) * bass_bar;

    // Beat indicator (pulsing border)
    let border = step(uv.x, 0.005) + step(0.995, uv.x) +
                 step(uv.y, 0.005) + step(0.995, uv.y);
    let beat_glow = vec3<f32>(1.0, 0.5, 0.2) * border * (u.beat + u.onset * 0.5);

    // Combine
    var color = bg + bar_color * filled * bar_gap + tick_color + bass_color + beat_glow;

    // CRT phosphor glow
    color *= scanline;

    return vec4<f32>(color, 1.0);
}
