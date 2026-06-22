// sim/water_shade.wgsl — display pass for the stateful pond.
// Reads the wave-equation height field from buf0 (binding 5), produced by
// sim/wave.wgsl: r = height(t), g = height(t-1). All the *physics* (ripples
// expanding, interfering, reflecting off the walls, slowly fading) lives in
// the sim buffer; this pass only shades it as water:
//   • surface normals from the height slope → sun sparkle,
//   • curvature (Laplacian) focuses light into caustic veins,
//   • crest/trough adds depth shading,
//   • velocity (h - h_prev) tints the leading edge of each moving wavefront.
// Because the state persists between frames, a wave keeps travelling after the
// drop that made it is long gone — memory, not pulse/pullback.

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
@group(0) @binding(3) var samp: sampler;
@group(0) @binding(5) var buf0: texture_2d<f32>;

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

fn height_at(uv: vec2<f32>) -> f32 {
    return textureSampleLevel(buf0, samp, uv, 0.0).x;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let dim = vec2<f32>(textureDimensions(buf0));
    let texel = 1.0 / dim;
    let uv = in.uv;

    let st = textureSampleLevel(buf0, samp, uv, 0.0).xy; // (h, h_prev)
    let h = st.x;
    let vel = st.x - st.y;                                // surface velocity

    let hxp = height_at(uv + vec2<f32>(texel.x, 0.0));
    let hxm = height_at(uv - vec2<f32>(texel.x, 0.0));
    let hyp = height_at(uv + vec2<f32>(0.0, texel.y));
    let hym = height_at(uv - vec2<f32>(0.0, texel.y));

    // Surface slope → normal. The height field is small, so scale the slope up
    // a touch to get readable specular sparkle without over-steepening.
    let sx = (hxm - hxp) / (2.0 * texel.x);
    let sy = (hym - hyp) / (2.0 * texel.y);
    let n = normalize(vec3<f32>(sx * 0.012, sy * 0.012, 1.0));

    // Curvature (Laplacian): concave dimples focus light → caustic veins.
    let curv = (hxp + hxm + hyp + hym - 4.0 * h);

    // Deep-water base gradient.
    let depth = uv.y;
    let deep = mix(vec3<f32>(0.0, 0.10, 0.22), vec3<f32>(0.0, 0.26, 0.42), depth);

    // Sun glints off the wave slopes.
    let sun = normalize(vec3<f32>(0.35, 0.55, 0.75));
    let spec = pow(max(dot(n, sun), 0.0), 90.0);

    // Caustic veins where the surface focuses light.
    var caustic = clamp(-curv * 6.0, 0.0, 1.0);
    caustic = pow(caustic, 1.2);

    var col = deep;
    col = col + vec3<f32>(0.45, 0.82, 1.0) * caustic * (1.4 + u.amplitude * 1.4);
    col = col + vec3<f32>(1.0, 1.0, 0.95) * spec * 3.2;
    col = col + deep * clamp(h * 1.4, -0.35, 0.7);            // crest/trough
    // Moving wavefronts: velocity tints the leading edge cyan/white.
    col = col + vec3<f32>(0.30, 0.55, 0.75) * clamp(abs(vel) * 9.0, 0.0, 0.9);

    let vig = 1.0 - dot(uv - 0.5, uv - 0.5) * 0.55;
    col = col * vig;

    return vec4<f32>(max(col, vec3<f32>(0.0)), 1.0);
}
