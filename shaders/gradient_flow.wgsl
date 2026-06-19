// Gradient Flow — ShaderGradient-inspired flowing mesh gradient.
// A soft, domain-warped color field that slowly morphs and breathes.
// Bass drives the warp intensity, mids cycle the palette, highs add grain.
// Inspired by the shadergradient.co aesthetic: smooth, organic, premium.

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

fn hash(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}

// Smooth value noise
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
    for (var i = 0; i < 5; i = i + 1) {
        v = v + amp * noise(p);
        p = p * 2.02 + vec2<f32>(1.7, 9.2);
        amp = amp * 0.5;
    }
    return v;
}

// Inigo Quilez cosine palette — smooth, designer-friendly gradients
fn palette(t: f32) -> vec3<f32> {
    let a = vec3<f32>(0.5, 0.5, 0.5);
    let b = vec3<f32>(0.5, 0.5, 0.5);
    let c = vec3<f32>(1.0, 1.0, 1.0);
    let d = vec3<f32>(0.00, 0.33, 0.67);
    return a + b * cos(6.28318 * (c * t + d));
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let aspect = u.resolution.x / u.resolution.y;
    var p = vec2<f32>((in.uv.x - 0.5) * aspect, in.uv.y - 0.5);

    let t = u.time * 0.08;

    // Domain warp — the heart of the flowing-mesh look. Two layers of fbm
    // displace the lookup so the gradient appears to swirl like liquid glass.
    let warp_amt = 0.6 + u.bass * 1.6 + u.sub_bass * 0.8;
    let q = vec2<f32>(
        fbm(p * 1.5 + vec2<f32>(0.0, t)),
        fbm(p * 1.5 + vec2<f32>(5.2, 1.3 - t)),
    );
    let r = vec2<f32>(
        fbm(p * 1.5 + q * warp_amt + vec2<f32>(1.7 + t, 9.2)),
        fbm(p * 1.5 + q * warp_amt + vec2<f32>(8.3, 2.8 - t * 0.7)),
    );

    let field = fbm(p * 1.5 + r * warp_amt);

    // Warp the screen-space coordinate by the flow vectors, then sweep the
    // palette diagonally across it. The broad spatial term is what gives the
    // smooth multi-colour mesh-gradient look; the warp makes it flow.
    let g = in.uv + (r - 0.5) * warp_amt;
    let hue = g.x * 0.55 + g.y * 0.35 + field * 0.25
        + u.time * 0.04 + u.mid * 0.4;
    var col = palette(hue);

    // Blend a second, offset palette sample for richer two-tone transitions
    let col2 = palette(hue + 0.35 + u.amplitude * 0.2);
    col = mix(col, col2, smoothstep(0.2, 0.8, field));

    // Gentle vignette keeps the focus centered, like a soft studio backdrop
    let vig = 1.0 - dot(p, p) * 0.35;
    col = col * vig;

    // Subtle breathing brightness so it feels alive even when quiet
    col = col * (0.85 + 0.15 * sin(u.time * 0.5) + u.amplitude * 0.5);

    // Fine film grain — highs/presence sparkle, classic ShaderGradient grain
    let grain = (hash(in.uv * u.resolution + u.time) - 0.5);
    col = col + grain * (0.03 + u.high * 0.08 + u.presence * 0.05);

    return vec4<f32>(col, 1.0);
}
