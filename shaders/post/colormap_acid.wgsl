// Post-processing: acid colormap.
// High contrast neon green/yellow/magenta cycling palette.
// Fast cycling speed driven by amplitude and beat for an intense look.

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
    let prev = textureSample(prev_frame, prev_sampler, in.uv);
    let brightness = dot(prev.rgb, vec3<f32>(0.299, 0.587, 0.114));

    // Fast cycling driven by amplitude and beat
    let speed = 0.08 + u.amplitude * 0.1 + u.beat * 0.15;
    let offset = u.time * speed;
    let t = fract(brightness * 1.5 + offset);

    // Acid palette: neon green -> electric yellow -> hot magenta -> back to green
    // Use sharp sine-based curves for high contrast neon look
    let tau = 6.28318;

    // Green channel: strong in first third, dips, returns
    let g = smoothstep(0.0, 0.15, t) * (1.0 - smoothstep(0.4, 0.55, t)) + smoothstep(0.85, 1.0, t);
    // Red channel: rises in middle (yellow region), peaks in magenta
    let r = smoothstep(0.2, 0.45, t) * 0.8 + smoothstep(0.5, 0.7, t) * 0.5;
    // Blue channel: only in magenta region
    let b = smoothstep(0.55, 0.75, t) * (1.0 - smoothstep(0.85, 1.0, t));

    var mapped = vec3<f32>(r, g, b);

    // Boost contrast and saturation hard for acid look
    mapped = mapped * 1.4;
    // Clamp to keep neon but not blow out
    mapped = clamp(mapped, vec3<f32>(0.0), vec3<f32>(1.0));

    // High frequency adds extra shimmer
    let shimmer = 1.0 + u.high * 0.3 * sin(u.time * 3.0 + brightness * tau);
    mapped = mapped * shimmer;

    // Blend: aggressively color dark areas, keep bright areas punchy
    let blend = smoothstep(0.85, 0.2, brightness);
    let result = mix(prev.rgb, mapped * brightness * 2.5, blend);

    return vec4<f32>(result, 1.0);
}
