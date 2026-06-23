// Acid Soup — a Mandelbox flown through head-on with heavy fog, which melts the
// folded box/sphere structure into a churning, colourful primordial soup rather
// than crisp architecture. A happy accident worth keeping. Bass morphs the
// fold, mids cycle the palette, beats surge the drift speed and glow.

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
    let d = vec3<f32>(0.20, 0.10, 0.55);
    return a + b * cos(6.28318 * (c * t + d));
}

// Mandelbox distance estimate. Returns vec2(distance, orbit-trap).
fn de(pos: vec3<f32>, scale: f32) -> vec2<f32> {
    let min_r2 = 0.25;
    let fixed_r2 = 1.0;
    var z = pos;
    var dr = 1.0;
    var trap = 1e9;
    for (var i = 0; i < 12; i = i + 1) {
        z = clamp(z, vec3<f32>(-1.0), vec3<f32>(1.0)) * 2.0 - z;
        let r2 = dot(z, z);
        if (r2 < min_r2) {
            let f = fixed_r2 / min_r2;
            z = z * f;
            dr = dr * f;
        } else if (r2 < fixed_r2) {
            let f = fixed_r2 / r2;
            z = z * f;
            dr = dr * f;
        }
        z = scale * z + pos;
        dr = dr * abs(scale) + 1.0;
        trap = min(trap, length(z));
    }
    return vec2<f32>(length(z) / abs(dr), trap);
}

fn calc_normal(p: vec3<f32>, scale: f32) -> vec3<f32> {
    let e = vec2<f32>(0.0015, 0.0);
    return normalize(vec3<f32>(
        de(p + e.xyy, scale).x - de(p - e.xyy, scale).x,
        de(p + e.yxy, scale).x - de(p - e.yxy, scale).x,
        de(p + e.yyx, scale).x - de(p - e.yyx, scale).x,
    ));
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let aspect = u.resolution.x / u.resolution.y;
    var uv = in.uv * 2.0 - 1.0;
    uv.x = uv.x * aspect;

    let scale = -1.85 + 0.15 * sin(u.time * 0.1) + u.bass * 0.25;

    // Slow drift head-on through the structure.
    let speed = 0.13 + u.beat * 0.18;
    let z = u.time * speed;
    let ro = vec3<f32>(sin(z * 0.6) * 0.25, cos(z * 0.5) * 0.25, z);
    let fwd = normalize(vec3<f32>(0.15 * cos(z * 0.6), 0.15 * -sin(z * 0.5), 1.0));
    let right = normalize(cross(vec3<f32>(0.0, 1.0, 0.0), fwd));
    let up = cross(fwd, right);
    let rd = normalize(uv.x * right + uv.y * up + fwd * 1.5);

    var t = 0.02;
    var hit = false;
    var trap = 0.0;
    var steps = 0.0;
    for (var i = 0; i < 110; i = i + 1) {
        let p = ro + rd * t;
        let d = de(p, scale);
        if (d.x < 0.0008) {
            hit = true;
            trap = d.y;
            break;
        }
        t = t + d.x * 0.85;
        steps = steps + 1.0;
        if (t > 8.0) {
            break;
        }
    }

    var col = vec3<f32>(0.0);
    if (hit) {
        let p = ro + rd * t;
        let n = calc_normal(p, scale);
        let view = -rd;
        let base = palette(trap * 0.5 + z * 0.04 + u.mid * 0.3);
        let l = normalize(vec3<f32>(0.5, 0.7, -0.5));
        let diff = max(dot(n, l), 0.0);
        let fres = pow(1.0 - max(dot(n, view), 0.0), 2.5);
        let ao = 1.0 - steps / 110.0;
        col = base * (0.18 + diff * 0.8) * ao;
        col = col + base * fres * 1.1;
        col = col + vec3<f32>(1.0) * fres * u.high * 0.5;
    }

    // Heavy fog is what melts it into "soup".
    let fog = 1.0 - exp(-t * 0.18);
    col = mix(col, palette(z * 0.04 + 0.5) * 0.25, fog * 0.7);

    col = col + col * u.beat * 0.3;
    let vig = 1.0 - dot(in.uv - 0.5, in.uv - 0.5) * 0.6;
    col = col * vig;

    return vec4<f32>(col, 1.0);
}
