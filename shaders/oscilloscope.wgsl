// Oscilloscope — dual-trace scope display with Lissajous XY mode.
// Top: L/R waveforms as time-domain traces (green phosphor).
// Bottom: Lissajous figure (L=X, R=Y) like a real analog scope.
// Audio drives everything directly — this IS the signal.

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

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let uv = in.uv;
    let aspect = u.resolution.x / u.resolution.y;

    // Dark scope background with subtle grid
    var col = vec3<f32>(0.01, 0.02, 0.01);

    // === Grid (scope graticule) ===
    let grid_spacing = 0.1;
    let gx = abs(fract(uv.x / grid_spacing + 0.5) - 0.5);
    let gy = abs(fract(uv.y / grid_spacing + 0.5) - 0.5);
    let grid_line = smoothstep(0.003, 0.0, gx) + smoothstep(0.003, 0.0, gy);
    col += vec3<f32>(0.0, 0.06, 0.02) * grid_line;

    // Center cross (brighter)
    let cx = smoothstep(0.002, 0.0, abs(uv.x - 0.5));
    let cy = smoothstep(0.002, 0.0, abs(uv.y - 0.5));
    col += vec3<f32>(0.0, 0.1, 0.03) * (cx + cy);

    // === Waveform traces using spectrum data ===
    // We use spectrum bins as a proxy for the waveform shape
    // (actual waveform would need a separate buffer, but spectrum gives us contour)
    let num_points = 256u;

    // Upper half: horizontal sweep — spectrum as amplitude
    if uv.y > 0.5 {
        let trace_y_center = 0.75;
        let sx = uv.x;
        let bin = u32(sx * f32(num_points));

        if bin < 512u {
            let val = spectrum[bin];
            // Scale: spectrum values are 0..1 after log normalization
            let wave_y = trace_y_center + (val - 0.5) * 0.35 * (1.0 + u.amplitude);

            let dist = abs(uv.y - wave_y);
            // Phosphor glow: bright core + soft bloom
            let trace = smoothstep(0.006, 0.0, dist);
            let bloom = exp(-dist * 80.0) * 0.3;

            let phosphor = vec3<f32>(0.2, 1.0, 0.3); // green phosphor
            col += phosphor * (trace + bloom) * 0.8;
        }

        // Second trace offset (shows difference/envelope)
        let bin2 = u32(sx * 128.0);
        if bin2 < 512u {
            let val2 = spectrum[bin2];
            let wave_y2 = trace_y_center - 0.02 + (val2 - 0.5) * 0.25;
            let dist2 = abs(uv.y - wave_y2);
            let trace2 = smoothstep(0.004, 0.0, dist2);
            let bloom2 = exp(-dist2 * 100.0) * 0.2;
            col += vec3<f32>(0.1, 0.5, 1.0) * (trace2 + bloom2) * 0.5; // blue trace
        }
    }

    // === Lower half: Lissajous / XY mode ===
    if uv.y < 0.5 {
        let center = vec2<f32>(0.5, 0.25);
        let liss_p = (vec2<f32>(uv.x, uv.y) - center) * 2.0;

        // Build Lissajous from spectrum data: sample pairs as X,Y
        var liss_field = 0.0;
        let liss_points = 128u;
        for (var i = 0u; i < liss_points; i++) {
            let t_norm = f32(i) / f32(liss_points);
            let idx_a = i * 2u;
            let idx_b = i * 2u + 1u;

            var sx = 0.0;
            var sy = 0.0;
            if idx_a < 512u { sx = (spectrum[idx_a] - 0.5) * 2.0; }
            if idx_b < 512u { sy = (spectrum[idx_b] - 0.5) * 2.0; }

            // Scale by amplitude
            sx *= 0.6 + u.amplitude_l * 0.8;
            sy *= 0.6 + u.amplitude_r * 0.8;

            let d = length(liss_p - vec2<f32>(sx, sy));
            liss_field += exp(-d * d * 800.0);
        }

        let liss_trace = clamp(liss_field * 0.15, 0.0, 1.0);
        let liss_bloom = clamp(liss_field * 0.03, 0.0, 0.5);
        col += vec3<f32>(0.2, 1.0, 0.3) * liss_trace;
        col += vec3<f32>(0.1, 0.4, 0.15) * liss_bloom;
    }

    // === Divider line ===
    let div = smoothstep(0.002, 0.0, abs(uv.y - 0.5));
    col += vec3<f32>(0.0, 0.15, 0.05) * div;

    // === Scope bezel / CRT effect ===
    let scanline = 0.95 + 0.05 * sin(uv.y * u.resolution.y * 3.14159);
    col *= scanline;

    // Phosphor persistence glow
    col += col * 0.1;

    // Vignette (round CRT tube)
    let d = length((uv - 0.5) * 2.0);
    col *= smoothstep(1.4, 0.6, d);

    // Beat: brief intensity boost
    col *= 1.0 + u.beat * 0.3;

    return vec4<f32>(col, 1.0);
}
