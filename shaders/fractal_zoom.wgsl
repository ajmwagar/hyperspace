// Fractal Dive — an endless zoom into the Mandelbrot set (distinct from
// fractal_pulse, which morphs a full-screen Julia in place). The camera dives
// into the Seahorse Valley and breathes back out, revealing self-similar
// mini-brots and spirals at every depth. Distance-estimate shading keeps the
// filaments razor-crisp; bass deepens the dive, mids cycle the palette, beats
// flash. Loops via the in/out breathing so it tiles cleanly for Reels.

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

fn cmul(a: vec2<f32>, b: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let aspect = u.resolution.x / u.resolution.y;
    var uv = in.uv * 2.0 - 1.0;
    uv.x = uv.x * aspect;

    // A famous deep-zoom coordinate in the Seahorse Valley.
    let focus = vec2<f32>(-0.743643887037, 0.131825904205);

    // Breathing log-zoom: dive in to ~e^12 magnification and back, so it loops.
    let depth = mix(1.5, 12.0, 0.5 - 0.5 * cos(u.time * 0.16)) + u.bass * 1.5;
    let scale = exp(-depth);

    // Slow rotation for extra motion.
    let rot = u.time * 0.03;
    let cr = cos(rot);
    let sr = sin(rot);
    let ruv = vec2<f32>(uv.x * cr - uv.y * sr, uv.x * sr + uv.y * cr);
    let c = focus + ruv * scale;

    // Iterate with the derivative for a distance estimate (crisp filaments).
    var z = vec2<f32>(0.0, 0.0);
    var dz = vec2<f32>(1.0, 0.0);
    var i = 0;
    let maxi = 256;
    for (; i < maxi; i = i + 1) {
        dz = 2.0 * cmul(z, dz) + vec2<f32>(1.0, 0.0);
        z = cmul(z, z) + c;
        if (dot(z, z) > 1.0e6) {
            break;
        }
    }

    var col: vec3<f32>;
    let m2 = dot(z, z);
    if (i >= maxi) {
        // Interior — near black so the boundary detail pops.
        col = vec3<f32>(0.02, 0.0, 0.04);
    } else {
        // Smooth iteration + Böttcher distance estimate.
        let smooth_i = f32(i) - log2(max(0.5 * log2(max(m2, 1.0001)), 1e-4));
        let dist = 0.5 * sqrt(m2) * log(max(m2, 1.0001)) / max(length(dz), 1e-6);
        // Pixel size in fractal space → crisp, resolution-independent edges.
        let px = scale * 2.0 / u.resolution.y;
        let edge = clamp(dist / px, 0.0, 1.0);

        let t = smooth_i * 0.06 + depth * 0.05 + u.time * 0.04 + u.mid * 0.3;
        col = palette(t) * edge;
        // Bright filament right at the boundary.
        col = col + palette(t + 0.5) * (1.0 - edge) * 0.6;
    }

    col = col * (0.85 + u.amplitude * 0.5);
    col = col + col * u.beat * 0.6;

    return vec4<f32>(col, 1.0);
}
