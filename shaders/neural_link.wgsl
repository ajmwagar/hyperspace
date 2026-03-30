// Neural Link — two chrome mannequin busts connected by a sine wave energy bridge.
// Infinite checkerboard floor, volumetric light, CRT post-processing.
// Blade Runner / retrowave aesthetic.

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

// ============================================================
// SDF primitives
// ============================================================

fn sd_ellipsoid(p: vec3<f32>, r: vec3<f32>) -> f32 {
    let k0 = length(p / r);
    let k1 = length(p / (r * r));
    return k0 * (k0 - 1.0) / k1;
}

fn sd_capsule(p: vec3<f32>, a: vec3<f32>, b: vec3<f32>, r: f32) -> f32 {
    let ab = b - a;
    let ap = p - a;
    let t = clamp(dot(ap, ab) / dot(ab, ab), 0.0, 1.0);
    return length(p - a - ab * t) - r;
}

fn op_smooth_union(d1: f32, d2: f32, k: f32) -> f32 {
    let h = clamp(0.5 + 0.5 * (d2 - d1) / k, 0.0, 1.0);
    return mix(d2, d1, h) - k * h * (1.0 - h);
}

// ============================================================
// Mannequin bust SDF
// ============================================================

fn bust_sdf(p: vec3<f32>) -> f32 {
    // Cranium — elongated ellipsoid
    let head = sd_ellipsoid(p - vec3<f32>(0.0, 0.35, 0.0), vec3<f32>(0.18, 0.22, 0.2));

    // Neck — thin capsule
    let neck = sd_capsule(p, vec3<f32>(0.0, 0.0, 0.0), vec3<f32>(0.0, 0.18, 0.0), 0.07);

    // Shoulders — wide flat ellipsoid
    let shoulders = sd_ellipsoid(p - vec3<f32>(0.0, -0.05, 0.0), vec3<f32>(0.35, 0.1, 0.15));

    // Jaw definition — small sphere subtracted from lower head
    let jaw = sd_ellipsoid(p - vec3<f32>(0.0, 0.22, 0.08), vec3<f32>(0.12, 0.08, 0.1));

    var d = op_smooth_union(head, neck, 0.08);
    d = op_smooth_union(d, shoulders, 0.06);
    d = op_smooth_union(d, jaw, 0.05);

    // Cut off below shoulders
    let cutoff = p.y + 0.1;
    d = max(d, -cutoff);

    return d;
}

fn scene_sdf(p: vec3<f32>) -> f32 {
    // Left bust (facing right)
    let p_left = vec3<f32>(p.x + 0.45, p.y, p.z);
    let left = bust_sdf(p_left);

    // Right bust (facing left, mirrored)
    let p_right = vec3<f32>(-(p.x - 0.45), p.y, p.z);
    let right = bust_sdf(p_right);

    return min(left, right);
}

fn calc_normal(p: vec3<f32>) -> vec3<f32> {
    let e = vec2<f32>(0.001, 0.0);
    return normalize(vec3<f32>(
        scene_sdf(p + e.xyy) - scene_sdf(p - e.xyy),
        scene_sdf(p + e.yxy) - scene_sdf(p - e.yxy),
        scene_sdf(p + e.yyx) - scene_sdf(p - e.yyx)
    ));
}

// ============================================================
// Raymarching
// ============================================================

struct HitResult {
    dist: f32,
    hit: bool,
    steps: i32,
};

fn raymarch(ro: vec3<f32>, rd: vec3<f32>) -> HitResult {
    var t = 0.0;
    var result: HitResult;
    result.hit = false;

    for (var i = 0; i < 48; i++) {
        let p = ro + rd * t;
        let d = scene_sdf(p);
        if d < 0.001 {
            result.hit = true;
            result.dist = t;
            result.steps = i;
            return result;
        }
        if t > 5.0 { break; }
        t += d;
    }
    result.dist = t;
    return result;
}

