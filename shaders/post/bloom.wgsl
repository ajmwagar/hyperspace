// Post-processing: bloom / glow.
// Soft light bleed from the bright parts of the image — multi-tap spiral blur
// of a thresholded bright pass, added back over the original. Makes neon and
// highlights feel like they're emitting. Beats and amplitude pump the glow.
// Cheap enough to chain anywhere; great before a CRT or kaleidoscope pass.

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
    let base = textureSample(prev_frame, prev_sampler, in.uv).rgb;

    // Bright-pass + spiral-tap blur. The golden-angle spiral gives an even,
    // cheap approximation of a gaussian glow kernel.
    let texel = 1.0 / u.resolution;
    let radius = 18.0 * (1.0 + u.beat * 0.6);
    var bloom = vec3<f32>(0.0);
    var wsum = 0.0;
    let golden = 2.39996;
    for (var i = 0; i < 24; i = i + 1) {
        let fi = f32(i);
        let a = fi * golden;
        let rr = sqrt(fi / 24.0) * radius;
        let off = vec2<f32>(cos(a), sin(a)) * rr * texel;
        let s = textureSample(prev_frame, prev_sampler, in.uv + off).rgb;
        // Threshold: keep only the bright energy.
        let bright = max(s - vec3<f32>(0.55), vec3<f32>(0.0));
        let w = 1.0 - rr / (radius + 1.0);
        bloom = bloom + bright * w;
        wsum = wsum + w;
    }
    bloom = bloom / max(wsum, 0.001);

    let intensity = 1.4 + u.beat * 1.2 + u.amplitude * 0.6;
    let col = base + bloom * intensity;

    return vec4<f32>(col, 1.0);
}
