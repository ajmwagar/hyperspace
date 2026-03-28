// Post-processing: diamond/square pull distortion.
// Corners pull inward along diamond axes, creating a faceted warping effect.
// Bass and amplitude modulate the pull strength.

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
};

@group(0) @binding(0) var<uniform> u: Uniforms;
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

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let centered = in.uv - 0.5;

    // Diamond distance: |x| + |y| gives a diamond/rhombus shape
    let diamond_dist = abs(centered.x) + abs(centered.y);

    // Pull strength increases toward corners, modulated by bass and beat
    let strength = 0.012 * (1.0 + u.bass * 0.6 + u.beat * 0.3);

    // Pull direction: inward along the diamond normal (sign-based axes)
    let sx = sign(centered.x);
    let sy = sign(centered.y);
    // Diagonal pull toward center, weighted by diamond distance
    let pull = vec2<f32>(
        -sx * diamond_dist * strength,
        -sy * diamond_dist * strength
    );

    // Add a subtle rotation over time driven by amplitude
    let angle = u.time * 0.15 * (1.0 + u.amplitude * 0.4);
    let rot_strength = 0.003 * (1.0 + u.mid * 0.5);
    let swirl = vec2<f32>(
        cos(angle) * centered.y - sin(angle) * centered.x,
        sin(angle) * centered.x + cos(angle) * centered.y
    ) * rot_strength;

    let flow = pull + swirl;
    let warped = clamp(in.uv + flow, vec2<f32>(0.001), vec2<f32>(0.999));
    let prev = textureSample(prev_frame, prev_sampler, warped);

    let decay = 0.95 + u.bass * 0.02;
    return vec4<f32>(prev.rgb * decay, 1.0);
}
