// Ripples — physics-y water surface. Raindrops fall and each sends out an
// expanding, decaying wave packet; overlapping rings interfere like a real
// ripple tank. The surface is then shaded as water: normals from the wave
// slope give sun sparkle, and the wave curvature focuses light into caustic
// veins on the floor. Bass = more/bigger drops, amplitude swells the waves,
// beats drop a big splash.

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

fn hash2(p: vec2<f32>) -> vec2<f32> {
    let q = vec2<f32>(dot(p, vec2<f32>(127.1, 311.7)), dot(p, vec2<f32>(269.5, 183.3)));
    return fract(sin(q) * 43758.5453);
}

// Water surface height = sum of expanding wave packets from recent raindrops.
fn wave_height(uv: vec2<f32>, aspect: f32) -> f32 {
    let rate = 3.2 + u.bass * 3.5;          // drops per second
    let cur = floor(u.time * rate);
    let amp = 0.075 * (0.5 + u.amplitude * 1.3);
    var h = 0.0;
    for (var k = 0; k < 12; k = k + 1) {
        let slot = cur - f32(k);
        let age = u.time - slot / rate;
        let rnd = hash2(vec2<f32>(slot, 3.7));
        let pos = vec2<f32>(0.12 + 0.76 * rnd.x, 0.12 + 0.76 * rnd.y);
        var d = uv - pos;
        d.x = d.x * aspect;
        let r = length(d);
        let speed = 0.30;
        let front = speed * age;
        // Expanding ring envelope (Gaussian around the wavefront) × time decay.
        let env = exp(-age * 1.4) * exp(-((r - front) * (r - front)) / 0.004);
        h = h + amp * sin((r - front) * 55.0) * env;
    }
    return h;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let aspect = u.resolution.x / u.resolution.y;
    let uv = in.uv;
    let e = 0.0025;

    let h = wave_height(uv, aspect);
    let hxp = wave_height(uv + vec2<f32>(e, 0.0), aspect);
    let hxm = wave_height(uv - vec2<f32>(e, 0.0), aspect);
    let hyp = wave_height(uv + vec2<f32>(0.0, e), aspect);
    let hym = wave_height(uv - vec2<f32>(0.0, e), aspect);

    // Surface slope → normal (scaled so the water isn't impossibly steep).
    let sx = (hxm - hxp) / (2.0 * e);
    let sy = (hym - hyp) / (2.0 * e);
    let n = normalize(vec3<f32>(sx * 0.05, sy * 0.05, 1.0));

    // Curvature (Laplacian) — concave dimples focus light → caustics.
    let curv = (hxp + hxm + hyp + hym - 4.0 * h);

    // Deep-water gradient.
    let depth = uv.y;
    let deep = mix(vec3<f32>(0.0, 0.12, 0.26), vec3<f32>(0.0, 0.30, 0.46), depth);

    // Sun glints off the wave slopes.
    let sun = normalize(vec3<f32>(0.35, 0.55, 0.75));
    let spec = pow(max(dot(n, sun), 0.0), 80.0);

    // Caustic veins where the surface focuses light.
    var caustic = clamp(-curv * 850.0, 0.0, 1.0);
    caustic = pow(caustic, 1.3);

    var col = deep;
    col = col + vec3<f32>(0.5, 0.85, 1.0) * caustic * (1.6 + u.amplitude * 1.5);
    col = col + vec3<f32>(1.0, 1.0, 0.95) * spec * 3.0;
    col = col + deep * clamp(h * 6.0, -0.3, 0.6); // crest/trough shading
    col = col + vec3<f32>(0.4, 0.7, 0.9) * caustic * u.beat * 0.8;

    let vig = 1.0 - dot(uv - 0.5, uv - 0.5) * 0.55;
    col = col * vig;

    return vec4<f32>(max(col, vec3<f32>(0.0)), 1.0);
}
