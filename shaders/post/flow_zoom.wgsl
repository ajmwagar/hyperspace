// Post-processing: breathing zoom pulse.
// Zooms in and out from center with bass-driven pulsation.
// Creates a pumping, breathing trail effect.

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

    // Breathing zoom: sinusoidal pulse with bass driving amplitude
    let breath_rate = 0.8 + u.bass * 1.5;
    let breath = sin(u.time * breath_rate) * 0.5 + 0.5;

    // Zoom factor oscillates between slight zoom-in and zoom-out
    let zoom_amount = 0.006 * (1.0 + u.bass * 0.8 + u.beat * 0.5);
    let zoom = 1.0 + (breath * 2.0 - 1.0) * zoom_amount;

    // Scale UVs from center
    let zoomed_uv = centered * zoom + 0.5;

    let warped = clamp(zoomed_uv, vec2<f32>(0.001), vec2<f32>(0.999));
    let prev = textureSample(prev_frame, prev_sampler, warped);

    let decay = 0.95 + u.amplitude * 0.02;
    return vec4<f32>(prev.rgb * decay, 1.0);
}
