// Fractal Flight — first-person run THROUGH an endless lattice of Mandelboxes.
// 3D domain repetition tiles the fractal in every direction, so the camera
// barrels forward forever, always deep inside detail. The flight path banks
// up / down / left / right on the beat grid: every BARS_PER_TURN bars it picks
// a new direction, so it weaves through the structure in time with the music.
//
// === Tempo knobs (edit to match your track) ============================
//   BPM            — beats per minute
//   BEATS_PER_BAR  — time signature numerator (4 = 4/4)
//   BARS_PER_TURN  — change direction every N bars
// (Live, these could instead be driven from a CV channel or tempo detector.)

const BPM: f32 = 120.0;
const BEATS_PER_BAR: f32 = 4.0;
const BARS_PER_TURN: f32 = 2.0;
const CELL: f32 = 2.7; // size of one repeated fractal cell (tighter = denser)

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
    let d = vec3<f32>(0.30, 0.15, 0.55);
    return a + b * cos(6.28318 * (c * t + d));
}

fn hash1(n: f32) -> f32 {
    return fract(sin(n * 127.1) * 43758.5453);
}

// One of 4 lateral directions (up/down/left/right) for turn segment k.
fn turn_dir(k: f32) -> vec2<f32> {
    let i = floor(hash1(k + 0.5) * 4.0);
    if (i < 1.0) { return vec2<f32>(1.0, 0.0); }
    if (i < 2.0) { return vec2<f32>(-1.0, 0.0); }
    if (i < 3.0) { return vec2<f32>(0.0, 1.0); }
    return vec2<f32>(0.0, -1.0);
}

// Mandelbox DE on a single cell. Returns vec2(distance, orbit-trap).
fn de(pos: vec3<f32>, scale: f32) -> vec2<f32> {
    let min_r2 = 0.25;
    var z = pos;
    var dr = 1.0;
    var trap = 1e9;
    for (var i = 0; i < 10; i = i + 1) {
        z = clamp(z, vec3<f32>(-1.0), vec3<f32>(1.0)) * 2.0 - z;
        let r2 = dot(z, z);
        if (r2 < min_r2) {
            let f = 1.0 / min_r2;
            z = z * f; dr = dr * f;
        } else if (r2 < 1.0) {
            let f = 1.0 / r2;
            z = z * f; dr = dr * f;
        }
        z = scale * z + pos;
        dr = dr * abs(scale) + 1.0;
        trap = min(trap, length(z));
    }
    return vec2<f32>(length(z) / abs(dr), trap);
}

// Tile space into a 3D lattice of mandelboxes, then evaluate the DE.
fn map(p: vec3<f32>, scale: f32) -> vec2<f32> {
    var q = p;
    q = q - CELL * round(q / CELL);
    return de(q, scale);
}

fn calc_normal(p: vec3<f32>, scale: f32) -> vec3<f32> {
    let e = vec2<f32>(0.0015, 0.0);
    return normalize(vec3<f32>(
        map(p + e.xyy, scale).x - map(p - e.xyy, scale).x,
        map(p + e.yxy, scale).x - map(p - e.yxy, scale).x,
        map(p + e.yyx, scale).x - map(p - e.yyx, scale).x,
    ));
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let aspect = u.resolution.x / u.resolution.y;
    var uv = in.uv * 2.0 - 1.0;
    uv.x = uv.x * aspect;

    let scale = -2.0 + u.bass * 0.2;

    // Beat grid: seconds per turn segment.
    let seg = (60.0 / BPM) * BEATS_PER_BAR * BARS_PER_TURN;
    let k = floor(u.time / seg);
    let local = fract(u.time / seg);

    // Forward run — beats and bass make it surge ("running" harder on the drop).
    let speed = 2.2 + u.beat * 2.5 + u.bass * 1.2;

    // Accumulate eased lateral steps so the path turns at each bar boundary.
    let stride = CELL * 0.5;
    var lateral = vec2<f32>(0.0);
    var j = 0.0;
    loop {
        if (j > k || j > 64.0) { break; }
        var w = 1.0;
        if (j == k) { w = smoothstep(0.0, 1.0, local); }
        lateral = lateral + turn_dir(j) * stride * w;
        j = j + 1.0;
    }

    let ro = vec3<f32>(lateral.x, lateral.y, u.time * speed);

    // Bank into the current turn (peaks mid-segment), look forward.
    let lean = turn_dir(k) * sin(local * 3.14159) * 0.7;
    let fwd = normalize(vec3<f32>(lean, 1.0));
    let right = normalize(cross(vec3<f32>(0.0, 1.0, 0.0), fwd));
    let up = cross(fwd, right);
    // A little roll for momentum.
    let roll = lean.x * 0.4;
    let cr = cos(roll); let sr = sin(roll);
    let ruv = vec2<f32>(uv.x * cr - uv.y * sr, uv.x * sr + uv.y * cr);
    let rd = normalize(ruv.x * right + ruv.y * up + fwd * 1.5);

    var t = 0.02;
    var hit = false;
    var trap = 0.0;
    var steps = 0.0;
    for (var i = 0; i < 110; i = i + 1) {
        let p = ro + rd * t;
        let d = map(p, scale);
        if (d.x < 0.0009) {
            hit = true;
            trap = d.y;
            break;
        }
        t = t + d.x * 0.8;
        steps = steps + 1.0;
        if (t > 9.0) {
            break;
        }
    }

    var col = vec3<f32>(0.0);
    if (hit) {
        let p = ro + rd * t;
        let n = calc_normal(p, scale);
        let view = -rd;
        let base = palette(trap * 0.5 + u.time * 0.06 + u.mid * 0.3);
        let l = normalize(vec3<f32>(0.4, 0.6, -0.6));
        let diff = max(dot(n, l), 0.0);
        let fres = pow(1.0 - max(dot(n, view), 0.0), 2.5);
        let ao = 1.0 - steps / 110.0;
        col = base * (0.18 + diff * 0.85) * ao;
        col = col + base * fres * 1.2;
        col = col + vec3<f32>(1.0) * fres * u.high * 0.5;
    }

    // Depth fog into a dark void — lighter so we stay inside readable detail.
    let fog = 1.0 - exp(-t * 0.11);
    col = mix(col, vec3<f32>(0.02, 0.0, 0.05), fog * 0.5);

    // Beat bloom + vignette.
    col = col + col * u.beat * 0.3;
    let vig = 1.0 - dot(in.uv - 0.5, in.uv - 0.5) * 0.6;
    col = col * vig;

    return vec4<f32>(col, 1.0);
}
