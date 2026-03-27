// Cyberpunk — digital rain, glitch blocks, circuit traces, neon haze.
// Bass drives glitch intensity, mids color the neon wash, highs spark
// the circuit traces. Beat triggers full-screen glitch disruption.

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

fn hash(p: f32) -> f32 {
    return fract(sin(p * 127.1) * 43758.5453);
}

fn hash2(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}

fn char_glyph(cell: vec2<f32>, local: vec2<f32>, t: f32) -> f32 {
    // Fake character: random dots in a 3x5 grid per cell
    let seed = hash2(cell + floor(t * 4.0) * 0.01);
    let gx = floor(local.x * 3.0);
    let gy = floor(local.y * 5.0);
    let bit = hash(seed * 100.0 + gx * 7.0 + gy * 13.0);
    let on = step(0.45, bit);
    // Smooth edges within pixel
    let fx = fract(local.x * 3.0);
    let fy = fract(local.y * 5.0);
    let edge = smoothstep(0.0, 0.15, fx) * smoothstep(1.0, 0.85, fx)
             * smoothstep(0.0, 0.15, fy) * smoothstep(1.0, 0.85, fy);
    return on * edge;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    var uv = in.uv;
    let aspect = u.resolution.x / u.resolution.y;

    // === Glitch displacement (beat + bass driven) ===
    let glitch_intensity = u.bass * 0.3 + u.beat * 0.5;
    let glitch_band = floor(uv.y * 30.0);
    let glitch_seed = hash(glitch_band + floor(u.time * 12.0));
    if glitch_seed > (1.0 - glitch_intensity) {
        let offset = (hash(glitch_band * 7.0 + u.time) - 0.5) * 0.08 * glitch_intensity;
        uv.x += offset;
    }

    // === RGB split on beat ===
    let split = u.beat * 0.01;

    var col = vec3<f32>(0.0);

    // Background: deep dark blue-black
    col = vec3<f32>(0.01, 0.01, 0.03);

    // === Digital rain columns ===
    let rain_cols = 60.0;
    let rain_cell_w = 1.0 / rain_cols;
    let rain_col_idx = floor(uv.x * rain_cols);
    let rain_local_x = fract(uv.x * rain_cols);

    // Each column has its own speed and character
    let col_seed = hash(rain_col_idx);
    let col_speed = 0.3 + col_seed * 0.7 + u.amplitude * 0.5;
    let col_offset = col_seed * 20.0;

    let rain_y = fract(uv.y + u.time * col_speed + col_offset);
    let rain_cell_h = 1.0 / 40.0;
    let rain_row = floor(rain_y / rain_cell_h);
    let rain_local_y = fract(rain_y / rain_cell_h);

    let cell = vec2<f32>(rain_col_idx, rain_row);
    let glyph = char_glyph(cell, vec2<f32>(rain_local_x, rain_local_y), u.time + col_seed * 100.0);

    // Fade: bright at top of stream, fading down
    let stream_len = 8.0 + col_seed * 12.0;
    let head_pos = fract(u.time * col_speed * 0.1 + col_seed * 5.0);
    let dist_from_head = fract(rain_y - head_pos);
    let fade = smoothstep(stream_len / 40.0, 0.0, dist_from_head);

    // Color: green with white-hot head
    let head_bright = smoothstep(0.02, 0.0, dist_from_head);
    let rain_color = mix(
        vec3<f32>(0.0, 0.8, 0.3),  // green body
        vec3<f32>(0.8, 1.0, 0.9),  // white head
        head_bright
    );

    // Spectrum modulates column brightness
    let spec_idx = u32(rain_col_idx * 512.0 / rain_cols);
    var spec_boost = 0.0;
    if spec_idx < 512u {
        spec_boost = spectrum[spec_idx] * 8.0;
    }

    col += rain_color * glyph * fade * (0.3 + spec_boost);

    // === Circuit traces ===
    let circuit_scale = 15.0;
    let cp = uv * circuit_scale;
    let ci = floor(cp);
    let cf = fract(cp);

    // Horizontal and vertical traces
    let h_trace = smoothstep(0.03, 0.0, abs(cf.y - 0.5)) * step(0.5, hash2(ci));
    let v_trace = smoothstep(0.03, 0.0, abs(cf.x - 0.5)) * step(0.6, hash2(ci + 100.0));
    let trace = (h_trace + v_trace) * u.high * 2.0;

    // Circuit nodes at intersections
    let node_dist = length(cf - 0.5);
    let node = smoothstep(0.08, 0.03, node_dist) * step(0.7, hash2(ci + 200.0));

    // Pulse along traces
    let pulse = sin(ci.x * 3.0 + ci.y * 2.0 - u.time * 4.0) * 0.5 + 0.5;

    let circuit_col = vec3<f32>(0.0, 0.5, 1.0) * trace * pulse * 0.15
                    + vec3<f32>(1.0, 0.3, 0.5) * node * 0.3;
    col += circuit_col;

    // === Neon haze / fog ===
    let haze_y = sin(uv.y * 3.0 + u.time * 0.5) * 0.5 + 0.5;
    let haze = exp(-abs(uv.y - 0.5) * 4.0) * 0.04;
    let neon_hue = u.mid;
    let haze_col = mix(
        vec3<f32>(1.0, 0.0, 0.5),  // hot pink
        vec3<f32>(0.0, 0.8, 1.0),  // cyan
        neon_hue
    );
    col += haze_col * haze * (1.0 + u.amplitude * 3.0);

    // === Horizontal glitch bars ===
    let bar_y = hash(floor(uv.y * 80.0) + floor(u.time * 8.0));
    if bar_y > 0.97 && u.beat > 0.3 {
        let bar_col = mix(
            vec3<f32>(1.0, 0.0, 0.4),
            vec3<f32>(0.0, 1.0, 0.8),
            hash(floor(uv.y * 80.0))
        );
        col = mix(col, bar_col, 0.6 * u.beat);
    }

    // === Scanlines ===
    let scan = 0.93 + 0.07 * sin(uv.y * u.resolution.y * 1.5);
    col *= scan;

    // === RGB chromatic split ===
    if split > 0.001 {
        let r_sample = uv.x + split;
        let b_sample = uv.x - split;
        // Approximate by shifting color channels
        col.r *= 1.0 + (hash(floor(r_sample * rain_cols)) - 0.5) * split * 20.0;
        col.b *= 1.0 + (hash(floor(b_sample * rain_cols)) - 0.5) * split * 20.0;
    }

    // Vignette — darker at edges
    let d = length((uv - 0.5) * 1.8);
    col *= 1.0 - d * d * 0.4;

    return vec4<f32>(col, 1.0);
}
