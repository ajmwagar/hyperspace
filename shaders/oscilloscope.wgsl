// Oscilloscope — real waveform display with green CRT phosphor.
// Top: L+R combined waveform (time domain).
// Bottom: Lissajous XY mode (L=X, R=Y).
// Buffer layout: [0..512) spectrum, [512..1024) waveform L, [1024..1536) waveform R

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

fn get_waveform_l(idx: u32) -> f32 {
    if idx < 512u { return audio_buf[512u + idx]; }
    return 0.0;
}

fn get_waveform_r(idx: u32) -> f32 {
    if idx < 512u { return audio_buf[1024u + idx]; }
    return 0.0;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let uv = in.uv;

    // Dark scope background
    var col = vec3<f32>(0.008, 0.015, 0.008);

    // === Graticule grid ===
    let grid_spacing = 0.1;
    let gx = abs(fract(uv.x / grid_spacing + 0.5) - 0.5);
    let gy = abs(fract(uv.y / grid_spacing + 0.5) - 0.5);
    let grid_line = smoothstep(0.003, 0.0, gx) + smoothstep(0.003, 0.0, gy);
    col += vec3<f32>(0.0, 0.04, 0.015) * grid_line;

    // Center cross
    let cx = smoothstep(0.002, 0.0, abs(uv.x - 0.5));
    let cy = smoothstep(0.002, 0.0, abs(uv.y - 0.5));
    col += vec3<f32>(0.0, 0.07, 0.025) * (cx + cy);

    let phosphor_green = vec3<f32>(0.2, 1.0, 0.3);
    let phosphor_blue = vec3<f32>(0.15, 0.5, 1.0);

    // === Upper half: time-domain waveform ===
    if uv.y > 0.52 {
        // Map x position to sample index
        let sample_x = uv.x;
        let idx_f = sample_x * 511.0;
        let idx0 = u32(floor(idx_f));
        let idx1 = min(idx0 + 1u, 511u);
        let frac = fract(idx_f);

        // Interpolate L waveform
        let sl0 = get_waveform_l(idx0);
        let sl1 = get_waveform_l(idx1);
        let sample_l = mix(sl0, sl1, frac);

        // Interpolate R waveform
        let sr0 = get_waveform_r(idx0);
        let sr1 = get_waveform_r(idx1);
        let sample_r = mix(sr0, sr1, frac);

        // L trace: upper portion
        let trace_center_l = 0.78;
        let wave_y_l = trace_center_l + sample_l * 0.18;
        let dist_l = abs(uv.y - wave_y_l);
        let trace_l = smoothstep(0.004, 0.0, dist_l);
        let bloom_l = exp(-dist_l * dist_l * 15000.0) * 0.4;
        col += phosphor_green * (trace_l + bloom_l) * 0.9;

        // R trace: lower portion
        let trace_center_r = 0.62;
        let wave_y_r = trace_center_r + sample_r * 0.18;
        let dist_r = abs(uv.y - wave_y_r);
        let trace_r = smoothstep(0.004, 0.0, dist_r);
        let bloom_r = exp(-dist_r * dist_r * 15000.0) * 0.4;
        col += phosphor_blue * (trace_r + bloom_r) * 0.7;

        // Channel labels (static lines at center)
        let label_l = smoothstep(0.001, 0.0, abs(uv.y - trace_center_l)) * 0.03;
        let label_r = smoothstep(0.001, 0.0, abs(uv.y - trace_center_r)) * 0.03;
        col += phosphor_green * label_l;
        col += phosphor_blue * label_r;
    }

    // === Lower half: Lissajous XY ===
    if uv.y < 0.48 {
        let center = vec2<f32>(0.5, 0.24);
        let liss_p = (vec2<f32>(uv.x, uv.y) - center) * 2.5;

        var liss_field = 0.0;
        for (var i = 0u; i < 512u; i++) {
            let sl = get_waveform_l(i);
            let sr = get_waveform_r(i);

            let lx = sl * 0.9;
            let ly = sr * 0.9;

            let d = length(liss_p - vec2<f32>(lx, ly));
            liss_field += exp(-d * d * 2000.0);
        }

        let liss_trace = clamp(liss_field * 0.08, 0.0, 1.0);
        let liss_bloom = clamp(liss_field * 0.015, 0.0, 0.4);
        col += phosphor_green * liss_trace;
        col += vec3<f32>(0.08, 0.3, 0.12) * liss_bloom;
    }

    // === Divider ===
    let div = smoothstep(0.003, 0.0, abs(uv.y - 0.5));
    col += vec3<f32>(0.0, 0.1, 0.04) * div;

    // === CRT effects ===
    let scanline = 0.94 + 0.06 * sin(uv.y * u.resolution.y * 3.14159);
    col *= scanline;

    // Vignette
    let d = length((uv - 0.5) * 2.0);
    col *= smoothstep(1.4, 0.5, d);

    return vec4<f32>(col, 1.0);
}
