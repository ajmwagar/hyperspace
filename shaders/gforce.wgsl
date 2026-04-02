// G-Force — feedback visualizer inspired by SoundSpectrum/iTunes.
// Reads previous frame, warps through flow field, draws waveshape, applies colormap.
// State buffer from Lua controls: flow_style, wave_shape, colormap, decay, etc.
//
// State buffer layout (from Lua):
//   [0] flow_style (0=spiral, 1=breathe, 2=drift, 3=diamond)
//   [1] wave_shape (0=circle, 1=ribbon, 2=star, 3=lissajous)
//   [2] colormap   (0=fire, 1=ocean, 2=neon, 3=sunset)
//   [3] decay      (0.0-1.0, how fast trails fade)
//   [4] flow_speed (multiplier for flow field intensity)
//   [5] wave_thickness (line width)
//   [6] colormap_speed (palette cycling speed)
//   [7] colormap_offset (palette phase)
//   [8] wave_intensity (brightness of new waveshape draw)

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
@group(0) @binding(2) var<storage, read> config: array<f32>;
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

// Read waveform samples from audio buffer
fn wave_l(i: u32) -> f32 {
    if i < 512u { return audio_buf[512u + i]; }
    return 0.0;
}
fn wave_r(i: u32) -> f32 {
    if i < 512u { return audio_buf[1024u + i]; }
    return 0.0;
}

// === Flow Fields ===
fn flow_spiral(p: vec2<f32>, t: f32, speed: f32) -> vec2<f32> {
    let angle = atan2(p.y, p.x);
    let r = length(p);
    let spin = speed * 0.02;
    let pull = speed * -0.005;
    return vec2<f32>(
        cos(angle + 1.5708) * spin + p.x * pull,
        sin(angle + 1.5708) * spin + p.y * pull
    );
}

fn flow_breathe(p: vec2<f32>, t: f32, speed: f32) -> vec2<f32> {
    let pulse = sin(t * 0.5) * speed * 0.01;
    return p * pulse;
}

fn flow_drift(p: vec2<f32>, t: f32, speed: f32) -> vec2<f32> {
    let dx = sin(p.y * 3.0 + t * 0.3) * speed * 0.008;
    let dy = cos(p.x * 3.0 + t * 0.4) * speed * 0.006;
    return vec2<f32>(dx, dy);
}

fn flow_diamond(p: vec2<f32>, t: f32, speed: f32) -> vec2<f32> {
    let ax = abs(p.x);
    let ay = abs(p.y);
    let pull = speed * -0.008;
    return vec2<f32>(sign(p.x) * pull * ay, sign(p.y) * pull * ax);
}

// === Wave Shapes ===
// Returns distance to the waveshape at this UV
fn wave_circle(uv: vec2<f32>, t: f32) -> f32 {
    let p = (uv - 0.5) * 2.0;
    let angle = atan2(p.y, p.x);
    let idx = u32((angle / 6.28318 + 0.5) * 511.0);
    let sample = wave_l(idx % 512u);
    let target_r = 0.3 + sample * 0.4;
    let r = length(p);
    return abs(r - target_r);
}

fn wave_ribbon(uv: vec2<f32>, t: f32) -> f32 {
    let idx = u32(uv.x * 511.0);
    let sample = wave_l(idx % 512u);
    let y_target = 0.5 + sample * 0.35;
    return abs(uv.y - y_target);
}

fn wave_star(uv: vec2<f32>, t: f32) -> f32 {
    let p = (uv - 0.5) * 2.0;
    let angle = atan2(p.y, p.x);
    let idx = u32((angle / 6.28318 + 0.5) * 511.0);
    let sample = wave_l(idx % 512u);
    let points = 5.0 + u.mid * 3.0;
    let star_r = 0.2 + 0.15 * sin(angle * points + t) + sample * 0.3;
    let r = length(p);
    return abs(r - star_r);
}

fn wave_lissajous(uv: vec2<f32>, t: f32) -> f32 {
    let p = (uv - 0.5) * 2.0;
    var min_d = 10.0;
    for (var i = 0u; i < 256u; i++) {
        let sl = wave_l(i * 2u);
        let sr = wave_r(i * 2u);
        let lp = vec2<f32>(sl * 0.8, sr * 0.8);
        let d = length(p - lp);
        min_d = min(min_d, d);
    }
    return min_d;
}

