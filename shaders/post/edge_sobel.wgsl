// Post-processing: Sobel edge detection.
// TouchDesigner "Edge TOP" look — outlines the previous pass and drops the
// fills, leaving glowing neon contours on black. Mids set the edge gain,
// highs the line crispness, beats flash the outlines white. Chain after any shader.

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

fn luma(uv: vec2<f32>) -> f32 {
    let c = textureSample(prev_frame, prev_sampler, uv).rgb;
    return dot(c, vec3<f32>(0.299, 0.587, 0.114));
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let texel = (1.0 / u.resolution) * (1.0 + u.high * 1.5);

    // 3x3 Sobel kernels on luminance.
    let tl = luma(in.uv + vec2<f32>(-texel.x, -texel.y));
    let tc = luma(in.uv + vec2<f32>(0.0, -texel.y));
    let tr = luma(in.uv + vec2<f32>(texel.x, -texel.y));
    let ml = luma(in.uv + vec2<f32>(-texel.x, 0.0));
    let mr = luma(in.uv + vec2<f32>(texel.x, 0.0));
    let bl = luma(in.uv + vec2<f32>(-texel.x, texel.y));
    let bc = luma(in.uv + vec2<f32>(0.0, texel.y));
    let br = luma(in.uv + vec2<f32>(texel.x, texel.y));

    let gx = (tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl);
    let gy = (bl + 2.0 * bc + br) - (tl + 2.0 * tc + tr);
    let g = sqrt(gx * gx + gy * gy);

    let gain = 1.0 + u.mid * 3.0;
    let edge = clamp(g * gain, 0.0, 1.0);

    // Tint the outline with the source colour so edges keep their hue.
    let src = textureSample(prev_frame, prev_sampler, in.uv).rgb;
    let tint = normalize(src + 0.001) * 1.3;

    var col = tint * edge;
    // Beat flashes the contours toward white.
    col = mix(col, vec3<f32>(edge), u.beat * 0.7);

    return vec4<f32>(col, 1.0);
}
