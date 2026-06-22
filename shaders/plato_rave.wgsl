// Plato's Rave — the Allegory of the Cave, dancing. A flickering fire sits low
// at the front of an organic rock cavern; a horizontal row of swaying figures
// stands between the fire and the cave wall. The figures are NEVER drawn — you
// only ever see their tall shadows thrown across the curved rock. The motion is
// LIGHTING-DRIVEN: the fire swings and flickers (audio-reactive) so the shadows
// dance side to side. Bass swells the figures, onsets/beats flare the fire.

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

fn hash21(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}
fn hash11(x: f32) -> f32 {
    return fract(sin(x * 91.17) * 43758.5453);
}
fn noise2(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let a = hash21(i);
    let b = hash21(i + vec2<f32>(1.0, 0.0));
    let c = hash21(i + vec2<f32>(0.0, 1.0));
    let d = hash21(i + vec2<f32>(1.0, 1.0));
    let s = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, s.x), mix(c, d, s.x), s.y);
}
fn fbm(p_in: vec2<f32>) -> f32 {
    var p = p_in; var v = 0.0; var a = 0.5;
    for (var i = 0; i < 3; i = i + 1) {
        v = v + a * noise2(p);
        p = p * 2.0 + vec2<f32>(1.7, 9.2);
        a = a * 0.5;
    }
    return v;
}

fn spec_at(tnorm: f32) -> f32 {
    let bin = u32(clamp(tnorm, 0.0, 1.0) * 200.0);
    if (bin < 512u) { return spectrum[bin]; }
    return 0.0;
}

// Signed distance to the rock: negative inside the cavern, positive in stone.
// A wide ellipsoid chamber with cheap lumpy displacement → rounded, organic,
// not boxy.
fn cave(p: vec3<f32>) -> f32 {
    let c = vec3<f32>(0.0, 0.4, 1.9);
    let r = vec3<f32>(3.3, 1.8, 3.1);
    var d = (length((p - c) / r) - 1.0) * 1.8;
    // Layered displacement: big rolling lumps, a ripple, and sharp ridged rock.
    d = d + (noise2(p.xy * 0.8 + 1.3) - 0.5) * 1.05;
    d = d + (noise2(p.zy * 1.5 + 7.1) - 0.5) * 0.45;
    // Ridged octave (1 - |..|) gives craggy stone rather than smooth blobs.
    d = d - (1.0 - abs(noise2(p.xy * 3.1 + 4.2) * 2.0 - 1.0)) * 0.22;
    d = d + (noise2(p.zx * 5.5 + 9.0) - 0.5) * 0.12;
    return d;
}

fn cave_normal(p: vec3<f32>) -> vec3<f32> {
    let e = vec2<f32>(0.02, 0.0);
    let g = vec3<f32>(
        cave(p + e.xyy) - cave(p - e.xyy),
        cave(p + e.yxy) - cave(p - e.yxy),
        cave(p + e.yyx) - cave(p - e.yyx),
    );
    // Interior-facing normal points opposite the outward gradient.
    return -normalize(g);
}

const FIG_SPACING: f32 = 0.95;
const FIG_Z: f32 = 2.0;

// The UNSEEN occluders: a horizontal row of swaying figures on the cave floor.
// Tiled along x. Only ever blocks light.
fn map_shape(p: vec3<f32>) -> f32 {
    let t = clamp((p.y + 1.2) / 2.2, 0.0, 1.0);
    let id = round(p.x / FIG_SPACING);
    let lx = p.x - FIG_SPACING * id;
    let ph = id * 1.7;
    let sway = sin(u.time * 1.6 + ph) * (0.08 + u.mid * 0.30);
    let cx = sway * t;
    let s = spec_at(t);
    let body = 0.10 * (0.65 + 0.55 * sin(t * 3.14159));
    let r = body * (1.0 + u.bass * 0.5 + s * 0.35);
    var d = length(vec2<f32>(lx - cx, p.z - FIG_Z)) - r;
    let head = -1.2 + (1.7 + 0.5 * hash11(id + 3.0));
    d = max(d, p.y - head);
    return d;
}

