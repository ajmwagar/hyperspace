// Post-processing: beat-drop shockwave.
// The "drop" moment — every beat fires an expanding ring that ripples the
// image outward, with a zoom punch, chromatic split and a bloom flash. Driven
// by beat (decaying pulse) + onset, so it stays locked to transients. Needs
// the audio uniforms populated (live engine, or the offline render's analyzer).
// Chain last for the punchiest result.

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
    let center = in.uv - 0.5;
    // Aspect-corrected radial distance so the ring is circular.
    let rc = vec2<f32>(center.x * aspect, center.y);
    let d = length(rc);
    let dir = center / max(length(center), 0.0001);

    let punch = clamp(u.beat + u.onset * 0.6, 0.0, 1.0);

    // Ring expands outward as the beat envelope decays from 1 → 0.
    let ring_r = (1.0 - u.beat) * 0.9;
    let ring = smoothstep(0.07, 0.0, abs(d - ring_r));

    // Zoom punch toward center + ring push outward.
    let zoom = 1.0 - punch * 0.06;
    let displace = ring * u.beat * 0.05;
    let uv2 = center * zoom + 0.5 + dir * displace;

    // Chromatic split, strongest on the ring and during the punch.
    let ca = punch * 0.010 + ring * 0.02;
    let r = textureSample(prev_frame, prev_sampler, uv2 + dir * ca).r;
    let g = textureSample(prev_frame, prev_sampler, uv2).g;
    let b = textureSample(prev_frame, prev_sampler, uv2 - dir * ca).b;
    var col = vec3<f32>(r, g, b);

    // Bloom flash on the drop + a cool highlight riding the ring crest.
    col = col + col * punch * 0.4;
    col = col + vec3<f32>(0.6, 0.8, 1.0) * ring * u.beat * 0.6;

    return vec4<f32>(col, 1.0);
}
