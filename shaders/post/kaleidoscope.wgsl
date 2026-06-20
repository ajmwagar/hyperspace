// Post-processing: kaleidoscope / mandala mirror.
// Folds the previous pass into N-fold radial symmetry — instant hypnotic
// mandala out of any generator. Rotates slowly; mids change the fold count,
// bass breathes the zoom, beats kick the rotation. Aspect-correct so it stays
// symmetric in vertical 9:16. Chain after any shader.

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
    let aspect = u.resolution.x / u.resolution.y;

    // Aspect-corrected centered coords so symmetry holds in any format.
    var p = in.uv - 0.5;
    p.x = p.x * aspect;

    // Fold count — quantized so it changes in clean steps with the mids.
    let segs = 6.0 + 2.0 * floor(u.mid * 3.0);
    let seg = 6.28318 / segs;

    var a = atan2(p.y, p.x) + u.time * 0.15 + u.beat * 0.35;
    // Wrap into one wedge, then mirror inside it.
    a = a - seg * floor(a / seg);
    a = abs(a - seg * 0.5);

    // Radius breathes with the bass for a gentle in/out pulse.
    let r = length(p) * (1.0 - u.bass * 0.08 * sin(u.time * 0.7));

    // Reconstruct a sample point and undo the aspect correction.
    var suv = vec2<f32>(cos(a), sin(a)) * r;
    suv.x = suv.x / aspect;
    suv = suv + 0.5;

    // Mirror-tile into [0,1] so the wedge fills richly (classic kaleidoscope).
    suv = abs(fract(suv * 0.5) * 2.0 - 1.0);

    var col = textureSample(prev_frame, prev_sampler, suv).rgb;

    // Subtle center bloom keeps the mandala's core glowing.
    let core = smoothstep(0.35, 0.0, length(p));
    col = col + col * core * (0.2 + u.beat * 0.4);

    return vec4<f32>(col, 1.0);
}
