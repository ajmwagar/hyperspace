// Post-processing: horizontal mirror.
// Left half is reflected to the right, with a beat-driven split line.
// Creates symmetrical kaleidoscope-like imagery.

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
    // Beat-driven split offset: the mirror line wobbles slightly with beat
    let split_offset = u.beat * 0.02 + sin(u.time * 0.3) * 0.005 + u.onset * 0.03;
    let split = 0.5 + split_offset;

    // Mirror: if on the right side, reflect the x coordinate
    var mirror_uv = in.uv;
    if mirror_uv.x > split {
        mirror_uv.x = split - (mirror_uv.x - split);
    }

    // Clamp to valid range
    mirror_uv = clamp(mirror_uv, vec2<f32>(0.001), vec2<f32>(0.999));

    let prev = textureSample(prev_frame, prev_sampler, mirror_uv);

    // Subtle glow line at the split boundary
    let dist_to_split = abs(in.uv.x - split);
    let line_width = 0.003 + u.beat * 0.004;
    let line_glow = smoothstep(line_width, 0.0, dist_to_split);

    // Line color pulses with bass
    let line_color = vec3<f32>(0.8 + u.bass * 0.2, 0.9, 1.0) * line_glow * 0.5;

    let result = prev.rgb + line_color;

    return vec4<f32>(result, 1.0);
}
