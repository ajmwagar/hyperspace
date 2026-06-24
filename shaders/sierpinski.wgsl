// Sierpinski — the classic Sierpinski-tetrahedron fold, raymarched as an
// endless architectural lattice of metallic cube cells wired together by thin
// struts, fading into a pale haze (after the Blender/Octane "Sierpinski
// formula" look). The camera flies forever forward through the structure.
//   • bass      — breathes the fold (cells swell/clench)
//   • mid       — slow tumble of the lattice + palette drift
//   • beat      — flares the strut glow and edge light
//   • amplitude — lifts the emissive wireframe
//   • spectrum  — sparkles the high-frequency edges
// Distinct from the bulb/box/apollonian: hard right angles, beams, blueprint
// haze — a building, not a creature.

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

fn rot(a: f32) -> mat2x2<f32> {
    let c = cos(a);
    let s = sin(a);
    return mat2x2<f32>(c, -s, s, c);
}

// Distance to a box of half-extent b, centred at origin.
fn box_de(p: vec3<f32>, b: vec3<f32>) -> f32 {
    let q = abs(p) - b;
    return length(max(q, vec3<f32>(0.0))) + min(max(q.x, max(q.y, q.z)), 0.0);
}

// Sierpinski-tetrahedron distance estimate (Kaleidoscopic IFS, 3 plane folds).
// Each cell is a small cube; thin cross-struts wire neighbouring cells, giving
// the connected-beam look. Returns vec2(distance, orbit-trap).
fn de(p0: vec3<f32>, fold: f32) -> vec2<f32> {
    var z = p0;
    let scale = 2.0;
    let off = vec3<f32>(1.0, 1.0, 1.0) * fold; // tetra offset (breathes with bass)
    var trap = 1e9;
    // Fewer levels → chunkier cube cells you read as 3D boxes (not fine lace).
    let iters = 6;
    for (var i = 0; i < iters; i = i + 1) {
        // Tetrahedral folds: reflect across the three diagonal planes.
        if (z.x + z.y < 0.0) { let t = -z.y; z.y = -z.x; z.x = t; }
        if (z.x + z.z < 0.0) { let t = -z.z; z.z = -z.x; z.x = t; }
        if (z.y + z.z < 0.0) { let t = -z.z; z.z = -z.y; z.y = t; }
        z = z * scale - off * (scale - 1.0);
        trap = min(trap, dot(z, z));
    }
    let inv = pow(scale, -f32(iters));
    // Solid cube cell.
    let cube = box_de(z, vec3<f32>(1.05)) * inv;
    // Three thin struts (a cross) wiring the cells together. Kept short so the
    // lattice reads as connected boxes, not a pin-cushion.
    let sx = box_de(z, vec3<f32>(1.9, 0.085, 0.085)) * inv;
    let sy = box_de(z, vec3<f32>(0.085, 1.9, 0.085)) * inv;
    let sz = box_de(z, vec3<f32>(0.085, 0.085, 1.9)) * inv;
    let struts = min(sx, min(sy, sz));
    return vec2<f32>(min(cube, struts), trap);
}

fn calc_normal(p: vec3<f32>, fold: f32) -> vec3<f32> {
    let e = vec2<f32>(0.0006, 0.0);
    return normalize(vec3<f32>(
        de(p + e.xyy, fold).x - de(p - e.xyy, fold).x,
        de(p + e.yxy, fold).x - de(p - e.yxy, fold).x,
        de(p + e.yyx, fold).x - de(p - e.yyx, fold).x,
    ));
}

// Cool metallic blueprint palette (steel → cyan glint), drifting with mids.
// Kept mid-dark so the cube faces read against the bright haze.
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

    // Fold breathes with the bass; cells swell and clench (kept subtle — this
    // is a KIFS, so big swings would pop the whole structure).
    let fold = 1.0 + 0.03 * sin(u.time * 0.3) + u.bass * 0.045;

    // Camera orbits CLOSE to the lattice (flying *through* a non-periodic
    // fractal just exits it into haze) so we're among the cube cells in 3D,
    // beams receding into the depth. Slow dolly keeps the recursion unfolding;
    // bass pulls us in on the drops.
    let ang = u.time * 0.14;
    let dist = 1.5 + 0.28 * sin(u.time * 0.09) - u.bass * 0.28;
    // Low, grazing orbit so a corner of the lattice points at us and the beams
    // recede hard into the haze (strong perspective = 3D, not a flat triangle).
    let ro = vec3<f32>(sin(ang) * dist, -0.55 + 0.3 * sin(u.time * 0.11), cos(ang) * dist);
    // Aim across the body toward the far upper side.
    let aim = vec3<f32>(0.1 * sin(u.time * 0.07), 0.45, 0.0);
    let fwd = normalize(aim - ro);
    let right = normalize(cross(vec3<f32>(0.0, 1.0, 0.0), fwd));
    let up = cross(fwd, right);
    // Mid-driven roll for a tumbling feel. Slightly wide FOV for depth.
    let roll = rot(u.time * 0.05 + u.mid * 0.4);
    let uvr = uv * roll;
    let rd = normalize(uvr.x * right + uvr.y * up + fwd * 1.35);

    var t = 0.0;
    var hit = false;
    var trap = 0.0;
    var glow = 0.0;
    let maxd = 16.0;
    for (var i = 0; i < 130; i = i + 1) {
        let p = ro + rd * t;
        let d = de(p, fold);
        glow = glow + exp(-d.x * 26.0);
        if (d.x < 0.0008 * (1.0 + t * 0.4)) {
            hit = true;
            trap = d.y;
            break;
        }
        t = t + d.x * 0.85;
        if (t > maxd) { break; }
    }

    // Pale blueprint haze the structure fades into (matches the Octane look).
    let haze = vec3<f32>(0.78, 0.82, 0.85);

    var col = haze;
    if (hit) {
        let p = ro + rd * t;
        let n = calc_normal(p, fold);
        let view = -rd;
        let base = palette(trap * 0.7 + u.time * 0.03 + u.mid * 0.25);

        // Two-light metallic shading.
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
        // Emissive wireframe along the struts (orbit-trap thin = edges).
        let edge = smoothstep(0.06, 0.0, trap);
        col = col + vec3<f32>(0.5, 0.8, 1.0) * edge * (u.amplitude * 0.8 + 0.15) * (1.0 + u.beat);
        // High-frequency sparkle on the metal.
        col = col + vec3<f32>(1.0) * fres * u.high * 0.5;

        // Depth fog into the haze — gentler now so near cells stay contrasty
        // and only the deep recursion dissolves into blueprint mist.
        let fog = 1.0 - exp(-t * 0.085);
        col = mix(col, haze, fog);
    }

    // Volumetric strut glow bleeding through the haze.
    col = col + palette(u.time * 0.03 + 0.5) * glow * 0.010 * (1.0 + u.beat * 0.8);

    col = col + col * u.beat * 0.18;
    // Reinhard keeps highlights in check, gentle lift back.
    col = col / (1.0 + col * 0.6);
    col = pow(col, vec3<f32>(0.9));

    let vig = 1.0 - dot(in.uv - 0.5, in.uv - 0.5) * 0.55;
    col = col * vig;

    return vec4<f32>(max(col, vec3<f32>(0.0)), 1.0);
}
