// Post-processing: warm color grade. Not a full palette remap —
// just a subtle push toward warm tones. Like golden hour light.

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
    var col = textureSample(prev_frame, prev_sampler, in.uv).rgb;

    // Warm push: boost reds/oranges slightly, cool blues slightly
    col.r *= 1.05 + u.bass * 0.03;
    col.g *= 1.0;
    col.b *= 0.92 + u.presence * 0.02;

    // Slight contrast lift
    col = (col - 0.5) * 1.08 + 0.5;
    col = clamp(col, vec3<f32>(0.0), vec3<f32>(1.0));

    // Subtle vignette
    let d = length(in.uv - 0.5) * 1.3;
    col *= 1.0 - d * d * 0.15;

    return vec4<f32>(col, 1.0);
}
