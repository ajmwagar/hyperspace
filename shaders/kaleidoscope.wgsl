// Kaleidoscope — a *proper* generative kaleidoscope, not a mirror post-effect.
// Models the real thing: an "object chamber" of tumbling coloured glass beads,
// viewed down a mirrored tube. We fold screen space into N-fold wedge-mirror
// symmetry (the two-mirror scope) AND repeat it in log-radius so the pattern
// nests in concentric rings receding to the centre — the hypnotic tube depth.
// The bead chamber drifts and rotates on its own, so the jewels tumble.
//   • bass      — spins/tumbles the chamber + breathes the zoom
//   • mid       — fold count (clean steps) + palette drift
//   • beat      — kicks the rotation and flares the beads
//   • amplitude — overall brightness / bead glow
//   • high      — sparkle on the facets
// Distinct from post/kaleidoscope.wgsl (which just folds a prior pass).

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

const TAU: f32 = 6.2831853;

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
    let c = cos(a); let s = sin(a);
    return mat2x2<f32>(c, -s, s, c);
}

fn hash2(p: vec2<f32>) -> vec2<f32> {
    let q = vec2<f32>(dot(p, vec2<f32>(127.1, 311.7)), dot(p, vec2<f32>(269.5, 183.3)));
    return fract(sin(q) * 43758.5453);
}

fn hash1(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(41.3, 289.1))) * 21793.13);
}

fn noise(p: vec2<f32>) -> f32 {
    let i = floor(p); let f = fract(p);
    let u2 = f * f * (3.0 - 2.0 * f);
    let a = hash1(i);
    let b = hash1(i + vec2<f32>(1.0, 0.0));
    let c = hash1(i + vec2<f32>(0.0, 1.0));
    let d = hash1(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u2.x), mix(c, d, u2.x), u2.y);
}

fn fbm(p0: vec2<f32>) -> f32 {
    var p = p0; var s = 0.0; var a = 0.5;
    for (var i = 0; i < 5; i = i + 1) {
        s = s + a * noise(p);
        p = rot(0.6) * p * 2.0;
        a = a * 0.5;
    }
    return s;
}

// Stained-glass palette.
fn palette(t: f32) -> vec3<f32> {
    let a = vec3<f32>(0.5, 0.5, 0.5);
    let b = vec3<f32>(0.5, 0.5, 0.5);
    let c = vec3<f32>(1.0, 1.0, 1.0);
    let d = vec3<f32>(0.0, 0.33, 0.67);
    return a + b * cos(TAU * (c * t + d));
}

// The object chamber: coloured glass tint (domain-warped fbm) + jewelled beads
// on a drifting jittered grid. This is what the mirrors multiply into a mandala.
fn chamber(p0: vec2<f32>) -> vec3<f32> {
    let t = u.time;
    // Slow tumble + drift of the whole bead chamber.
    var p = rot(t * 0.10 + u.bass * 0.4) * p0;
    p = p + vec2<f32>(sin(t * 0.13), cos(t * 0.11)) * 0.5;

    // Warped fbm → flowing coloured glass.
    let w = vec2<f32>(fbm(p * 1.2 + t * 0.05), fbm(p * 1.2 + vec2<f32>(4.7, 2.1) - t * 0.04));
    let n = fbm(p * 1.6 + w * 1.8);
    var col = palette(n * 1.4 + t * 0.05 + u.mid * 0.3) * (0.35 + 0.5 * n);

    // Jewelled beads: glowing coloured dots on jittered grids that drift. Two
    // layers at different scales pack the field with big and small jewels (a
    // real scope is dense with mixed-size chips of glass).
    for (var layer = 0; layer < 2; layer = layer + 1) {
        let scale = select(2.4, 5.1, layer == 1);   // coarse then fine
        let lseed = f32(layer) * 17.3;
        let g = p * scale + lseed;
        let cell = floor(g);
        for (var j = -1; j <= 1; j = j + 1) {
            for (var i = -1; i <= 1; i = i + 1) {
                let id = cell + vec2<f32>(f32(i), f32(j));
                let h = hash2(id + lseed);
                let centre = id + 0.5 + 0.35 * vec2<f32>(sin(t * (0.4 + h.x) + h.x * TAU),
                                                         cos(t * (0.4 + h.y) + h.y * TAU));
                let d = length(g - centre);
                let rad = 0.28 + 0.14 * h.x;
                let bead = smoothstep(rad, rad * 0.15, d);
                let bcol = palette(h.y + t * 0.08 + f32(layer) * 0.25);
                let hi = pow(smoothstep(rad, 0.0, d), 6.0);
                let amp = select(0.7, 0.5, layer == 1);  // fine layer a touch dimmer
                col = col + bcol * bead * (amp + u.amplitude * 0.8) + vec3<f32>(1.0) * hi * (0.3 + u.high * 1.2) * h.x;
            }
        }
    }
    return col;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let aspect = u.resolution.x / u.resolution.y;
    var p = in.uv - 0.5;
    p.x = p.x * aspect;

    // N-fold wedge mirror (quantized so the fold changes in clean steps).
    let segs = 6.0 + 2.0 * floor(u.mid * 4.0);          // 6..14
    let seg = TAU / segs;
    var a = atan2(p.y, p.x) + u.time * 0.12 + u.beat * 0.30;
    a = a - seg * floor(a / seg);
    a = abs(a - seg * 0.5);                              // mirror inside the wedge

    // Radial ring tiling. A log term gives the receding-tube depth near the
    // centre; a linear `r` term makes the rings pile up ever denser toward the
    // rim, so the corners go wild with tightly-packed reflections like a real
    // scope (instead of smoothing out into big lobes).
    var r = length(p);
    let zoom = 1.0 - u.bass * 0.10 * sin(u.time * 0.6);  // bass breathes the zoom
    var lr = log(r + 1e-3) * 1.7 + r * 2.6 - u.time * 0.15;
    // Break the perfectly-circular rings with a symmetric wobble (uses the
    // folded angle + radius, so mirror symmetry survives) that grows toward the
    // rim — the corners churn into organic jewelled chaos instead of smooth
    // bands. Beat cranks the turbulence.
    let wob = fbm(vec2<f32>(a * 4.0, r * 5.0 - u.time * 0.2));
    lr = lr + (wob - 0.5) * (0.35 + r * 1.1) * (1.0 + u.beat * 0.6);
    lr = abs(fract(lr) - 0.5) * 2.0;                     // mirrored ring coordinate

    // Reconstruct a chamber sample point from (folded angle, ring coordinate).
    let rr = exp((lr - 0.5) * 1.15) * zoom;
    let q = vec2<f32>(cos(a), sin(a)) * rr;

    var col = chamber(q);

    // Glass seams: darken the exact mirror edges for a leaded-glass look.
    let edge = smoothstep(0.0, 0.04, a) * smoothstep(0.0, 0.04, seg * 0.5 - a);
    col = col * mix(0.55, 1.0, edge);

    // Central bloom + beat flash down the tube.
    let core = smoothstep(0.5, 0.0, r);
    col = col + col * core * (0.25 + u.beat * 0.6);

    // Tone + very light vignette (keep the busy corners bright, like an IRL
    // scope where the whole field is packed edge to edge).
    col = col / (1.0 + col * 0.5);
    col = pow(col, vec3<f32>(0.85));
    let vig = 1.0 - dot(in.uv - 0.5, in.uv - 0.5) * 0.15;
    col = col * vig;

    return vec4<f32>(max(col, vec3<f32>(0.0)), 1.0);
}
