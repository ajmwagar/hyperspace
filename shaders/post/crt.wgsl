// Post-processing: CRT / arcade monitor emulation.
// The on-brand finisher — barrel-curved glass, aperture-grille RGB mask,
// scanlines, phosphor bloom, rolling flicker and a vignette. Designed to sit
// last in a post chain so anything looks like it's playing on a real tube.
// Bass flexes the glass curvature, beats pump brightness/bloom, highs add
// signal static. Chain after any shader.

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

fn hash(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}

// Bulge the screen outward from center like curved CRT glass.
fn barrel(uv: vec2<f32>, amount: f32) -> vec2<f32> {
    let cc = uv - 0.5;
    let d = dot(cc, cc);
    return uv + cc * d * amount;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    // Curved glass — bass flexes the tube a touch.
    let curve = 0.18 + u.bass * 0.12;
    let uv = barrel(in.uv, curve);

    // Everything outside the curved screen is black bezel.
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }

    // Slight phosphor bloom: a cheap cross-tap blur added back as glow.
    let texel = 1.0 / u.resolution;
    var bloom = textureSample(prev_frame, prev_sampler, uv).rgb;
    bloom = bloom + textureSample(prev_frame, prev_sampler, uv + vec2<f32>(texel.x * 1.5, 0.0)).rgb;
    bloom = bloom + textureSample(prev_frame, prev_sampler, uv - vec2<f32>(texel.x * 1.5, 0.0)).rgb;
    bloom = bloom + textureSample(prev_frame, prev_sampler, uv + vec2<f32>(0.0, texel.y * 1.5)).rgb;
    bloom = bloom + textureSample(prev_frame, prev_sampler, uv - vec2<f32>(0.0, texel.y * 1.5)).rgb;
    bloom = bloom / 5.0;

    var col = textureSample(prev_frame, prev_sampler, uv).rgb;
    col = col + bloom * (0.25 + u.beat * 0.35);

    let frag = uv * u.resolution;

    // Aperture-grille mask: cycle R/G/B emphasis across every 3 columns.
    let stripe = i32(floor(frag.x)) % 3;
    var mask = vec3<f32>(0.6);
    if (stripe == 0) { mask = vec3<f32>(1.0, 0.55, 0.55); }
    else if (stripe == 1) { mask = vec3<f32>(0.55, 1.0, 0.55); }
    else { mask = vec3<f32>(0.55, 0.55, 1.0); }
    col = col * mask;

    // Scanlines: darken alternate display rows. A slow vertical roll plus a
    // beat pump sell the live-tube feel.
    let roll = u.time * 30.0;
    let scan = 0.5 + 0.5 * sin((frag.y + roll) * 3.14159);
    let scan_depth = 0.35 - u.beat * 0.15;
    col = col * (1.0 - scan_depth * scan);

    // Signal static — highs/presence add faint snow.
    let snow = hash(frag + u.time) - 0.5;
    col = col + snow * (0.02 + u.high * 0.06 + u.presence * 0.04);

    // Boost to compensate for mask/scanline darkening, beats brighten.
    col = col * (1.5 + u.beat * 0.4 + u.amplitude * 0.3);

    // Vignette toward the corners of the curved glass.
    let cc = uv - 0.5;
    let vig = smoothstep(0.8, 0.2, dot(cc, cc) * 2.2);
    col = col * mix(0.5, 1.0, vig);

    return vec4<f32>(col, 1.0);
}
