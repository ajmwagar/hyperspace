// Acid Melt — liquid distortion that melts the screen.
// Domain warping with feedback creates organic flowing acid patterns.
// Bass drives the warp intensity, onset triggers color eruptions.

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
@group(0) @binding(1) var<storage, read> audio_buf: array<f32>;
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

fn noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u2 = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(hash(i), hash(i + vec2<f32>(1.0, 0.0)), u2.x),
        mix(hash(i + vec2<f32>(0.0, 1.0)), hash(i + vec2<f32>(1.0, 1.0)), u2.x),
        u2.y
    );
}

// Domain warping: displace coordinates through layered noise
fn warp(p: vec2<f32>, t: f32, intensity: f32) -> vec2<f32> {
    let q = vec2<f32>(
        noise(p + vec2<f32>(0.0, 0.0) + t * 0.1),
        noise(p + vec2<f32>(5.2, 1.3) + t * 0.12)
    );
    let r = vec2<f32>(
        noise(p + 4.0 * q + vec2<f32>(1.7, 9.2) + t * 0.08),
        noise(p + 4.0 * q + vec2<f32>(8.3, 2.8) + t * 0.09)
    );
    return p + r * intensity;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let uv = in.uv;
    let p = (uv - 0.5) * 2.0;
    let t = u.time;

    // Warp the UV for feedback sampling — this creates the liquid flow
    let warp_strength = 0.015 + u.bass * 0.012 + u.sub_bass * 0.008;
    let warped_p = warp(p * 2.0, t, warp_strength * 8.0);
    let flow_uv = warped_p * 0.25 + 0.5;
    let feedback_uv = clamp(flow_uv, vec2<f32>(0.001), vec2<f32>(0.999));

    // Sample previous frame — lower decay so trails are vivid, not washed
    let prev = textureSample(prev_frame, prev_sampler, feedback_uv);
    let decay = 0.88 + u.amplitude * 0.04;
    // Re-saturate the feedback: push colors away from grey
    var fb = prev.rgb * decay;
    let fb_luma = dot(fb, vec3<f32>(0.299, 0.587, 0.114));
    fb = mix(vec3<f32>(fb_luma), fb, 1.3); // boost saturation of trails
    var col = max(fb, vec3<f32>(0.0));

    // === Acid patterns — bold, not subtle ===

    // Domain warp the coordinate space hard
    let wp1 = warp(p * 3.0, t * 0.5, 1.2 + u.bass * 0.8);
    let wp2 = warp(p * 1.5, t * 0.3 + 100.0, 1.0 + u.mid * 0.5);

    let pattern1 = noise(wp1 * 2.0 + t * 0.2);
    let pattern2 = noise(wp2 * 3.0 - t * 0.15);
    let combined = pattern1 * 0.6 + pattern2 * 0.4;

    // Sharp contour lines — thick, vivid
    let contour = abs(fract(combined * 5.0 + t * 0.06) - 0.5) * 2.0;
    let line = smoothstep(0.08, 0.0, contour - 0.4);

    // Color: full-saturation acid palette
    let hue = fract(combined * 0.5 + t * 0.03 + u.mid * 0.3);
    let acid_col = acid_palette(hue);

    // Draw lines BRIGHT — this is acid, not watercolor
    let line_brightness = line * (0.4 + u.amplitude * 0.6 + u.onset * 0.4);
    col += acid_col * line_brightness;

    // Filled regions between contours — low-key color wash
    let fill = smoothstep(0.3, 0.5, combined) * 0.15;
    col += acid_col * fill * (0.5 + u.amplitude * 0.5);

    // Onset: inject bright blobs
    if u.onset > 0.2 {
        let blob_pos = warp(p, t * 2.0, 0.5);
        let blob = exp(-length(blob_pos) * 2.5) * u.onset;
        col += acid_col * blob * 0.6;
    }

    // Sub-bass: deep pulsing glow from center
    let center_glow = exp(-length(p) * 1.2) * u.sub_bass * 0.25;
    col += vec3<f32>(0.3, 0.0, 0.4) * center_glow;

    // Presence: sparkle overlay
    let spark = step(0.98, hash(floor(p * 40.0) + floor(t * 5.0)));
    col += vec3<f32>(1.0) * spark * u.presence * 0.2;

    // Soft clamp
    col = col / (col + 0.6) * 1.1;

    return vec4<f32>(col, 1.0);
}

fn acid_palette(t: f32) -> vec3<f32> {
    // Neon acid: green → yellow → magenta → cyan → green
    let h = t * 4.0;
    var col: vec3<f32>;
    if h < 1.0 {
        col = mix(vec3<f32>(0.0, 1.0, 0.2), vec3<f32>(1.0, 1.0, 0.0), h);
    } else if h < 2.0 {
        col = mix(vec3<f32>(1.0, 1.0, 0.0), vec3<f32>(1.0, 0.0, 0.8), h - 1.0);
    } else if h < 3.0 {
        col = mix(vec3<f32>(1.0, 0.0, 0.8), vec3<f32>(0.0, 0.8, 1.0), h - 2.0);
    } else {
        col = mix(vec3<f32>(0.0, 0.8, 1.0), vec3<f32>(0.0, 1.0, 0.2), h - 3.0);
    }
    return col;
}
