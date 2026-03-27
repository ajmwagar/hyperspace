// Hyperdrive — Star Wars lightspeed jump. Stars streak from center outward,
// elongating into light trails. Bass punches the acceleration, beat triggers
// the jump flash. Spectrum data seeds star positions.

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

fn hash21(p: vec2<f32>) -> f32 {
    var p3 = fract(p * vec2<f32>(443.897, 441.423));
    p3 += dot(p3, p3 + 19.19);
    return fract(p3.x * p3.y);
}

fn hash22(p: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(hash21(p), hash21(p + 47.33));
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let uv = (in.uv - 0.5) * 2.0;
    let aspect = u.resolution.x / u.resolution.y;
    let p = vec2<f32>(uv.x * aspect, uv.y);

    var col = vec3<f32>(0.0);

    // Warp speed factor: bass drives acceleration
    let speed = 2.0 + u.bass * 8.0 + u.amplitude * 4.0;
    let streak_len = 0.05 + u.bass * 0.4 + u.amplitude * 0.2;

    // Multiple star layers for depth
    for (var layer = 0u; layer < 4u; layer++) {
        let layer_f = f32(layer);
        let layer_speed = speed * (0.5 + layer_f * 0.4);
        let layer_bright = 1.0 - layer_f * 0.15;
        let num_stars = 80.0 + layer_f * 40.0;

        for (var i = 0u; i < 120u; i++) {
            if f32(i) >= num_stars { break; }

            let seed = vec2<f32>(f32(i) + 0.5, layer_f * 100.0 + 0.5);
            let star_pos = hash22(seed) * 2.0 - 1.0;
            let star_pos_a = vec2<f32>(star_pos.x * aspect * 1.5, star_pos.y * 1.5);

            // Star moves radially outward from center
            let dir = normalize(star_pos_a);
            let base_dist = length(star_pos_a);

            // Cycle: star starts near center, flies outward, wraps
            let cycle = fract(base_dist * 0.5 + u.time * layer_speed * 0.3 + hash21(seed) * 10.0);
            let dist = cycle * 2.0;

            let cur_pos = dir * dist;

            // Streak: line from cur_pos toward center
            let streak_dir = -dir;
            let streak_length = streak_len * dist * (0.5 + layer_f * 0.3);

            // Distance from p to the streak line segment
            let to_p = p - cur_pos;
            let along = clamp(dot(to_p, streak_dir) / (streak_length + 0.001), 0.0, 1.0);
            let closest = cur_pos + streak_dir * along * streak_length;
            let d = length(p - closest);

            // Star width thins with distance from center, thickens with amplitude
            let width = 0.002 + 0.001 * layer_f + u.amplitude * 0.002;
            let star = smoothstep(width, 0.0, d);

            // Brightness: brighter further out, fades at edges
            let brightness = star * smoothstep(0.0, 0.3, dist) * smoothstep(2.2, 1.5, dist) * layer_bright;

            // Color: white-blue core, slightly warm at tips
            let core_color = vec3<f32>(0.8, 0.85, 1.0);
            let tip_color = vec3<f32>(0.6, 0.7, 1.0);
            let star_col = mix(tip_color, core_color, along);

            col += star_col * brightness * 0.7;
        }
    }

    // Central glow — always present, intensifies with speed
    let center_dist = length(p);
    let core_glow = exp(-center_dist * 3.0) * (0.1 + u.amplitude * 0.4);
    col += vec3<f32>(0.6, 0.7, 1.0) * core_glow;

    // Radial light streaks from center (subtle)
    let angle = atan2(p.y, p.x);
    let radial = abs(sin(angle * 8.0 + u.time * 0.5)) * exp(-center_dist * 2.0);
    col += vec3<f32>(0.3, 0.4, 0.8) * radial * 0.05 * (1.0 + u.bass * 3.0);

    // Beat: jump flash — bright white pulse from center
    if u.beat > 0.5 {
        let flash = exp(-center_dist * 1.5) * u.beat;
        col += vec3<f32>(1.0, 0.95, 0.9) * flash * 0.8;
    }

    // Subtle blue fog at edges
    let fog = smoothstep(0.5, 2.0, center_dist) * 0.03;
    col += vec3<f32>(0.1, 0.1, 0.3) * fog;

    // Vignette
    let vig = 1.0 - center_dist * 0.2;
    col *= max(vig, 0.0);

    return vec4<f32>(col, 1.0);
}
