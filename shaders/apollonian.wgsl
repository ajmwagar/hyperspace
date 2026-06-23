// Apollonian — a Kleinian/Apollonian-gasket fractal: endlessly nested spheres
// folded into a glowing crystalline temple, raymarched. Distinct from the
// bulb/box — all rings and bubbles. Bass morphs the fold (the structure
// breathes and reshuffles), mids cycle the palette, beats flare the glow,
// the spectrum sparkles the surface.

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

// Apollonian distance estimate (after Iñigo Quilez). Returns vec2(dist, trap).
fn de(p0: vec3<f32>, kk: f32) -> vec2<f32> {
    var p = p0;
    var s = 1.0;
    var trap = 1e9;
    for (var i = 0; i < 8; i = i + 1) {
        p = -1.0 + 2.0 * fract(0.5 * p + 0.5);
        let r2 = dot(p, p);
        trap = min(trap, r2);
        let k = kk / r2;
        p = p * k;
        s = s * k;
    }
    return vec2<f32>(0.25 * abs(p.y) / s, trap);
}

fn calc_normal(p: vec3<f32>, kk: f32) -> vec3<f32> {
    let e = vec2<f32>(0.0008, 0.0);
    return normalize(vec3<f32>(
        de(p + e.xyy, kk).x - de(p - e.xyy, kk).x,
        de(p + e.yxy, kk).x - de(p - e.yxy, kk).x,
        de(p + e.yyx, kk).x - de(p - e.yyx, kk).x,
    ));
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let aspect = u.resolution.x / u.resolution.y;
    var uv = in.uv * 2.0 - 1.0;
    uv.x = uv.x * aspect;

    // Fold factor morphs the whole gasket; bass reshuffles it.
    let kk = 1.05 + 0.12 * sin(u.time * 0.2) + u.bass * 0.22;

    // Slowly orbiting camera.
    let ang = u.time * 0.12;
    let dist = 2.6;
    let ro = vec3<f32>(sin(ang) * dist, 0.4 * sin(u.time * 0.09), cos(ang) * dist);
    let fwd = normalize(-ro);
    let right = normalize(cross(vec3<f32>(0.0, 1.0, 0.0), fwd));
    let up = cross(fwd, right);
    let rd = normalize(uv.x * right + uv.y * up + fwd * 1.7);

    var t = 0.0;
    var hit = false;
    var trap = 0.0;
    var glow = 0.0;
    for (var i = 0; i < 100; i = i + 1) {
        let p = ro + rd * t;
        let d = de(p, kk);
        glow = glow + exp(-d.x * 30.0);
        if (d.x < 0.0006) {
            hit = true;
            trap = d.y;
            break;
        }
        t = t + d.x * 0.85;
        if (t > 7.0) {
            break;
        }
    }

    var col = vec3<f32>(0.0);
    if (hit) {
        let p = ro + rd * t;
        let n = calc_normal(p, kk);
        let view = -rd;
        let base = palette(trap * 1.2 + u.time * 0.05 + u.mid * 0.3);
        let l = normalize(vec3<f32>(0.6, 0.8, -0.3));
        let diff = max(dot(n, l), 0.0);
        let fres = pow(1.0 - max(dot(n, view), 0.0), 3.0);
        let ao = 1.0 / (1.0 + t * 0.6);
        col = base * (0.15 + diff * 0.9) * ao;
        col = col + base * fres * 1.3;
        col = col + vec3<f32>(1.0) * fres * u.high * 0.6;
    }

    // Glowing aura through the bubbles (kept subtle so it doesn't blow out).
    col = col + palette(u.time * 0.05 + 0.4) * glow * 0.014 * (1.0 + u.beat * 0.6);

    col = col + col * u.beat * 0.25;
    // Reinhard tone map keeps the highlights from clipping to white.
    col = col / (1.0 + col);
    col = pow(col, vec3<f32>(0.85)); // gentle lift back

    let vig = 1.0 - dot(in.uv - 0.5, in.uv - 0.5) * 0.7;
    col = col * vig;

    return vec4<f32>(col, 1.0);
}