// === Colormaps ===
fn cmap_fire(brightness: f32, offset: f32) -> vec3<f32> {
    let t = fract(brightness + offset);
    return vec3<f32>(
        smoothstep(0.0, 0.4, t),
        smoothstep(0.25, 0.6, t) * 0.7,
        smoothstep(0.5, 0.9, t) * 0.3
    );
}

fn cmap_ocean(brightness: f32, offset: f32) -> vec3<f32> {
    let t = fract(brightness + offset);
    return vec3<f32>(
        smoothstep(0.6, 1.0, t) * 0.5,
        smoothstep(0.2, 0.7, t) * 0.8,
        smoothstep(0.0, 0.5, t)
    );
}

fn cmap_neon(brightness: f32, offset: f32) -> vec3<f32> {
    let t = fract(brightness + offset);
    let r = sin(t * 6.28318) * 0.5 + 0.5;
    let g = sin(t * 6.28318 + 2.094) * 0.5 + 0.5;
    let b = sin(t * 6.28318 + 4.189) * 0.5 + 0.5;
    return vec3<f32>(r, g, b);
}

fn cmap_sunset(brightness: f32, offset: f32) -> vec3<f32> {
    let t = fract(brightness + offset);
    return mix(
        mix(vec3<f32>(0.1, 0.0, 0.2), vec3<f32>(0.8, 0.2, 0.4), t * 2.0),
        mix(vec3<f32>(0.8, 0.2, 0.4), vec3<f32>(1.0, 0.8, 0.3), (t - 0.5) * 2.0),
        step(0.5, t)
    );
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let uv = in.uv;

    // Read config from Lua state buffer
    let flow_style = i32(config[0]);
    let wave_shape = i32(config[1]);
    let colormap = i32(config[2]);
    let decay = config[3];
    let flow_speed = config[4];
    let wave_thick = config[5];
    let cmap_speed = config[6];
    let cmap_offset = config[7];
    let wave_intensity = config[8];

    // === 1. Sample previous frame with flow field distortion ===
    let centered = uv - 0.5;
    var flow: vec2<f32>;
    if flow_style == 0 {
        flow = flow_spiral(centered, u.time, flow_speed);
    } else if flow_style == 1 {
        flow = flow_breathe(centered, u.time, flow_speed);
    } else if flow_style == 2 {
        flow = flow_drift(centered, u.time, flow_speed);
    } else {
        flow = flow_diamond(centered, u.time, flow_speed);
    }

    // Audio modulates flow intensity
    flow *= 1.0 + u.bass * 0.5;

    let warped_uv = clamp(uv + flow, vec2<f32>(0.001), vec2<f32>(0.999));
    let prev = textureSample(prev_frame, prev_sampler, warped_uv);

    // Decay previous frame (creates trails)
    let decayed = prev.rgb * decay;

    // === 2. Draw current waveshape ===
    var wave_dist: f32;
    if wave_shape == 0 {
        wave_dist = wave_circle(uv, u.time);
    } else if wave_shape == 1 {
        wave_dist = wave_ribbon(uv, u.time);
    } else if wave_shape == 2 {
        wave_dist = wave_star(uv, u.time);
    } else {
        wave_dist = wave_lissajous(uv, u.time);
    }

    let thickness = wave_thick * (1.0 + u.amplitude * 0.5);
    let wave_bright = smoothstep(thickness, 0.0, wave_dist) * (wave_intensity + u.onset * 0.3);

    // Waveshape color: white-hot core
    let wave_color = vec3<f32>(1.0, 0.95, 0.9) * wave_bright;

    // === 3. Combine ===
    var combined = decayed + wave_color;

    // === 4. Apply colormap ===
    let brightness = dot(combined, vec3<f32>(0.299, 0.587, 0.114)); // luminance
    let offset = cmap_offset + u.time * cmap_speed;

    var mapped: vec3<f32>;
    if colormap == 0 {
        mapped = cmap_fire(brightness, offset);
    } else if colormap == 1 {
        mapped = cmap_ocean(brightness, offset);
    } else if colormap == 2 {
        mapped = cmap_neon(brightness, offset);
    } else {
        mapped = cmap_sunset(brightness, offset);
    }

    // Blend: colormap applies more at lower brightness, raw wave stays hot
    let color_blend = smoothstep(0.8, 0.3, brightness);
    var final_col = mix(combined, mapped * brightness * 2.0, color_blend);

    // Beat: brief flash
    final_col += vec3<f32>(0.1, 0.08, 0.06) * u.beat * 0.3 + u.onset * 0.15;

    return vec4<f32>(final_col, 1.0);
}
