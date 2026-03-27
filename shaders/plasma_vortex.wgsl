// Plasma Vortex — swirling plasma tendrils that react to audio.
// Bass drives rotation speed, mids control color shift, highs add fractal detail.
// Beat pulses invert the vortex direction momentarily.

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

fn rot2(a: f32) -> mat2x2<f32> {
    let c = cos(a);
    let s = sin(a);
    return mat2x2<f32>(c, -s, s, c);
}

fn plasma(p: vec2<f32>, t: f32) -> f32 {
    var v = 0.0;
    var q = p;
    v += sin(q.x * 10.0 + t);
    v += sin(10.0 * (q.x * sin(t * 0.5) + q.y * cos(t * 0.33)) + t);
    let cx = q.x + 0.5 * sin(t * 0.2);
    let cy = q.y + 0.5 * cos(t * 0.37);
    v += sin(sqrt(100.0 * (cx * cx + cy * cy) + 1.0) + t);
    v += sin(sqrt(q.x * q.x + q.y * q.y) * 8.0 - t * 2.0);
    return v * 0.25;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let uv = (in.uv - 0.5) * 2.0;
    let aspect = u.resolution.x / u.resolution.y;
    var p = vec2<f32>(uv.x * aspect, uv.y);

    // Polar warp
    let angle = atan2(p.y, p.x);
    let radius = length(p);

    // Vortex rotation: bass drives speed, beat reverses
    let spin_dir = mix(1.0, -1.0, smoothstep(0.5, 1.0, u.beat));
    let spin_speed = 0.5 + u.bass * 3.0;
    let vortex_angle = angle + u.time * spin_speed * spin_dir + radius * 3.0 * sin(u.time * 0.3);

    // Reconstruct from warped polar
    let warped = vec2<f32>(cos(vortex_angle), sin(vortex_angle)) * radius;

    // Multi-octave plasma
    var p1 = plasma(warped * 1.0, u.time * 0.7);
    var p2 = plasma(warped * 2.0 + 3.7, u.time * 1.1 + 100.0);
    var p3 = plasma(warped * 4.0 - 1.3, u.time * 0.5 + 200.0);

    // High frequencies add fractal detail
    let detail = p3 * u.high * 2.0;
    let combined = p1 + p2 * 0.5 + detail;

    // Color palette — mid controls hue rotation
    let hue_shift = u.mid * 2.0 + u.time * 0.1;
    let r = sin(combined * 3.14159 + hue_shift) * 0.5 + 0.5;
    let g = sin(combined * 3.14159 + hue_shift + 2.094) * 0.5 + 0.5;
    let b = sin(combined * 3.14159 + hue_shift + 4.189) * 0.5 + 0.5;

    var col = vec3<f32>(r, g, b);

    // Amplitude drives overall brightness
    col *= 0.3 + u.amplitude * 3.0;

    // Beat flash — hot white center pulse
    let flash_radius = u.beat * (1.0 - radius);
    col += vec3<f32>(1.0, 0.9, 0.7) * flash_radius * 0.5;

    // Vignette
    let vig = 1.0 - radius * 0.4;
    col *= vig;

    // Spectrum ring: map spectrum bins around the vortex center
    let spec_angle = (angle + 3.14159) / (2.0 * 3.14159); // 0..1
    let spec_idx = u32(spec_angle * 128.0);
    var spec_val = 0.0;
    if spec_idx < 512u {
        spec_val = spectrum[spec_idx];
    }
    let ring_width = 0.02 + spec_val * 0.3;
    let ring_dist = abs(radius - 0.6 - spec_val * 0.2);
    let ring = smoothstep(ring_width, 0.0, ring_dist);
    col += vec3<f32>(0.3, 0.7, 1.0) * ring * 0.4;

    return vec4<f32>(col, 1.0);
}
