// Fractal Pulse — Julia set fractal that breathes with audio.
// Bass morphs the fractal seed, amplitude controls iteration depth glow,
// beat triggers color inversion and seed jumps. Spectrum data textures
// the escape-time coloring.

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

fn complex_mul(a: vec2<f32>, b: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
}

fn palette(t: f32, a: vec3<f32>, b: vec3<f32>, c: vec3<f32>, d: vec3<f32>) -> vec3<f32> {
    return a + b * cos(6.28318 * (c * t + d));
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let uv = (in.uv - 0.5) * 2.0;
    let aspect = u.resolution.x / u.resolution.y;
    var p = vec2<f32>(uv.x * aspect, uv.y);

    // Zoom: slowly pulse in and out, amplitude modulates
    let zoom = 1.5 + sin(u.time * 0.2) * 0.3 + u.amplitude * 0.5;
    p *= zoom;

    // Pan slowly
    p += vec2<f32>(sin(u.time * 0.07) * 0.3, cos(u.time * 0.11) * 0.2);

    // Julia set constant — bass morphs the seed
    let seed_angle = u.time * 0.15 + u.bass * 2.0;
    let seed_radius = 0.7885 + sin(u.time * 0.3) * 0.05 + u.mid * 0.1 + u.presence * 0.05;
    var c = vec2<f32>(cos(seed_angle), sin(seed_angle)) * seed_radius;

    // Beat/onset: sudden seed jump
    if u.onset > 0.7 {
        c += vec2<f32>(sin(u.time * 37.0), cos(u.time * 43.0)) * 0.05 * u.onset;
    }

    // Iterate Julia set
    var z = p;
    let max_iter = 64;
    var iter = 0;
    var escaped = false;
    var smooth_iter = 0.0;
    var orbit_trap = 100.0; // closest approach to origin

    for (var i = 0; i < max_iter; i++) {
        z = complex_mul(z, z) + c;

        let d = dot(z, z);
        orbit_trap = min(orbit_trap, length(z - vec2<f32>(0.0, 0.0)));

        if d > 256.0 {
            // Smooth iteration count
            smooth_iter = f32(i) - log2(log2(d)) + 4.0;
            escaped = true;
            iter = i;
            break;
        }
        iter = i;
    }

    var col: vec3<f32>;

    if escaped {
        let t = smooth_iter / f32(max_iter);

        // Spectrum-driven coloring: use spectrum data to shift palette
        let spec_idx = u32(t * 128.0);
        var spec_mod = 0.0;
        if spec_idx < 512u {
            spec_mod = spectrum[spec_idx] * 1.0;
        }

        // Iq palette with audio modulation
        let hue_shift = u.time * 0.05 + u.mid * 0.5 + spec_mod;
        col = palette(
            t + hue_shift,
            vec3<f32>(0.5, 0.5, 0.5),
            vec3<f32>(0.5, 0.5, 0.5),
            vec3<f32>(1.0, 1.0, 1.0),
            vec3<f32>(0.0 + u.bass * 0.3, 0.33 + u.mid * 0.2, 0.67 + u.high * 0.3)
        );

        // Orbit trap glow
        let trap_glow = exp(-orbit_trap * 3.0);
        col += vec3<f32>(1.0, 0.5, 0.2) * trap_glow * 0.3;

        // Brightness from amplitude
        col *= 0.5 + u.amplitude * 2.5;

    } else {
        // Interior: dark with subtle orbit trap coloring
        let trap_color = exp(-orbit_trap * 2.0);
        col = vec3<f32>(0.1, 0.0, 0.15) * (1.0 + trap_color);

        // High frequency detail in interior
        col += vec3<f32>(0.0, 0.05, 0.1) * u.high * 3.0 * trap_color;
    }

    // Beat inversion flash
    if u.beat > 0.6 {
        let inv_amount = (u.beat - 0.6) * 2.5; // 0..1
        col = mix(col, vec3<f32>(1.0) - col, inv_amount * 0.4);
        // Hot rim
        col += vec3<f32>(1.0, 0.8, 0.5) * inv_amount * 0.15;
    }

    // Radial glow at center
    let center_dist = length(uv);
    let glow = exp(-center_dist * 2.0) * u.amplitude * 0.3;
    col += vec3<f32>(0.5, 0.3, 1.0) * glow;

    // Subtle CRT curvature
    let cuv = in.uv * 2.0 - 1.0;
    let barrel = 1.0 + dot(cuv, cuv) * 0.02;
    let vig = 1.0 - dot(cuv, cuv) * 0.3;
    col *= vig;

    // Scanline hint
    let scan = 0.97 + 0.03 * sin(in.uv.y * u.resolution.y * 2.0);
    col *= scan;

    return vec4<f32>(col, 1.0);
}
