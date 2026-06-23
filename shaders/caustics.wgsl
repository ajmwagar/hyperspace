// Caustics — dreamy underwater pool-floor light. Rippling caustic veins drift
// over a deep-water gradient with a slow surface sway and god-ray shimmer.
// Amplitude/bass drive the ripple speed and brightness, mids tint the water,
// beats send a bright caustic flash across the floor. Calm, gorgeous, non-fractal.

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
    let d = vec3<f32>(0.25, 0.45, 0.65); // cool, watery
    return a + b * cos(6.28318 * (c * t + d));
}

// Iterative caustic field (the classic "water caustic" formulation): a point
// is repeatedly folded by sin/cos of itself and the reciprocal distance is
// accumulated, producing bright tangled veins like refracted sunlight.
fn caustic(uv: vec2<f32>, time: f32, seed: f32) -> f32 {
    let TAU = 6.28318;
    // The large offset is what tips the sin/cos folding into chaotic, tangled
    // caustic veins rather than a smooth field.
    var p = (uv * TAU) % vec2<f32>(TAU) - 250.0 + seed;
    var iv = p;
    var c = 1.0;
    let inten = 0.005;
    for (var n = 0; n < 6; n = n + 1) {
        let t = time * (1.0 - 3.5 / f32(n + 1));
        iv = p + vec2<f32>(
            cos(t - iv.x) + sin(t + iv.y),
            sin(t - iv.y) + cos(t + iv.x),
        );
        let denom = vec2<f32>(
            p.x / (sin(iv.x + t) / inten),
            p.y / (cos(iv.y + t) / inten),
        );
        c = c + 1.0 / max(length(denom), 1e-4);
    }
    c = c / 6.0;
    c = 1.17 - pow(c, 1.4);
    return clamp(pow(abs(c), 8.0), 0.0, 1.0);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let aspect = u.resolution.x / u.resolution.y;
    // Sample space (a couple of caustic tiles across the frame); a gentle drift
    // makes the whole pool sway.
    var p = in.uv * vec2<f32>(aspect, 1.0) * 1.6;
    p = p + vec2<f32>(sin(u.time * 0.15) * 0.05, cos(u.time * 0.12) * 0.05);

    let speed = 0.5 + u.amplitude * 0.8 + u.bass * 0.6;
    let t = u.time * speed;

    // Two layers at slightly different scales for richer water.
    let b1 = caustic(p, t, 0.0);
    let b2 = caustic(p * 1.7, t * 0.9, 30.0);
    let bright = clamp(b1 + b2 * 0.5, 0.0, 1.0);

    // Deep-water vertical gradient (darker near the surface, lit on the floor).
    let depth = in.uv.y;
    let water = mix(vec3<f32>(0.01, 0.10, 0.22), vec3<f32>(0.02, 0.28, 0.42), depth);

    // Caustic veins: cool white tinted by the mids.
    let tint = mix(vec3<f32>(0.7, 0.95, 1.0), palette(u.mid * 0.5 + u.time * 0.03), 0.35);
    var col = water + tint * bright * (0.7 + u.amplitude * 0.6);

    // Beat sends a brighter shimmer through the whole floor.
    col = col + tint * bright * u.beat * 0.4;

    // Faint god-ray shafts angling down through the water.
    let ray = pow(0.5 + 0.5 * sin((in.uv.x - in.uv.y) * 14.0 + u.time * 0.6), 6.0);
    col = col + vec3<f32>(0.3, 0.55, 0.7) * ray * (0.05 + u.high * 0.1) * depth;

    // Soft vignette + surface brightening at the top.
    let vig = 1.0 - dot(in.uv - 0.5, in.uv - 0.5) * 0.6;
    col = col * vig;

    return vec4<f32>(col, 1.0);
}
