// Reaction Diffusion — Gray-Scott system, a TouchDesigner feedback staple.
// The feedback buffer doubles as simulation state and display:
//   stored.r = 1 - A   (so the A=1 substrate reads as black)
//   stored.g = B        (the growing chemical — the visible pattern)
// Permanent seed points keep the reaction perpetually fed, and audio onsets
// inject fresh blobs, so beats spawn new organic growth on a dark field.

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

// Reconstruct (A, B) from a stored texel: r holds 1-A, g holds B.
fn read_ab(uv: vec2<f32>) -> vec2<f32> {
    let s = textureSample(prev_frame, prev_sampler, uv).xy;
    return vec2<f32>(1.0 - s.x, s.y);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let texel = 1.0 / u.resolution;

    let c = read_ab(in.uv);
    var a = c.x;
    var b = c.y;

    // Laplacian on reconstructed A,B with a standard 9-point stencil.
    var sum = vec2<f32>(0.0);
    sum = sum + read_ab(in.uv + vec2<f32>(-texel.x, 0.0)) * 0.2;
    sum = sum + read_ab(in.uv + vec2<f32>(texel.x, 0.0)) * 0.2;
    sum = sum + read_ab(in.uv + vec2<f32>(0.0, -texel.y)) * 0.2;
    sum = sum + read_ab(in.uv + vec2<f32>(0.0, texel.y)) * 0.2;
    sum = sum + read_ab(in.uv + vec2<f32>(-texel.x, -texel.y)) * 0.05;
    sum = sum + read_ab(in.uv + vec2<f32>(texel.x, -texel.y)) * 0.05;
    sum = sum + read_ab(in.uv + vec2<f32>(-texel.x, texel.y)) * 0.05;
    sum = sum + read_ab(in.uv + vec2<f32>(texel.x, texel.y)) * 0.05;
    let lap = sum - c;

    // Gray-Scott update. Feed/kill wander with the mix for variety.
    let da = 1.0;
    let db = 0.5;
    let feed = 0.0545 + u.mid * 0.006;
    let kill = 0.062 + u.high * 0.003;

    // Several iterations per frame so growth is visible at 30-60fps.
    for (var i = 0; i < 6; i = i + 1) {
        let reaction = a * b * b;
        let na = a + (da * lap.x - reaction + feed * (1.0 - a));
        let nb = b + (db * lap.y + reaction - (kill + feed) * b);
        a = clamp(na, 0.0, 1.0);
        b = clamp(nb, 0.0, 1.0);
    }

    // Permanent emitters keep the system self-sustaining no matter the frame.
    // A fairly dense, evenly-spread grid so growth fills the whole field.
    let emitter = hash(floor(in.uv * 34.0));
    if (emitter > 0.972) {
        b = max(b, 0.9);
    }

    // Onset injects a fresh growing blob at a slowly orbiting location.
    let inject_pos = vec2<f32>(
        0.5 + 0.34 * sin(u.time * 0.7),
        0.5 + 0.34 * cos(u.time * 0.9),
    );
    if (distance(in.uv, inject_pos) < 0.035 && u.onset > 0.15) {
        b = 1.0;
    }

    // Display = the stored encoding itself: black substrate, glowing worms.
    // Tint with a touch of blue on B for a bioluminescent feel.
    let store = vec3<f32>(1.0 - a, b, b * (0.5 + u.amplitude));
    return vec4<f32>(store, 1.0);
}
