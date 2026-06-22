// sim/wave.wgsl — stateful water-surface simulation (discrete wave equation).
// Lives in a float sim buffer (the `sim` multi-buffer pipeline). Reads its own
// previous state at binding 5 (buf0): r = height(t), g = height(t-1). Each step:
//   h_next = (2h - h_prev) + c²·∇²h , then a touch of damping.
// Audio INJECTS energy (raindrops on the beat / bass); the wave equation then
// carries it on — ripples expand, interfere, reflect off the walls and slowly
// fade, with real memory. The display pass (water_shade.wgsl) shades buf0.

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
@group(0) @binding(3) var samp: sampler;
@group(0) @binding(5) var buf0: texture_2d<f32>;

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

fn height_at(uv: vec2<f32>) -> f32 {
    return textureSampleLevel(buf0, samp, uv, 0.0).x;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let dim = vec2<f32>(textureDimensions(buf0));
    let texel = 1.0 / dim;
    let uv = in.uv;

    let c = textureSampleLevel(buf0, samp, uv, 0.0).xy; // (h, h_prev)
    let h = c.x;
    let hp = c.y;

    // ∇²h (5-point Laplacian). ClampToEdge sampling makes the walls reflect.
    let lap = height_at(uv + vec2<f32>(texel.x, 0.0))
        + height_at(uv - vec2<f32>(texel.x, 0.0))
        + height_at(uv + vec2<f32>(0.0, texel.y))
        + height_at(uv - vec2<f32>(0.0, texel.y))
        - 4.0 * h;

    // Wave step (c² = 0.30 keeps it well under the CFL limit) + slow damping.
    var hn = (2.0 * h - hp) + 0.30 * lap;
    hn = hn * 0.9985;

    // --- Energy injection: raindrops. A brief impulse at the start of each
    // time-slot; afterwards the equation propagates it on its own. ---
    let rate = 1.6 + u.bass * 3.0;
    let slot = floor(u.time * rate);
    let age = fract(u.time * rate);
    let impulse = exp(-age * 45.0);                 // sharp → ~single kick
    let rnd = hash2(vec2<f32>(slot, 3.7));
    let dpos = vec2<f32>(0.15 + 0.70 * rnd.x, 0.15 + 0.70 * rnd.y);
    let dd = distance(uv, dpos);
    hn = hn + impulse * exp(-dd * dd / 0.0004) * (0.35 + u.amplitude * 0.6);

    // Onset/beat throws a bigger splash at a second moving spot.
    let bpos = vec2<f32>(0.5 + 0.3 * sin(u.time * 0.6), 0.5 + 0.3 * cos(u.time * 0.5));
    let bd = distance(uv, bpos);
    hn = hn + u.onset * exp(-bd * bd / 0.0009) * 0.8;

    hn = clamp(hn, -3.0, 3.0);
    return vec4<f32>(hn, h, 0.0, 1.0);
}
