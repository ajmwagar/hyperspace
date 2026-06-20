// Liquid Chrome — raymarched metaballs with a reflective, iridescent surface.
// Blobs orbit and merge like ferrofluid/mercury; bass swells them, beats pump
// a central blob, mids tint the thin-film iridescence. A glossy environment is
// reflected off the surface for that "liquid metal" wow look. First 3D SDF
// shader in the set.

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

// Smooth minimum — the metaball blend.
fn smin(a: f32, b: f32, k: f32) -> f32 {
    let h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

// Signed distance to the blob field.
fn map(p: vec3<f32>) -> f32 {
    var d = 1e9;
    let blend = 0.55 + u.mid * 0.35;
    for (var i = 0; i < 6; i = i + 1) {
        let fi = f32(i);
        let ang = u.time * (0.3 + 0.06 * fi) + fi * 1.7;
        let orbit = 1.1 + 0.35 * sin(u.time * 0.5 + fi);
        let c = vec3<f32>(
            cos(ang) * orbit,
            sin(ang * 1.3) * 0.85,
            sin(ang) * orbit,
        );
        let rad = 0.42 + u.bass * 0.22 + 0.08 * sin(u.time + fi);
        d = smin(d, length(p - c) - rad, blend);
    }
    // Central blob pumps on the beat.
    d = smin(d, length(p) - (0.45 + u.beat * 0.4 + u.sub_bass * 0.2), 0.7);
    return d;
}

fn calc_normal(p: vec3<f32>) -> vec3<f32> {
    let e = vec2<f32>(0.0015, 0.0);
    return normalize(vec3<f32>(
        map(p + e.xyy) - map(p - e.xyy),
        map(p + e.yxy) - map(p - e.yxy),
        map(p + e.yyx) - map(p - e.yyx),
    ));
}

// Glossy studio environment sampled along a reflection direction.
fn env(dir: vec3<f32>) -> vec3<f32> {
    let t = dir.y * 0.5 + 0.5;
    var col = mix(vec3<f32>(0.04, 0.05, 0.09), vec3<f32>(0.45, 0.55, 0.75), t);
    // Soft overhead softbox.
    col = col + vec3<f32>(0.9) * pow(max(dir.y, 0.0), 4.0);
    // Warm key light.
    let sun = pow(max(dot(dir, normalize(vec3<f32>(0.6, 0.7, 0.4))), 0.0), 48.0);
    col = col + vec3<f32>(1.0, 0.85, 0.7) * sun * 1.5;
    return col;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let aspect = u.resolution.x / u.resolution.y;
    var uv = in.uv * 2.0 - 1.0;
    uv.x = uv.x * aspect;

    // Camera, slowly rotating around the blobs.
    let ca = u.time * 0.12;
    let ro = vec3<f32>(sin(ca) * 4.0, 0.6, cos(ca) * 4.0);
    let fwd = normalize(-ro);
    let right = normalize(cross(vec3<f32>(0.0, 1.0, 0.0), fwd));
    let up = cross(fwd, right);
    let rd = normalize(uv.x * right + uv.y * up + fwd * 1.8);

    // March.
    var t = 0.0;
    var hit = false;
    for (var i = 0; i < 80; i = i + 1) {
        let p = ro + rd * t;
        let d = map(p);
        if (d < 0.001) {
            hit = true;
            break;
        }
        t = t + d;
        if (t > 12.0) {
            break;
        }
    }

    var col: vec3<f32>;
    if (hit) {
        let p = ro + rd * t;
        let n = calc_normal(p);
        let view = -rd;
        let refl = reflect(rd, n);

        // Mirror-like reflection of the environment.
        col = env(refl);

        // Fresnel brightens the rim.
        let fres = pow(1.0 - max(dot(n, view), 0.0), 3.0);
        col = mix(col, vec3<f32>(1.0), fres * 0.65);

        // Thin-film iridescence — angle + mids drive the hue.
        let irid = palette(dot(n, view) * 1.4 + u.time * 0.08 + u.mid * 0.5);
        col = mix(col, col * irid * 1.6, 0.45);

        // Highs sparkle along the surface.
        col = col + vec3<f32>(1.0) * fres * u.high * 0.5;
    } else {
        // Background is a dim version of the same environment.
        col = env(rd) * 0.5;
    }

    // Beat bloom + slight vignette.
    col = col + col * u.beat * 0.25;
    let vig = 1.0 - dot(in.uv - 0.5, in.uv - 0.5) * 0.6;
    col = col * vig;

    return vec4<f32>(col, 1.0);
}
