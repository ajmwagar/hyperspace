// Post-processing: halftone dots.
// Print / comic / TouchDesigner look — reconstructs the image from a rotated
// grid of dots whose radius follows local brightness. Amplitude grows the
// dots, beats rotate the screen angle. Chain after any shader.

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

fn rot(a: f32) -> mat2x2<f32> {
    let c = cos(a);
    let s = sin(a);
    return mat2x2<f32>(c, -s, s, c);
}

// One dot screen: returns coverage [0,1] of a dot whose size tracks `value`.
fn dots(uv: vec2<f32>, angle: f32, freq: f32, value: f32) -> f32 {
    let p = rot(angle) * uv * freq;
    let g = fract(p) - 0.5;
    let d = length(g);
    let radius = sqrt(clamp(value, 0.0, 1.0)) * 0.72;
    return smoothstep(radius, radius - 0.08, d);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let aspect = u.resolution.x / u.resolution.y;
    let uv = vec2<f32>(in.uv.x * aspect, in.uv.y);

    let src = textureSample(prev_frame, prev_sampler, in.uv).rgb;

    // Dot grid frequency; amplitude makes dots bolder by lowering frequency.
    let freq = 90.0 - u.amplitude * 30.0 - u.bass * 20.0;
    let spin = u.beat * 0.4 + u.time * 0.02;

    // Classic CMY-ish screen angles, one per channel, for a colour halftone.
    let r = dots(uv, 0.262 + spin, freq, src.r);
    let g = dots(uv, 1.309 + spin, freq, src.g);
    let b = dots(uv, 0.785 + spin, freq, src.b);

    let col = vec3<f32>(r, g, b);
    return vec4<f32>(col, 1.0);
}
