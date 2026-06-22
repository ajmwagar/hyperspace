// Plato's Rave — Plato's Cave for the club.
// An audioreactive shape (a spinning, spectrum-driven funnel) is NEVER drawn
// to screen. Instead it only blocks light: all you ever see is its shadow cast
// across the walls and floor of a virtual room. Two coloured club lights throw
// overlapping coloured shadows; the perspective room reads as real 3D depth.
// Bass swells the unseen form, the spectrum sculpts its silhouette, beats flash
// the lights. Inspired by @ojrgb's off-axis shadow-room TouchDesigner work.

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

fn palette(t: f32) -> vec3<f32> {
    let a = vec3<f32>(0.5, 0.5, 0.5);
    let b = vec3<f32>(0.5, 0.5, 0.5);
    let c = vec3<f32>(1.0, 1.0, 1.0);
    let d = vec3<f32>(0.0, 0.33, 0.67);
    return a + b * cos(6.28318 * (c * t + d));
}

fn spec_at(tnorm: f32) -> f32 {
    let bin = u32(clamp(tnorm, 0.0, 1.0) * 220.0);
    if (bin < 512u) {
        return spectrum[bin];
    }
    return 0.0;
}

// SDF of the UNSEEN shape: a twisting, spectrum-sculpted funnel rising from
// the floor. Only ever used for shadow occlusion — never shaded.
fn map_shape(p: vec3<f32>) -> f32 {
    // Sits in the middle of the room so a front key light projects its
    // silhouette cleanly onto the back wall.
    let base = vec2<f32>(0.0, 1.75);
    let t = clamp((p.y + 1.0) / 2.0, 0.0, 1.0);
    // Spiral that widens toward the top, like a tornado/funnel.
    let twist = t * 5.0 + u.time * 1.5;
    let center = base + vec2<f32>(sin(twist), cos(twist)) * t * 0.22;
    // Radius sculpted by the spectrum along its height + bass swell + beat.
    let s = spec_at(t);
    let radius = mix(0.06, 0.5, t) * (0.6 + u.bass * 0.9 + s * 0.7 + u.beat * 0.3);
    return length(p.xz - center) - radius;
}

