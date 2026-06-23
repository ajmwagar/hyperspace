// Mandelbulb — the classic 3D fractal, raymarched with a distance estimator.
// Camera orbits the bulb while audio morphs the power (the "bulb exponent"),
// so the whole form mutates to the music. Orbit-trap colouring + fresnel glow
// + ambient occlusion give it depth. Bass swells/morphs it, mids cycle the
// palette, beats flare the glow, the spectrum sparkles the surface.

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
    let d = vec3<f32>(0.0, 0.33, 0.67);
    return a + b * cos(6.28318 * (c * t + d));
}

// Mandelbulb distance estimate. Returns vec2(distance, orbit-trap).
fn de(pos: vec3<f32>, power: f32) -> vec2<f32> {
    var z = pos;
    var dr = 1.0;
    var r = 0.0;
    var trap = 1e9;
    for (var i = 0; i < 8; i = i + 1) {
        r = length(z);
        if (r > 2.0) {
            break;
        }
        // To polar.
        let theta = acos(clamp(z.z / r, -1.0, 1.0));
        let phi = atan2(z.y, z.x);
        dr = pow(r, power - 1.0) * power * dr + 1.0;
        // Scale and rotate.
        let zr = pow(r, power);
        let st = sin(theta * power);
        z = zr * vec3<f32>(
            st * cos(phi * power),
            st * sin(phi * power),
            cos(theta * power),
        ) + pos;
        trap = min(trap, length(z));
    }
    return vec2<f32>(0.5 * log(r) * r / dr, trap);
}

fn calc_normal(p: vec3<f32>, power: f32) -> vec3<f32> {
    let e = vec2<f32>(0.001, 0.0);
    return normalize(vec3<f32>(
        de(p + e.xyy, power).x - de(p - e.xyy, power).x,
        de(p + e.yxy, power).x - de(p - e.yxy, power).x,
        de(p + e.yyx, power).x - de(p - e.yyx, power).x,
    ));
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let aspect = u.resolution.x / u.resolution.y;
    var uv = in.uv * 2.0 - 1.0;
    uv.x = uv.x * aspect;

    // Power morphs with the music — the bulb breathes between forms.
    let power = 7.0 + u.bass * 3.0 + 1.5 * sin(u.time * 0.2);

    // Orbiting camera.
    let ang = u.time * 0.15;
    let dist = 2.4;
    let ro = vec3<f32>(sin(ang) * dist, 0.5 * sin(u.time * 0.1), cos(ang) * dist);
    let fwd = normalize(-ro);
    let right = normalize(cross(vec3<f32>(0.0, 1.0, 0.0), fwd));
    let up = cross(fwd, right);
    let rd = normalize(uv.x * right + uv.y * up + fwd * 1.6);

    var t = 0.0;
    var hit = false;
    var trap = 0.0;
    var glow = 0.0;
    for (var i = 0; i < 96; i = i + 1) {
        let p = ro + rd * t;
        let d = de(p, power);
        // Accumulate a soft glow from how close rays graze the surface.
        glow = glow + exp(-d.x * 24.0);
        if (d.x < 0.0008) {
            hit = true;
            trap = d.y;
            break;
        }
        t = t + d.x * 0.9;
        if (t > 6.0) {
            break;
        }
    }

    var col = vec3<f32>(0.0);
    if (hit) {
        let p = ro + rd * t;
        let n = calc_normal(p, power);
        let view = -rd;

        // Orbit trap drives the surface colour.
        let base = palette(trap * 0.6 + u.time * 0.05 + u.mid * 0.3);

        // Key light + ambient + fresnel rim.
        let l = normalize(vec3<f32>(0.7, 0.8, -0.4));
        let diff = max(dot(n, l), 0.0);
        let fres = pow(1.0 - max(dot(n, view), 0.0), 3.0);
        // Cheap AO from marched distance.
        let ao = 1.0 / (1.0 + t * 0.5);

        col = base * (0.15 + diff * 0.9) * ao;
        col = col + base * fres * 1.2;
        // Spectrum sparkle on the rim.
        col = col + vec3<f32>(1.0) * fres * u.high * 0.6;
    }

    // Volumetric glow halo around the bulb (the wispy fractal aura).
    let halo = palette(u.time * 0.05 + 0.4) * glow * 0.04 * (1.0 + u.beat);
    col = col + halo;

    // Beat bloom + vignette.
    col = col + col * u.beat * 0.3;
    let vig = 1.0 - dot(in.uv - 0.5, in.uv - 0.5) * 0.7;
    col = col * vig;

    return vec4<f32>(col, 1.0);
}
