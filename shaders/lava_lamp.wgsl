// Lava Lamp — soft metaball blobs that rise, merge, and split.
// Mostly self-driven; audio gently modulates color warmth and blob size.
// Beat adds a subtle heat pulse from below.

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

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let uv = in.uv;
    let aspect = u.resolution.x / u.resolution.y;
    // Coordinate system: x centered, y 0..1 (bottom to top)
    let p = vec2<f32>((uv.x - 0.5) * aspect, uv.y);

    // Slow time — lava lamps are meditative
    let t = u.time * 0.15;

    // === Metaball field ===
    var field = 0.0;
    var color_accum = vec3<f32>(0.0);
    let num_blobs = 10;

    for (var i = 0; i < num_blobs; i++) {
        let id = f32(i);

        // Each blob has its own slow orbit
        let phase = hash(id) * 6.283;
        let freq_x = 0.1 + hash(id + 1.0) * 0.15;
        let amp_x = 0.08 + hash(id + 3.0) * 0.1;
        let bx = sin(t * freq_x + phase) * amp_x;

        // Rise slowly, wrap around — the core lava lamp motion
        let rise_speed = 0.03 + hash(id + 4.0) * 0.05;
        let by = fract(t * rise_speed + hash(id + 5.0));
        // Slight wobble
        let wobble = sin(t * 0.2 + phase * 2.0) * 0.03;

        let bp = vec2<f32>(bx, by + wobble);

        // Blob radius: large, soft — audio gently inflates
        let base_r = 0.08 + hash(id + 6.0) * 0.06;
        let r = base_r + u.bass * 0.015;

        let d = length(p - bp);
        let influence = (r * r) / (d * d + 0.0005);

        field += influence;

        // Per-blob warm color
        let blob_col = lava_palette(hash(id + 7.0), u.mid * 0.3, u.time);
        color_accum += blob_col * influence;
    }

    color_accum /= max(field, 0.01);

    // Soft metaball threshold — big gooey shapes
    let threshold = 0.8;
    let blob_shape = smoothstep(threshold - 0.2, threshold + 0.05, field);
    let inner_glow = smoothstep(threshold, threshold + 1.5, field);

    // === Background: warm dark gradient ===
    let bg = mix(vec3<f32>(0.04, 0.01, 0.02), vec3<f32>(0.1, 0.02, 0.04), uv.y);

    // Subtle heat shimmer
    let shimmer = sin(uv.y * 20.0 + u.time * 0.8 + sin(uv.x * 8.0) * 1.5) * 0.005;
    let bg_warm = bg + vec3<f32>(0.02, 0.005, 0.0) * (shimmer + 0.5);

    // === Compose ===
    var col = bg_warm;

    // Blob body
    let body_col = color_accum * (0.6 + inner_glow * 0.4);
    col = mix(col, body_col, blob_shape);

    // Soft outer glow
    let outer_glow = smoothstep(threshold * 0.3, threshold, field);
    col += color_accum * outer_glow * 0.06;

    // Wax highlights near blob centers
    let highlight = smoothstep(threshold + 1.0, threshold + 2.5, field);
    col += vec3<f32>(1.0, 0.9, 0.7) * highlight * 0.2;

    // === Glass tube ===
    let tube_width = aspect * 0.4;
    let tube_dist = abs(p.x) / tube_width;
    let tube_edge = smoothstep(0.7, 1.0, tube_dist);
    col *= 1.0 - tube_edge * 0.7;

    // Top and bottom metal caps
    let cap_top = smoothstep(0.94, 0.98, uv.y);
    let cap_bot = smoothstep(0.06, 0.02, uv.y);
    let cap = max(cap_top, cap_bot);
    col = mix(col, vec3<f32>(0.12, 0.06, 0.03), cap * 0.85);

    // Glass reflection line
    let refl_x = abs(p.x + 0.1);
    let reflection = smoothstep(0.008, 0.0, refl_x) * 0.04 * (1.0 - tube_edge) * (1.0 - cap);
    col += vec3<f32>(1.0);
    col = col - vec3<f32>(1.0) + vec3<f32>(reflection);
    // Simpler:
    col = mix(col - vec3<f32>(reflection), col, 1.0);

    // Beat: gentle warm pulse from base
    col += vec3<f32>(0.15, 0.05, 0.0) * u.beat * 0.2 * smoothstep(0.4, 0.0, uv.y);

    return vec4<f32>(col, 1.0);
}

fn lava_palette(hue_base: f32, mid: f32, time: f32) -> vec3<f32> {
    let hue = fract(hue_base * 0.3 + time * 0.008 + mid * 0.1);
    let t = hue * 4.0;

    var col: vec3<f32>;
    if t < 1.0 {
        col = mix(vec3<f32>(0.6, 0.05, 0.02), vec3<f32>(0.9, 0.3, 0.02), t);
    } else if t < 2.0 {
        col = mix(vec3<f32>(0.9, 0.3, 0.02), vec3<f32>(0.95, 0.65, 0.1), t - 1.0);
    } else if t < 3.0 {
        col = mix(vec3<f32>(0.95, 0.65, 0.1), vec3<f32>(0.7, 0.1, 0.25), t - 2.0);
    } else {
        col = mix(vec3<f32>(0.7, 0.1, 0.25), vec3<f32>(0.6, 0.05, 0.02), t - 3.0);
    }

    return col;
}