// Soft shadow by marching the shape SDF from a surface point toward a light.
// More steps + a softer penumbra constant = smoother, higher-quality shadows.
fn soft_shadow(p: vec3<f32>, lpos: vec3<f32>) -> f32 {
    let dir = normalize(lpos - p);
    let maxt = length(lpos - p);
    var res = 1.0;
    var t = 0.03;
    for (var i = 0; i < 44; i = i + 1) {
        let h = map_shape(p + dir * t);
        if (h < 0.001) {
            return 0.0;
        }
        res = min(res, 7.0 * h / t);
        t = t + clamp(h, 0.015, 0.2);
        if (t > maxt) {
            break;
        }
    }
    return clamp(res, 0.0, 1.0);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let aspect = u.resolution.x / u.resolution.y;
    var uv = in.uv * 2.0 - 1.0;
    uv.x = uv.x * aspect;

    // Room half-extents.
    let XB = 1.35;
    let YB = 1.0;
    let ZB = 3.6;

    // Camera looks into the room through the screen "window". A little vertical
    // offset + sway gives the off-axis, parallax-y depth read.
    let ro = vec3<f32>(0.18 * sin(u.time * 0.3), 0.12, -0.35);
    let rd = normalize(vec3<f32>(uv * 0.62, 1.0));

    // Intersect the 5 interior planes; keep the nearest valid hit.
    var best_t = 1e9;
    var nrm = vec3<f32>(0.0, 0.0, -1.0);
    var hid = 0;

    // Floor (y = -YB)
    if (rd.y < -1e-4) {
        let t = (-YB - ro.y) / rd.y;
        let p = ro + rd * t;
        if (t > 0.0 && t < best_t && abs(p.x) < XB && p.z > 0.0 && p.z < ZB) {
            best_t = t; nrm = vec3<f32>(0.0, 1.0, 0.0); hid = 1;
        }
    }
    // Ceiling (y = YB)
    if (rd.y > 1e-4) {
        let t = (YB - ro.y) / rd.y;
        let p = ro + rd * t;
        if (t > 0.0 && t < best_t && abs(p.x) < XB && p.z > 0.0 && p.z < ZB) {
            best_t = t; nrm = vec3<f32>(0.0, -1.0, 0.0); hid = 2;
        }
    }
    // Back wall (z = ZB)
    if (rd.z > 1e-4) {
        let t = (ZB - ro.z) / rd.z;
        let p = ro + rd * t;
        if (t > 0.0 && t < best_t && abs(p.x) < XB && abs(p.y) < YB) {
            best_t = t; nrm = vec3<f32>(0.0, 0.0, -1.0); hid = 3;
        }
    }
    // Left wall (x = -XB)
    if (rd.x < -1e-4) {
        let t = (-XB - ro.x) / rd.x;
        let p = ro + rd * t;
        if (t > 0.0 && t < best_t && abs(p.y) < YB && p.z > 0.0 && p.z < ZB) {
            best_t = t; nrm = vec3<f32>(1.0, 0.0, 0.0); hid = 4;
        }
    }
    // Right wall (x = XB)
    if (rd.x > 1e-4) {
        let t = (XB - ro.x) / rd.x;
        let p = ro + rd * t;
        if (t > 0.0 && t < best_t && abs(p.y) < YB && p.z > 0.0 && p.z < ZB) {
            best_t = t; nrm = vec3<f32>(-1.0, 0.0, 0.0); hid = 5;
        }
    }

    let p = ro + rd * best_t;

    // Key light out front (behind the camera) shines onto the back wall, so
    // the unseen funnel throws a sharp central shadow. A coloured fill light
    // off to the side adds a second, softer coloured shadow. Colours cycle;
    // beat flares them.
    let l1 = vec3<f32>(0.25 * sin(u.time * 0.4), 0.35, -0.8);
    let l2 = vec3<f32>(1.1 * sin(u.time * 0.5), 0.7, 0.1);
    let c1 = mix(vec3<f32>(1.0), palette(u.time * 0.05 + u.mid * 0.3), 0.45) * (1.0 + u.beat * 0.6);
    let c2 = palette(u.time * 0.05 + 0.45 + u.onset * 0.3) * (1.0 + u.beat);

    // Matte room surface; floor a touch darker, back wall a soft gradient.
    var albedo = vec3<f32>(0.18);
    if (hid == 1) { albedo = vec3<f32>(0.12); }
    if (hid == 3) { albedo = mix(vec3<f32>(0.22), vec3<f32>(0.10), (p.y + 1.0) * 0.5); }

    let n1 = normalize(l1 - p);
    let n2 = normalize(l2 - p);
    let d1 = max(dot(nrm, n1), 0.0);
    let d2 = max(dot(nrm, n2), 0.0);
    // Deepen the shadows (sharper penumbra falloff) so the room reads moodier.
    let s1 = pow(soft_shadow(p + nrm * 0.01, l1), 1.6);
    let s2 = pow(soft_shadow(p + nrm * 0.01, l2), 1.6);

    // Gentle distance falloff so the room stays moody but the back wall is lit
    // enough to read the shadow against.
    let f1 = 1.0 / (1.0 + 0.06 * dot(l1 - p, l1 - p));
    let f2 = 1.0 / (1.0 + 0.10 * dot(l2 - p, l2 - p));

    // Deep, shadowy base: the room is mostly dark and the lights carve it out
    // of near-black, so the unseen funnel's shadow dominates the frame.
    var col = albedo * 0.02; // ambient
    if (best_t < 1e8) {
        col = col + albedo * c1 * d1 * s1 * f1 * 3.6; // key
        col = col + albedo * c2 * d2 * s2 * f2 * 1.4; // coloured fill
        // A faint pool of light around each lamp's footprint adds shape without
        // lifting the shadows.
        col = col + c1 * d1 * s1 * f1 * 0.05;
    } else {
        col = vec3<f32>(0.0);
    }

    // Strong vignette pulls the corners into darkness for a moodier room.
    let vig = 1.0 - dot(in.uv - 0.5, in.uv - 0.5) * 1.1;
    col = col * clamp(vig, 0.0, 1.0);
    // Subtle filmic lift of the deep blacks keeps them from crushing flat.
    col = col + vec3<f32>(0.006, 0.004, 0.010);
    let grain = fract(sin(dot(in.uv * u.resolution, vec2<f32>(12.9, 78.2))) * 43758.5) - 0.5;
    col = col + grain * 0.01;

    return vec4<f32>(max(col, vec3<f32>(0.0)), 1.0);
}
