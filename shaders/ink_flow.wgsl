// Ink Flow — coloured ink/dye swirling in water, a curl-noise fluid in the
// feedback buffer. Each frame advects the previous dye along a divergence-free
// velocity field and injects fresh ink from drifting emitters; onsets squirt a
// burst. Slow, organic, oddly-satisfying — pairs beautifully with ambient/lofi.

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
@group(0) @binding(3) var prev_sampler: sampler;
@group(0) @binding(4) var prev_frame: texture_2d<f32>;

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

fn hash(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}

fn noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let a = hash(i);
    let b = hash(i + vec2<f32>(1.0, 0.0));
    let c = hash(i + vec2<f32>(0.0, 1.0));
    let d = hash(i + vec2<f32>(1.0, 1.0));
    let s = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, s.x), mix(c, d, s.x), s.y);
}

fn fbm(p_in: vec2<f32>) -> f32 {
    var p = p_in;
    var v = 0.0;
    var amp = 0.5;
    for (var i = 0; i < 4; i = i + 1) {
        v = v + amp * noise(p);
        p = p * 2.0 + vec2<f32>(3.1, 1.7);
        amp = amp * 0.5;
    }
    return v;
}

fn palette(t: f32) -> vec3<f32> {
    let a = vec3<f32>(0.5, 0.5, 0.5);
    let b = vec3<f32>(0.5, 0.5, 0.5);
    let c = vec3<f32>(1.0, 1.0, 1.0);
    let d = vec3<f32>(0.0, 0.33, 0.67);
    return a + b * cos(6.28318 * (c * t + d));
}

// Divergence-free velocity = curl of a scalar noise potential.
fn velocity(p: vec2<f32>) -> vec2<f32> {
    let e = 0.01;
    let n_dy = fbm(p + vec2<f32>(0.0, e)) - fbm(p - vec2<f32>(0.0, e));
    let n_dx = fbm(p + vec2<f32>(e, 0.0)) - fbm(p - vec2<f32>(e, 0.0));
    return vec2<f32>(n_dy, -n_dx) / (2.0 * e);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let uv = in.uv;
    let aspect = u.resolution.x / u.resolution.y;

    // Curl-noise field, slowly evolving.
    let v = velocity(uv * 3.0 + vec2<f32>(0.0, u.time * 0.05));
    let flow = 0.0016 * (1.0 + u.bass * 1.5);

    // Advect: pull dye from upstream, with a small cross-tap blur so the ink
    // diffuses and feathers like real dye in water (vs acid_melt's hard warp).
    let src = uv - v * flow;
    let tx = 1.4 / u.resolution;
    var dye = textureSample(prev_frame, prev_sampler, src).rgb * 0.4;
    dye = dye + textureSample(prev_frame, prev_sampler, src + vec2<f32>(tx.x, 0.0)).rgb * 0.15;
    dye = dye + textureSample(prev_frame, prev_sampler, src - vec2<f32>(tx.x, 0.0)).rgb * 0.15;
    dye = dye + textureSample(prev_frame, prev_sampler, src + vec2<f32>(0.0, tx.y)).rgb * 0.15;
    dye = dye + textureSample(prev_frame, prev_sampler, src - vec2<f32>(0.0, tx.y)).rgb * 0.15;
    dye = dye * 0.992;

    // Two drifting emitters squirt coloured ink continuously.
    for (var k = 0; k < 2; k = k + 1) {
        let fk = f32(k);
        let pos = vec2<f32>(
            0.5 + 0.3 * sin(u.time * (0.3 + 0.1 * fk) + fk * 2.0),
            0.5 + 0.3 * cos(u.time * (0.25 + 0.12 * fk) + fk * 4.0),
        );
        let d = length((uv - pos) * vec2<f32>(aspect, 1.0));
        let drop = smoothstep(0.05, 0.0, d);
        dye = dye + palette(u.time * 0.08 + fk * 0.5) * drop * 0.5;
    }

    // Onset squirts a bright burst at a hashed location.
    let burst_pos = vec2<f32>(hash(vec2<f32>(floor(u.time * 2.0), 1.0)),
                              hash(vec2<f32>(floor(u.time * 2.0), 7.0)));
    let bd = length((uv - burst_pos) * vec2<f32>(aspect, 1.0));
    dye = dye + palette(u.time * 0.2 + 0.4) * smoothstep(0.07, 0.0, bd) * u.onset * 1.2;

    dye = clamp(dye, vec3<f32>(0.0), vec3<f32>(1.4));
    return vec4<f32>(dye, 1.0);
}
