// Acid Pools — Voronoi-based liquid pools that bubble and merge.
// Each cell is a pool of acid color that reacts to different bands.
// Bass makes pools expand, mid shifts their hue, onset makes them pop.

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

fn hash2(p: vec2<f32>) -> vec2<f32> {
    let p2 = vec2<f32>(dot(p, vec2<f32>(127.1, 311.7)), dot(p, vec2<f32>(269.5, 183.3)));
    return fract(sin(p2) * 43758.5453);
}

// Animated Voronoi — cells move over time
fn voronoi(p: vec2<f32>, t: f32) -> vec3<f32> {
    let n = floor(p);
    let f = fract(p);

    var min_dist = 8.0;
    var min_dist2 = 8.0;
    var min_cell = vec2<f32>(0.0);

    for (var j = -1; j <= 1; j++) {
        for (var i = -1; i <= 1; i++) {
            let g = vec2<f32>(f32(i), f32(j));
            let o = hash2(n + g);
            // Animate cell centers
            let center = g + 0.5 + 0.4 * sin(t * 0.5 + o * 6.283);
            let d = length(f - center);

            if d < min_dist {
                min_dist2 = min_dist;
                min_dist = d;
                min_cell = n + g;
            } else if d < min_dist2 {
                min_dist2 = d;
            }
        }
    }

    // Return: (distance to nearest, distance to second nearest, cell ID hash)
    return vec3<f32>(min_dist, min_dist2, hash2(min_cell).x);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let uv = in.uv;
    let aspect = u.resolution.x / u.resolution.y;
    let p = vec2<f32>((uv.x - 0.5) * aspect, uv.y - 0.5) * 2.0;
    let t = u.time;

    // Scale: bass makes cells larger (fewer, bigger pools)
    let scale = 4.0 - u.bass * 1.0;

    // Multi-layer Voronoi at different scales
    let v1 = voronoi(p * scale, t);
    let v2 = voronoi(p * scale * 2.0 + 10.0, t * 1.3);

    // Pool shape: smooth inner region
    let pool_edge = smoothstep(0.0, 0.15 + u.amplitude * 0.1, v1.x);
    let pool_inner = 1.0 - pool_edge;

    // Cell boundary — the "membrane" between pools
    let edge_dist = v1.y - v1.x;
    let membrane = smoothstep(0.0, 0.04 + u.presence * 0.02, edge_dist);
    let membrane_line = (1.0 - membrane) * 0.8;

    // Color per cell based on its hash + audio
    let cell_hue = fract(v1.z + t * 0.02 + u.mid * 0.3);
    let cell_col = acid_hsv(cell_hue, 0.8 + u.amplitude * 0.2, 0.7 + u.bass * 0.3);

    // Second layer: subtle detail
    let detail_hue = fract(v2.z + t * 0.03 + u.high * 0.2);
    let detail = acid_hsv(detail_hue, 0.6, 0.3) * (1.0 - smoothstep(0.0, 0.2, v2.x));

    // Background: very dark with sub-bass glow
    var col = vec3<f32>(0.01, 0.01, 0.02);
    col += vec3<f32>(0.05, 0.0, 0.08) * u.sub_bass * 0.5;

    // Pool interiors
    col = mix(col, cell_col, pool_inner * 0.8);

    // Detail layer
    col += detail * 0.3 * pool_inner;

    // Membrane edges — bright neon
    let membrane_col = acid_hsv(fract(cell_hue + 0.5), 1.0, 1.0);
    col += membrane_col * membrane_line * (0.3 + u.onset * 0.5);

    // Bubbles: onset makes cells "pop" with brightness
    let pop = smoothstep(0.3, 0.8, u.onset) * pool_inner;
    col += vec3<f32>(0.5, 0.5, 0.3) * pop * 0.3;

    // Beat pulse
    col *= 1.0 + u.beat * 0.1;

    // Inner glow per pool
    let inner_glow = exp(-v1.x * 6.0) * pool_inner * u.amplitude * 0.3;
    col += cell_col * inner_glow;

    // Scanlines for CRT feel
    let scan = 0.95 + 0.05 * sin(uv.y * u.resolution.y * 3.14159);
    col *= scan;

    // Vignette
    let d = length(uv - 0.5) * 1.5;
    col *= 1.0 - d * d * 0.3;

    return vec4<f32>(col, 1.0);
}

fn acid_hsv(h: f32, s: f32, v: f32) -> vec3<f32> {
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
