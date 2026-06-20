// Neon Tunnel — a 3D volumetric flythrough of a glowing wireframe tube.
// Emission is accumulated along each ray near the wandering tunnel wall, so
// neon grid lines streak past as you fly forward. Beats punch the speed, bass
// widens the tube, the spectrum lights up rings down its length.

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

fn palette(t: f32) -> vec3<f32> {
    let a = vec3<f32>(0.5, 0.5, 0.5);
    let b = vec3<f32>(0.5, 0.5, 0.5);
    let c = vec3<f32>(1.0, 1.0, 1.0);
    let d = vec3<f32>(0.30, 0.10, 0.55);
    return a + b * cos(6.28318 * (c * t + d));
}

// The tunnel centre wanders in x/y as a function of depth z.
fn path(z: f32) -> vec2<f32> {
    return vec2<f32>(sin(z * 0.18) * 0.7, cos(z * 0.14) * 0.6);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let aspect = u.resolution.x / u.resolution.y;
    var uv = in.uv * 2.0 - 1.0;
    uv.x = uv.x * aspect;

    // Forward-moving camera; beats and bass surge the speed.
    let speed = 3.0 + u.beat * 6.0 + u.bass * 3.0;
    let cam_z = u.time * speed;
    let ro = vec3<f32>(path(cam_z), cam_z);
    let rd = normalize(vec3<f32>(uv, 1.4));

    let radius = 1.0 + u.bass * 0.25;

    var glow = vec3<f32>(0.0);
    var t = 0.0;
    for (var i = 0; i < 64; i = i + 1) {
        t = t + 0.16;
        let p = ro + rd * t;
        let centre = path(p.z);
        let off = p.xy - centre;
        let r = length(off);
        let ang = atan2(off.y, off.x);

        // Distance to the cylindrical wall.
        let wall = abs(radius - r);

        // Neon grid: lines around the ring and along the length.
        let ring = pow(0.5 + 0.5 * sin(p.z * 2.0), 12.0);
        let ribs = pow(0.5 + 0.5 * sin(ang * 8.0), 8.0);
        let grid = max(ring, ribs * 0.7);

        // Spectrum lights rings down the tunnel.
        let bin = u32(abs(fract(p.z * 0.05)) * 200.0);
        var spec = 0.0;
        if (bin < 512u) { spec = spectrum[bin]; }

        let near = exp(-wall * 7.0);
        let col = palette(p.z * 0.03 + ang * 0.15 + u.time * 0.05);
        let falloff = exp(-t * 0.10);
        glow = glow + col * near * (grid + spec * 1.5) * falloff * 0.5;
    }

    // Beat bloom + gentle vignette.
    glow = glow + glow * u.beat * 0.3;
    let vig = 1.0 - dot(in.uv - 0.5, in.uv - 0.5) * 0.7;
    glow = glow * vig;

    return vec4<f32>(glow, 1.0);
}
