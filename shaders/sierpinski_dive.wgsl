// Sierpinski Dive — an *endless* zoom into the Sierpinski tetrahedron. The
// trick: the tetra is invariant under (scale ×2 about a vertex) + (120° spin
// about that vertex's 3-fold axis). So we dive down the (1,1,1) axis and rotate
// exactly 120° per zoom-doubling — every loop wraps with NO seam, an infinite
// triangular kaleidoscope tunnel rushing at the camera. The camera never moves;
// the fractal is scaled/rotated past it, so there's zero precision loss however
// long it runs.
//   • bass      — breathes the fold (tunnel walls swell/clench)
//   • mid       — palette drift + slow camera sway
//   • beat      — flares the strut glow + a brightness punch
//   • amplitude — lifts the emissive wireframe
//   • spectrum  — sparkles the metal edges
// Companion to sierpinski.wgsl (the orbiting hero shot); this is the dive.

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

const PI: f32 = 3.14159265;

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

fn rot(a: f32) -> mat2x2<f32> {
    let c = cos(a);
    let s = sin(a);
    return mat2x2<f32>(c, -s, s, c);
}

// Rotate vector p about unit axis a by angle (Rodrigues).
fn rodrigues(p: vec3<f32>, a: vec3<f32>, angle: f32) -> vec3<f32> {
    let c = cos(angle);
    let s = sin(angle);
    return p * c + cross(a, p) * s + a * dot(a, p) * (1.0 - c);
}

fn box_de(p: vec3<f32>, b: vec3<f32>) -> f32 {
    let q = abs(p) - b;
    return length(max(q, vec3<f32>(0.0))) + min(max(q.x, max(q.y, q.z)), 0.0);
}

// Sierpinski-tetrahedron DE (Kaleidoscopic IFS, 3 plane folds). Chunky cube
// cells wired by thin struts. Deep iteration count so the infinite dive always
// has fresh detail. Returns vec2(distance, orbit-trap).
fn de(p0: vec3<f32>, fold: f32) -> vec2<f32> {
    var z = p0;
    let scale = 2.0;
    let off = vec3<f32>(1.0, 1.0, 1.0) * fold;
    var trap = 1e9;
    let iters = 12;
    for (var i = 0; i < iters; i = i + 1) {
        if (z.x + z.y < 0.0) { let t = -z.y; z.y = -z.x; z.x = t; }
        if (z.x + z.z < 0.0) { let t = -z.z; z.z = -z.x; z.x = t; }
        if (z.y + z.z < 0.0) { let t = -z.z; z.z = -z.y; z.y = t; }
        z = z * scale - off * (scale - 1.0);
        trap = min(trap, dot(z, z));
    }
    let inv = pow(scale, -f32(iters));
    let cube = box_de(z, vec3<f32>(1.05)) * inv;
    let sx = box_de(z, vec3<f32>(1.9, 0.085, 0.085)) * inv;
    let sy = box_de(z, vec3<f32>(0.085, 1.9, 0.085)) * inv;
    let sz = box_de(z, vec3<f32>(0.085, 0.085, 1.9)) * inv;
    let struts = min(sx, min(sy, sz));
    return vec2<f32>(min(cube, struts), trap);
}

// The seamless infinite-zoom transform: scale the world ×2^f about the dive
// vertex and spin f·120° about its 3-fold axis, then evaluate the static DE.
// At the f:1→0 wrap, (×2 + 120°) is an exact symmetry of the tetra, so the
// image is continuous — endless zoom with no precision loss.
fn dive_de(p: vec3<f32>, fold: f32, f: f32) -> vec2<f32> {
    let v = vec3<f32>(1.0, 1.0, 1.0) * fold;       // dive vertex
    let ax = normalize(vec3<f32>(1.0, 1.0, 1.0));   // its 3-fold axis
    let s = exp2(f);                                 // 1 → 2
    var q = (p - v) * s;
    q = rodrigues(q, ax, f * (2.0 / 3.0) * PI);      // 0 → 120°
    q = q + v;
    let r = de(q, fold);
    return vec2<f32>(r.x / s, r.y);                  // undo the scale on distance
}

fn calc_normal(p: vec3<f32>, fold: f32, f: f32) -> vec3<f32> {
    let e = vec2<f32>(0.0006, 0.0);
    return normalize(vec3<f32>(
        dive_de(p + e.xyy, fold, f).x - dive_de(p - e.xyy, fold, f).x,
        dive_de(p + e.yxy, fold, f).x - dive_de(p - e.yxy, fold, f).x,
        dive_de(p + e.yyx, fold, f).x - dive_de(p - e.yyx, fold, f).x,
    ));
}

