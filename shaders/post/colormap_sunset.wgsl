// Post-processing: sunset colormap.
// Maps brightness to a warm orange/pink/purple gradient.
// Beat pulses shift the palette for a living sunset feel.

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
    let prev = textureSample(prev_frame, prev_sampler, in.uv);
    let brightness = dot(prev.rgb, vec3<f32>(0.299, 0.587, 0.114));

    // Drift offset with beat-driven pulse
    let offset = u.time * 0.025 + u.beat * 0.08 + u.onset * 0.1;
    let t = fract(brightness + offset);

    // Sunset gradient: deep purple -> magenta/pink -> warm orange -> golden yellow
    let purple = vec3<f32>(0.2, 0.05, 0.3);
    let pink = vec3<f32>(0.8, 0.2, 0.4);
    let orange = vec3<f32>(0.95, 0.5, 0.1);
    let gold = vec3<f32>(1.0, 0.85, 0.3);

    // Four-stop gradient
    var mapped: vec3<f32>;
    if t < 0.33 {
        mapped = mix(purple, pink, t / 0.33);
    } else if t < 0.66 {
        mapped = mix(pink, orange, (t - 0.33) / 0.33);
    } else {
        mapped = mix(orange, gold, (t - 0.66) / 0.34);
    }

    // Warmth boost on bass hits
    let warmth = 1.0 + u.bass * 0.2;
    mapped = mapped * vec3<f32>(warmth, 1.0, 1.0 / warmth);

    // Blend based on brightness
    let blend = smoothstep(0.8, 0.3, brightness);
    let result = mix(prev.rgb, mapped * brightness * 2.0, blend);

    return vec4<f32>(result, 1.0);
}
