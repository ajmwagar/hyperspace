// Lava Lamp — soft metaball blobs that rise, merge, and split.
// Bass inflates blobs, mids shift the color palette, amplitude drives
// the convection speed. Beat spawns a burst of new blobs from below.
// Warm, gooey, hypnotic.

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

// Smooth blob position — each blob orbits a unique path
fn blob_pos(id: f32, t: f32) -> vec2<f32> {
    let phase = hash(id) * 6.283;
    let freq_x = 0.2 + hash(id + 1.0) * 0.3;
    let freq_y = 0.15 + hash(id + 2.0) * 0.2;
    let amp_x = 0.15 + hash(id + 3.0) * 0.2;

    let x = sin(t * freq_x + phase) * amp_x;
    // Blobs drift upward with time, wrapping around
    let rise_speed = 0.08 + hash(id + 4.0) * 0.12;
    let y_base = fract(t * rise_speed + hash(id + 5.0)) * 2.4 - 0.7;
    let y = y_base + sin(t * freq_y + phase * 2.0) * 0.1;

    return vec2<f32>(x, y);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let uv = in.uv;
    let aspect = u.resolution.x / u.resolution.y;
    let p = vec2<f32>((uv.x - 0.5) * aspect, uv.y - 0.5);

    let t = u.time * (0.4 + u.amplitude * 0.8);

    // === Metaball field ===
    // Sum of inverse-distance fields from each blob
    var field = 0.0;
    var color_accum = vec3<f32>(0.0);
    let num_blobs = 12;

    for (var i = 0; i < num_blobs; i++) {
        let id = f32(i);
        var bp = blob_pos(id, t);

        // Beat: push blobs upward suddenly
        bp.y += u.beat * 0.15 * hash(id + 10.0);

        // Bass inflates blob radius
        let base_radius = 0.06 + hash(id + 6.0) * 0.05;
        let radius = base_radius + u.bass * 0.04;

        let d = length(p - bp);
        let influence = (radius * radius) / (d * d + 0.001);

        field += influence;

        // Per-blob color contribution (weighted by influence)
        let hue_base = hash(id + 7.0);
        let blob_col = lava_palette(hue_base, u.mid, u.time);
        color_accum += blob_col * influence;
    }

    // Normalize color by total field
    color_accum /= max(field, 0.01);

    // Metaball threshold: sharp-ish edge with soft glow
    let threshold = 1.0 + u.amplitude * 0.5;
    let blob_shape = smoothstep(threshold - 0.3, threshold + 0.1, field);

    // Inner glow: brighter near blob centers
    let inner_glow = smoothstep(threshold, threshold + 2.0, field);

    // === Background: warm gradient ===
    let bg_top = vec3<f32>(0.12, 0.02, 0.05);
    let bg_bot = vec3<f32>(0.05, 0.01, 0.02);
    let bg = mix(bg_bot, bg_top, uv.y);

    // Subtle heat shimmer in background
    let shimmer = sin(uv.y * 30.0 + u.time * 1.5 + sin(uv.x * 10.0) * 2.0) * 0.01;
    let bg_warm = bg + vec3<f32>(0.03, 0.01, 0.0) * (shimmer + 0.5) * u.amplitude;

    // === Compose ===
    var col = bg_warm;

    // Blob body
    let body_col = color_accum * (0.7 + inner_glow * 0.5);
    col = mix(col, body_col, blob_shape);

    // Soft outer glow around blobs
    let outer_glow = smoothstep(threshold * 0.4, threshold, field);
    col += color_accum * outer_glow * 0.08;

    // === Wax drip highlights ===
    let highlight = smoothstep(threshold + 1.5, threshold + 3.0, field);
    col += vec3<f32>(1.0, 0.95, 0.8) * highlight * 0.25;

    // === Glass tube edge darkening ===
    let tube_dist = abs(p.x) / (aspect * 0.35);
    let tube_edge = smoothstep(0.7, 1.0, tube_dist);
    col *= 1.0 - tube_edge * 0.6;

    // Top and bottom caps
    let cap_top = smoothstep(0.48, 0.5, uv.y);
    let cap_bot = smoothstep(0.02, 0.0, uv.y);
    col *= (1.0 - cap_top) * (1.0 - cap_bot);
    // Cap color
    col = mix(col, vec3<f32>(0.15, 0.08, 0.04), cap_top * 0.8 + cap_bot * 0.8);

    // === Subtle glass reflection ===
    let refl_x = abs(p.x + 0.12);
    let reflection = smoothstep(0.01, 0.0, refl_x) * 0.06 * (1.0 - tube_edge);
    col += vec3<f32>(1.0, 1.0, 1.0) * reflection;

    // Beat: warm flash at base
    col += vec3<f32>(0.3, 0.1, 0.0) * u.beat * 0.3 * smoothstep(0.3, 0.0, uv.y);

    return vec4<f32>(col, 1.0);
}

fn lava_palette(hue_base: f32, mid: f32, time: f32) -> vec3<f32> {
    // Warm palette: oranges, reds, yellows, purples
    // Mid audio shifts the palette cooler/warmer
    let hue = fract(hue_base * 0.3 + time * 0.02 + mid * 0.2);
    let t = hue * 4.0;

    var col: vec3<f32>;
    if t < 1.0 {
        // Deep red → orange
        col = mix(vec3<f32>(0.6, 0.05, 0.02), vec3<f32>(0.9, 0.3, 0.02), t);
    } else if t < 2.0 {
        // Orange → yellow
        col = mix(vec3<f32>(0.9, 0.3, 0.02), vec3<f32>(0.95, 0.7, 0.1), t - 1.0);
    } else if t < 3.0 {
        // Yellow → magenta
        col = mix(vec3<f32>(0.95, 0.7, 0.1), vec3<f32>(0.7, 0.1, 0.3), t - 2.0);
    } else {
        // Magenta → deep red
        col = mix(vec3<f32>(0.7, 0.1, 0.3), vec3<f32>(0.6, 0.05, 0.02), t - 3.0);
    }

    return col;
}
