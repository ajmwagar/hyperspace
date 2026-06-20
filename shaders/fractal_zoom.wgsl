// Fractal Zoom — an animated Julia set that morphs, breathes and cycles colour.
// The whole frame fills with fractal dendrites (no big black interior like the
// Mandelbrot), so it reads as a hypnotic, ever-shifting bloom. Bass reshapes
// the set, mids drive the palette, beats flash it, and a slow breathing zoom
// keeps it loop-friendly for Reels.

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
    let d = vec3<f32>(0.0, 0.33, 0.67);
    return a + b * cos(6.28318 * (c * t + d));
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let aspect = u.resolution.x / u.resolution.y;
    var uv = in.uv * 2.0 - 1.0;
    uv.x = uv.x * aspect;

    // Breathing zoom + slow rotation keep it alive and loopable.
    let zoom = 1.3 * exp(-0.2 * sin(u.time * 0.2) - u.bass * 0.3);
    let rot = u.time * 0.05;
    let cr = cos(rot);
    let sr = sin(rot);
    var z = vec2<f32>(uv.x * cr - uv.y * sr, uv.x * sr + uv.y * cr) * zoom;

    // A classic dendrite Julia constant, gently morphing — gives crisp
    // filaments that fill the frame rather than a pale blob.
    let c = vec2<f32>(-0.8, 0.156)
        + 0.05 * vec2<f32>(cos(u.time * 0.2), sin(u.time * 0.25))
        + u.bass * 0.03;

    var i = 0;
    let maxi = 160;
    // Orbit trap: track closest approach to the origin for richer colour.
    var trap = 1e9;
    for (; i < maxi; i = i + 1) {
        // z = z^2 + c
        z = vec2<f32>(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
        trap = min(trap, dot(z, z));
        if (dot(z, z) > 64.0) {
            break;
        }
    }

    let mag = dot(z, z);
    // Smooth iteration count for banding without stair-steps.
    let smooth_i = f32(i) - log2(max(0.5 * log2(max(mag, 1.0001)), 1e-4));

    var col: vec3<f32>;
    if (i >= maxi) {
        // Interior: dark, tinted by the orbit trap so it isn't flat black.
        col = palette(0.6 + sqrt(trap)) * 0.18;
    } else {
        // Escape bands — higher frequency = more vivid colour rings.
        let t = smooth_i * 0.07 + sqrt(trap) * 0.3 + u.time * 0.05 + u.mid * 0.3;
        col = palette(t);
        // Crisp bright filaments near the escape boundary.
        let fil = pow(smooth_i / f32(maxi), 0.4);
        col = col * (0.5 + fil * 1.3);
    }

    col = col * (0.85 + u.amplitude * 0.5);
    col = col + col * u.beat * 0.6;

    return vec4<f32>(col, 1.0);
}
