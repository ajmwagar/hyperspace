// Post-processing: ordered (Bayer) dithering.
// Retro 8-bit / Playdate look — quantizes each channel to a few levels using
// an 8x8 Bayer threshold matrix. Bass lowers the bit depth (chunkier bands),
// highs add a little threshold jitter so flat areas shimmer. Chain after any shader.

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

// 8x8 Bayer matrix value in [0,1) for integer pixel coords.
fn bayer8(c: vec2<i32>) -> f32 {
    let x = c.x & 7;
    let y = c.y & 7;
    var m = array<i32, 64>(
        0, 32, 8, 40, 2, 34, 10, 42,
        48, 16, 56, 24, 50, 18, 58, 26,
        12, 44, 4, 36, 14, 46, 6, 38,
        60, 28, 52, 20, 62, 30, 54, 22,
        3, 35, 11, 43, 1, 33, 9, 41,
        51, 19, 59, 27, 49, 17, 57, 25,
        15, 47, 7, 39, 13, 45, 5, 37,
        63, 31, 55, 23, 61, 29, 53, 21,
    );
    return f32(m[y * 8 + x]) / 64.0;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let src = textureSample(prev_frame, prev_sampler, in.uv).rgb;

    // Optional pixelation so the dither pattern reads as chunky pixels.
    let px = 2.0 + floor(u.bass * 3.0);
    let frag = floor(in.uv * u.resolution / px);

    let threshold = bayer8(vec2<i32>(frag)) - 0.5 + (u.high * 0.15) * sin(u.time * 30.0);

    // Fewer levels when the bass hits → heavier banding.
    let levels = 5.0 - floor(u.bass * 2.5);
    let dithered = floor(src * (levels - 1.0) + 0.5 + threshold) / (levels - 1.0);

    let col = clamp(dithered, vec3<f32>(0.0), vec3<f32>(1.0));
    return vec4<f32>(col, 1.0);
}