// Smooth soft shadow toward the (moving) fire.
fn soft_shadow(p: vec3<f32>, lpos: vec3<f32>) -> f32 {
    let dir = normalize(lpos - p);
    let maxt = length(lpos - p);
    var res = 1.0;
    var t = 0.04;
    for (var i = 0; i < 40; i = i + 1) {
        let h = map_shape(p + dir * t);
        if (h < 0.001) { return 0.0; }
        res = min(res, 7.0 * h / t);
        t = t + clamp(h, 0.02, 0.22);
        if (t > maxt) { break; }
    }
    return clamp(res, 0.0, 1.0);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let aspect = u.resolution.x / u.resolution.y;
    var uv = in.uv * 2.0 - 1.0;
    uv.x = uv.x * aspect;

    // Low camera (a seated prisoner) looking forward and slightly up.
    let ro = vec3<f32>(0.0, -0.25, -0.3);
    let rd = normalize(vec3<f32>(uv * 0.72, 1.0) + vec3<f32>(0.0, 0.10, 0.0));

    // Raymarch to the rock wall (we start inside, so step by distance-to-wall).
    var t = 0.05;
    var hit = false;
    for (var i = 0; i < 90; i = i + 1) {
        let pos = ro + rd * t;
        let dw = -cave(pos);
        if (dw < 0.004) { hit = true; break; }
        t = t + max(dw * 0.7, 0.02);
        if (t > 18.0) { break; }
    }
    let p = ro + rd * t;
    var n = cave_normal(p);
    // Fine rock bump-mapping: perturb the shading normal with high-freq noise
    // so the firelight breaks across craggy stone detail.
    let bump = vec3<f32>(
        noise2(p.yz * 9.0) - 0.5,
        noise2(p.zx * 9.0 + 3.0) - 0.5,
        noise2(p.xy * 9.0 + 6.0) - 0.5,
    );
    n = normalize(n + bump * 0.5);
    // Crevice ambient occlusion: how open is the rock just inside the surface.
    let ao = clamp(-cave(p + n * 0.22) / 0.22, 0.25, 1.0);

    // ---- The fire: low and front, SWINGING + flickering. This motion is what
    // makes the shadows dance. ----
    let flick = 0.55 + 0.45 * fbm(vec2<f32>(u.time * 6.0, 0.0)) + u.onset * 0.5;
    let fire = vec3<f32>(
        0.9 * sin(u.time * 0.8) + 0.30 * sin(u.time * 5.3) + (u.amplitude - 0.2),
        -0.55 + 0.10 * sin(u.time * 3.1),
        -0.10,
    );
    let fire_col = vec3<f32>(1.0, 0.45, 0.16) * flick * (1.0 + u.beat * 0.6);

    // Warm rock albedo: fbm base + ridged striations + darkened crevices.
    let rough = fbm(p.xy * 1.6 + p.z * 0.5);
    let strata = 1.0 - abs(fbm(p.zy * 2.2 + p.x * 0.3) * 2.0 - 1.0);
    var albedo = mix(vec3<f32>(0.12, 0.09, 0.07), vec3<f32>(0.30, 0.23, 0.16), rough);
    albedo = albedo * (0.6 + 0.5 * strata); // mineral banding
    albedo = albedo * ao;                    // dirt in the crevices

    let ldir = normalize(fire - p);
    let diff = max(dot(n, ldir), 0.0);
    let sh = soft_shadow(p + n * 0.02, fire);
    let fall = 1.0 / (1.0 + 0.12 * dot(fire - p, fire - p));

    var col = albedo * vec3<f32>(0.05, 0.06, 0.09); // faint cool ambient
    if (hit) {
        col = col + albedo * fire_col * diff * pow(sh, 1.5) * fall * 4.2;
        col = col + fire_col * diff * sh * fall * 0.05;
    } else {
        col = vec3<f32>(0.0);
    }

    // Direct ember glow where the fire sits in frame.
    let fdist = length(p - fire);
    col = col + vec3<f32>(1.0, 0.5, 0.2) * flick * 0.012 / (0.05 + fdist * fdist);

    // Moody vignette + faint grain.
    let vig = 1.0 - dot(in.uv - 0.5, in.uv - 0.5) * 1.0;
    col = col * clamp(vig, 0.0, 1.0);
    col = col + vec3<f32>(0.008, 0.005, 0.004);
    let grain = fract(sin(dot(in.uv * u.resolution, vec2<f32>(12.9, 78.2))) * 43758.5) - 0.5;
    col = col + grain * 0.01;

    return vec4<f32>(max(col, vec3<f32>(0.0)), 1.0);
}
