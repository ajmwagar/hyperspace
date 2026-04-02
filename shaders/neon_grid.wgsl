// Neon Grid — retrowave infinite grid with audio-reactive mountains.
// Bass shakes the horizon, mids raise the terrain, beat triggers lightning.
// CRT scanline aesthetic baked in.

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
@group(0) @binding(1) var<storage, read> spectrum: array<f32>;

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
    let h = dot(p, vec2<f32>(127.1, 311.7));
    return fract(sin(h) * 43758.5453);
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

fn terrain(x: f32, z: f32) -> f32 {
    let p = vec2<f32>(x * 0.3, z * 0.3);
    var h = noise(p * 2.0) * 0.5;
    h += noise(p * 4.0 + 13.7) * 0.25;
    h += noise(p * 8.0 + 31.1) * 0.125;
    // Audio drives terrain height
    h *= 0.5 + u.mid * 3.0;
    // Bass wobble
    h += sin(x * 0.5 + u.time * 2.0) * u.bass * 0.3;
    return h;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let uv = in.uv;
    let aspect = u.resolution.x / u.resolution.y;

    // Sky gradient — dark purple to black
    let sky_t = uv.y;
    var col = mix(
        vec3<f32>(0.0, 0.0, 0.0),
        vec3<f32>(0.15, 0.0, 0.3),
        sky_t
    );

    // Sun
    let sun_pos = vec2<f32>(0.5, 0.62);
    let sun_dist = length((uv - sun_pos) * vec2<f32>(aspect, 1.0));
    let sun_glow = 0.08 / (sun_dist + 0.01);
    let sun_body = smoothstep(0.15, 0.14, sun_dist);
    // Sun stripe lines
    let stripe = step(0.0, sin(uv.y * 80.0 - u.time * 2.0)) * 0.3;
    let sun_col = vec3<f32>(1.0, 0.3, 0.6) * sun_body * (1.0 - stripe)
                + vec3<f32>(1.0, 0.5, 0.8) * sun_glow * 0.15;
    col += sun_col;

    // Ground plane — perspective grid
    let horizon = 0.45 + u.bass * 0.02 + u.sub_bass * 0.03;

    if uv.y < horizon {
        let gy = horizon - uv.y;
        let depth = 0.1 / (gy + 0.001);
        let gx = (uv.x - 0.5) * aspect * depth;
        let gz = depth + u.time * 3.0;

        // Terrain height for this point
        let h = terrain(gx, gz);
        let terrain_screen_y = horizon - (h * 0.1 / (gy + 0.001));

        // Grid lines
        let grid_x = abs(fract(gx * 0.5) - 0.5);
        let grid_z = abs(fract(gz * 0.5) - 0.5);
        let line_w = 0.02 + u.amplitude * 0.03 - u.presence * 0.01;
        let grid_line = smoothstep(line_w, 0.0, grid_x) + smoothstep(line_w, 0.0, grid_z);
        let grid_fade = exp(-gy * 3.0);

        // Grid color — neon cyan/magenta
        let grid_hue = fract(depth * 0.01 + u.time * 0.05);
        var grid_col: vec3<f32>;
        if grid_hue < 0.5 {
            grid_col = vec3<f32>(0.0, 1.0, 1.0); // cyan
        } else {
            grid_col = vec3<f32>(1.0, 0.0, 1.0); // magenta
        }

        col = mix(col, grid_col * (0.5 + u.amplitude * 2.0), grid_line * grid_fade * 0.7);

        // Terrain silhouette
        if uv.y > terrain_screen_y {
            let terrain_col = vec3<f32>(0.05, 0.0, 0.1);
            col = mix(col, terrain_col, 0.8);
        }
    }

    // Spectrum bars along bottom
    let bar_count = 64.0;
    let bar_idx = floor(uv.x * bar_count);
    let bar_frac = fract(uv.x * bar_count);
    let bar_gap = smoothstep(0.0, 0.1, bar_frac) * smoothstep(1.0, 0.9, bar_frac);
    let spec_idx = u32(bar_idx * 4.0);
    var bar_h = 0.0;
    if spec_idx < 512u {
        bar_h = spectrum[spec_idx] * 0.15; // log-scaled, scale to bar height
    }
    bar_h = clamp(bar_h, 0.0, 0.15);
    let bar_fill = step(uv.y, bar_h) * bar_gap;
    col += vec3<f32>(0.0, 0.8, 1.0) * bar_fill * 0.5;

    // Beat/onset lightning
    if u.beat > 0.5 || u.onset > 0.5 {
        let lx = uv.x + sin(uv.y * 50.0 + u.time * 100.0) * 0.02;
        let bolt = smoothstep(0.003, 0.0, abs(lx - 0.5));
        // Branch
        let branch = smoothstep(0.004, 0.0, abs(lx - 0.5 + sin(uv.y * 30.0) * 0.05));
        col += vec3<f32>(0.8, 0.8, 1.0) * (bolt + branch * 0.5) * u.beat;
    }

    // CRT scanlines
    let scanline = 0.92 + 0.08 * sin(uv.y * u.resolution.y * 3.14159);
    col *= scanline;

    // CRT vignette
    let d = length((uv - 0.5) * 1.5);
    col *= 1.0 - d * d * 0.5;

    return vec4<f32>(col, 1.0);
}