// ============================================================
// Fragment shader
// ============================================================

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let uv = in.uv;
    let aspect = u.resolution.x / u.resolution.y;
    let p = vec2<f32>((uv.x - 0.5) * aspect, uv.y - 0.5);

    // ========== 1. Background sky ==========
    let sky_bottom = vec3<f32>(0.04, 0.10, 0.12);
    let sky_top = vec3<f32>(0.10, 0.23, 0.25);
    var col = mix(sky_bottom, sky_top, uv.y);

    // Nebula bright spot at top center
    let nebula_dist = length(vec2<f32>(p.x, p.y - 0.35));
    col += vec3<f32>(0.12, 0.25, 0.28) * exp(-nebula_dist * nebula_dist * 8.0) * 0.4;

    // ========== 2. Volumetric light cone ==========
    let cone_width = 0.3 + (0.5 - uv.y) * 0.6;
    let cone = smoothstep(cone_width, 0.0, abs(p.x)) * smoothstep(0.0, 0.4, uv.y - 0.5);
    col += vec3<f32>(0.08, 0.15, 0.18) * cone * 0.15;

    // ========== 3. Infinite checkerboard floor ==========
    let horizon = 0.38;
    if uv.y < horizon {
        let floor_y = horizon - uv.y;
        let depth = 0.15 / (floor_y + 0.001);
        let floor_x = p.x * depth;
        let floor_z = depth + u.time * (0.5 + u.amplitude * 0.3);

        let scale = 1.5;
        let cx = floor(floor_x * scale);
        let cz = floor(floor_z * scale);
        let checker = ((i32(cx) + i32(cz)) % 2 + 2) % 2;

        let pink = vec3<f32>(0.77, 0.42, 0.48);
        let dark = vec3<f32>(0.05, 0.05, 0.05);
        let floor_col = select(dark, pink, checker == 0);

        // Distance fog
        let fog = exp(-floor_y * 2.5);
        let fogged = mix(floor_col, col, fog);
        col = fogged;
    }

    // ========== 4. Mannequin busts (raymarched) ==========
    let cam_pos = vec3<f32>(0.0, 0.25, 1.2);
    let cam_target = vec3<f32>(0.0, 0.2, 0.0);
    let cam_fwd = normalize(cam_target - cam_pos);
    let cam_right = normalize(cross(cam_fwd, vec3<f32>(0.0, 1.0, 0.0)));
    let cam_up = cross(cam_right, cam_fwd);

    let screen_p = vec2<f32>((uv.x - 0.5) * aspect, uv.y - 0.45);
    let rd = normalize(cam_fwd * 1.5 + cam_right * screen_p.x + cam_up * screen_p.y);

    let hit = raymarch(cam_pos, rd);
    if hit.hit {
        let hit_p = cam_pos + rd * hit.dist;
        let normal = calc_normal(hit_p);
        let view_dir = normalize(cam_pos - hit_p);

        // Chrome base color (very dark)
        let base_color = vec3<f32>(0.08, 0.08, 0.1);

        // Fresnel rim lighting
        let fresnel = pow(1.0 - max(dot(normal, view_dir), 0.0), 4.0);
        let rim_pulse = 1.0 + u.beat * 0.6;

        // Left bust: cyan rim on left edge
        var rim_color = vec3<f32>(0.0, 0.9, 1.0); // cyan
        if hit_p.x > 0.0 {
            rim_color = vec3<f32>(1.0, 0.24, 0.54); // pink for right bust
        }

        // Specular highlight
        let light_dir = normalize(vec3<f32>(0.0, 1.0, 0.8));
        let half_v = normalize(light_dir + view_dir);
        let spec = pow(max(dot(normal, half_v), 0.0), 64.0) * 0.5;

        let bust_col = base_color + rim_color * fresnel * rim_pulse * 0.7 + vec3<f32>(spec);

        // Composite bust over background
        col = bust_col;
    }

    // ========== 5. Sine wave energy bridge ==========
    // Bridge spans between the two foreheads
    let bridge_left = vec2<f32>(-0.25, 0.12);
    let bridge_right = vec2<f32>(0.25, 0.12);

    // Only draw between the heads
    let bridge_t = (p.x - bridge_left.x) / (bridge_right.x - bridge_left.x);
    if bridge_t > -0.05 && bridge_t < 1.05 {
        let bridge_y = bridge_left.y;
        let wave_amp = 0.04 + u.bass * 0.03;
        let wave_freq = 4.0;
        let wave_speed = 2.0 + u.mid * 2.0;

        let wave_y = bridge_y + sin(p.x * 6.28318 * wave_freq + u.time * wave_speed) * wave_amp;
        let dist_to_wave = abs(p.y - wave_y);

        // Thickness and glow
        let thickness = 0.006;
        let wave_core = smoothstep(thickness, 0.0, dist_to_wave);
        let wave_glow = exp(-dist_to_wave * dist_to_wave * 3000.0) * 0.5;

        // Color gradient: pink on left → orange on right
        let pink = vec3<f32>(1.0, 0.18, 0.48);
        let orange = vec3<f32>(1.0, 0.54, 0.18);
        let wave_color = mix(pink, orange, clamp(bridge_t, 0.0, 1.0));

        // Fade at edges (near the heads)
        let edge_fade = smoothstep(-0.05, 0.1, bridge_t) * smoothstep(1.05, 0.9, bridge_t);

        col += wave_color * (wave_core + wave_glow) * edge_fade * (0.8 + u.amplitude * 0.5);

        // White flares at endpoints
        let flare_l = exp(-length(p - bridge_left) * 20.0) * 0.7;
        let flare_r = exp(-length(p - bridge_right) * 20.0) * 0.7;
        col += vec3<f32>(1.0, 0.95, 0.9) * (flare_l + flare_r) * (0.5 + u.beat * 0.5);
    }

    // ========== 6. Post-processing ==========

    // Scanlines
    let scanline = 0.92 + 0.08 * sin(uv.y * u.resolution.y * 3.14159);
    col *= scanline;

    // Chromatic aberration
    let ca_offset = 0.002;
    // Approximate by shifting color channels
    let ca_r = uv.x + ca_offset;
    let ca_b = uv.x - ca_offset;
    // Subtle color shift at edges
    let edge_dist = abs(uv.x - 0.5) * 2.0;
    col.r *= 1.0 + edge_dist * ca_offset * 10.0;
    col.b *= 1.0 - edge_dist * ca_offset * 10.0;

    // Vignette
    let vig_dist = length(uv - 0.5) * 1.4;
    col *= 1.0 - 0.4 * pow(vig_dist, 2.4);

    // Color grading: teal shadows, warm highlights
    let luma = dot(col, vec3<f32>(0.299, 0.587, 0.114));
    let shadow_tint = vec3<f32>(0.05, 0.1, 0.12);
    let highlight_tint = vec3<f32>(0.05, 0.02, 0.0);
    col += shadow_tint * (1.0 - luma) * 0.15;
    col += highlight_tint * luma * 0.1;

    return vec4<f32>(col, 1.0);
}