// Cool metallic blueprint palette (steel → cyan glint), drifting with mids.
fn palette(t: f32) -> vec3<f32> {
    let a = vec3<f32>(0.34, 0.38, 0.44);
    let b = vec3<f32>(0.26, 0.28, 0.33);
    let c = vec3<f32>(1.0, 1.0, 1.0);
    let d = vec3<f32>(0.55, 0.60, 0.70);
    return a + b * cos(6.28318 * (c * t + d));
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let aspect = u.resolution.x / u.resolution.y;
    var uv = in.uv * 2.0 - 1.0;
    uv.x = uv.x * aspect;

    // Fold breathes with bass (kept subtle — KIFS pops if swung hard).
    let fold = 1.0 + 0.025 * sin(u.time * 0.3) + u.bass * 0.04;

    // Continuous dive phase. Constant rate keeps the wrap seamless; audio drives
    // the *look*, not the zoom speed (varying speed would break the seam).
    let f = fract(u.time * 0.22);

    // Camera is FIXED on the 3-fold axis, sitting INSIDE the body (in the
    // central void) looking toward the dive vertex v; the surrounding three
    // sub-tetras form a triangular tunnel converging on v, and the dive_de
    // transform rushes that tunnel past the lens. Gentle mid sway/roll keep it
    // organic (continuous in time → no seam at the zoom wrap).
    let v = vec3<f32>(1.0, 1.0, 1.0) * fold;
    let ax = normalize(vec3<f32>(1.0, 1.0, 1.0));
    let perp1 = normalize(cross(ax, vec3<f32>(0.0, 1.0, 0.0)));
    let perp2 = cross(ax, perp1);
    let sway = 0.06 + u.mid * 0.10;
    let ro = ax * 0.9 + (perp1 * sin(u.time * 0.13) + perp2 * cos(u.time * 0.11)) * sway;
    // Aim slightly OFF the axis so the dive vertex sits a touch off-centre: the
    // tunnel walls then recede asymmetrically → real 3D perspective instead of a
    // flat dead-on kaleidoscope. (Camera is independent of dive_de, so the zoom
    // stays seamless.) The off-axis bearing drifts slowly for variety.
    let bearing = 0.32 * (perp1 * cos(u.time * 0.05) + perp2 * sin(u.time * 0.05));
    let aim = v + bearing;
    let fwd = normalize(aim - ro);
    let right = normalize(cross(perp2, fwd));
    let up = cross(fwd, right);
    let roll = rot(u.time * 0.07 + u.mid * 0.3);
    let uvr = uv * roll;
    let rd = normalize(uvr.x * right + uvr.y * up + fwd * 1.45);

    var t = 0.0;
    var hit = false;
    var trap = 0.0;
    var glow = 0.0;
    let maxd = 12.0;
    for (var i = 0; i < 140; i = i + 1) {
        let p = ro + rd * t;
        let d = dive_de(p, fold, f);
        glow = glow + exp(-d.x * 26.0);
        if (d.x < 0.0008 * (1.0 + t * 0.4)) {
            hit = true;
            trap = d.y;
            break;
        }
        t = t + d.x * 0.85;
        if (t > maxd) { break; }
    }

    let haze = vec3<f32>(0.78, 0.82, 0.85);

    var col = haze;
    if (hit) {
        let p = ro + rd * t;
        let n = calc_normal(p, fold, f);
        let view = -rd;
        let base = palette(trap * 0.7 + u.time * 0.03 + u.mid * 0.25);

        let l1 = normalize(vec3<f32>(0.5, 0.8, -0.4));
        let l2 = normalize(vec3<f32>(-0.6, 0.3, 0.5));
        let diff = max(dot(n, l1), 0.0) + 0.4 * max(dot(n, l2), 0.0);
        let h1 = normalize(l1 + view);
        let spec = pow(max(dot(n, h1), 0.0), 48.0);
        let fres = pow(1.0 - max(dot(n, view), 0.0), 4.0);
        let ao = 1.0 / (1.0 + t * 0.25);

        col = base * (0.08 + diff * 1.05) * ao;
        col = col + vec3<f32>(0.9, 0.95, 1.0) * spec * 1.4;
        col = col + base * fres * 1.2;
        let edge = smoothstep(0.06, 0.0, trap);
        col = col + vec3<f32>(0.5, 0.8, 1.0) * edge * (u.amplitude * 0.8 + 0.15) * (1.0 + u.beat);
        col = col + vec3<f32>(1.0) * fres * u.high * 0.5;

        // Depth fog into the haze — only the deepest recursion dissolves.
        let fog = 1.0 - exp(-t * 0.085);
        col = mix(col, haze, fog);
    }

    // Volumetric strut glow bleeding through the haze.
    col = col + palette(u.time * 0.03 + 0.5) * glow * 0.010 * (1.0 + u.beat * 0.8);

    col = col + col * u.beat * 0.20;
    col = col / (1.0 + col * 0.6);
    col = pow(col, vec3<f32>(0.9));

    let vig = 1.0 - dot(in.uv - 0.5, in.uv - 0.5) * 0.55;
    col = col * vig;

    return vec4<f32>(max(col, vec3<f32>(0.0)), 1.0);
}
