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
@group(0) @binding(1) var<storage, read> spectrum: array<f32>;

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) idx: u32) -> VertexOutput {
    // Fullscreen triangle
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
    let uv = (in.uv - 0.5) * 2.0;
    let aspect = u.resolution.x / u.resolution.y;
    var p = vec2<f32>(uv.x * aspect, uv.y);

    // Polar coordinates (from original center)
    let angle = atan2(p.y, p.x);
    let radius = length(p);

    // Tunnel effect: warp radius
    let tunnel_z = 1.0 / (radius + 0.001);
    let tunnel_x = angle / 3.14159;

    // Stereo panning: bend the tunnel walls deeper into the Z axis
    // Near edge (large radius, small tunnel_z) stays stable
    // Far end (small radius, large tunnel_z) sways with stereo
    let pan = (u.amplitude_l - u.amplitude_r) * 0.4;
    let bass_pan = (u.bass_l - u.bass_r) * 0.6;
    let stereo_bend = (pan + bass_pan);
    // Bend amount increases with depth (tunnel_z), clamped to avoid extremes
    let depth_factor = clamp(tunnel_z * 0.08, 0.0, 1.0);

    // Scroll through tunnel based on time + bass
    let speed = u.time * 2.0 + u.bass * 5.0;
    let tx = tunnel_x + sin(u.time * 0.3) * u.mid + stereo_bend * depth_factor;
    let ty = tunnel_z + speed + stereo_bend * depth_factor * 0.3;

    // Grid pattern with audio reactivity
    let grid = sin(tx * 10.0) * sin(ty * 10.0);
    let lines = smoothstep(0.0, 0.1 + u.amplitude * 0.5, abs(grid));

    // Color palette - shifts with beat, stereo tints L/R
    let beat_hue = u.beat * 0.3;
    let hue = fract(tunnel_z * 0.1 + u.time * 0.05 + beat_hue + stereo_bend * 0.1);
    let col = hsv_to_rgb(vec3<f32>(hue, 0.8, lines));

    // Vignette from tunnel depth
    let vignette = smoothstep(0.0, 0.8, radius);
    let brightness = mix(0.1, 1.0, vignette) * (0.5 + u.amplitude * 2.0);

    // Beat flash
    let flash = u.beat * 0.3;

    return vec4<f32>(col * brightness + flash, 1.0);
}

fn hsv_to_rgb(hsv: vec3<f32>) -> vec3<f32> {
    let h = hsv.x * 6.0;
    let s = hsv.y;
    let v = hsv.z;
    let c = v * s;
    let x = c * (1.0 - abs(h % 2.0 - 1.0));
    let m = v - c;
    var rgb: vec3<f32>;
    if h < 1.0 {
        rgb = vec3<f32>(c, x, 0.0);
    } else if h < 2.0 {
        rgb = vec3<f32>(x, c, 0.0);
    } else if h < 3.0 {
        rgb = vec3<f32>(0.0, c, x);
    } else if h < 4.0 {
        rgb = vec3<f32>(0.0, x, c);
    } else if h < 5.0 {
        rgb = vec3<f32>(x, 0.0, c);
    } else {
        rgb = vec3<f32>(c, 0.0, x);
    }
    return rgb + m;
}
