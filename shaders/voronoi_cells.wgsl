// Voronoi Cells — TouchDesigner-style animated Voronoi diagram.
// Cell seeds drift and pulse to the music; bass swells the cells, highs
// sharpen the glowing borders. Each cell is tinted from a smooth palette.

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

fn hash2(p: vec2<f32>) -> vec2<f32> {
    let q = vec2<f32>(dot(p, vec2<f32>(127.1, 311.7)), dot(p, vec2<f32>(269.5, 183.3)));
    return fract(sin(q) * 43758.5453);
}

fn palette(t: f32) -> vec3<f32> {
    let a = vec3<f32>(0.5, 0.5, 0.5);
    let b = vec3<f32>(0.5, 0.5, 0.5);
    let c = vec3<f32>(1.0, 1.0, 1.0);
    let d = vec3<f32>(0.10, 0.40, 0.75);
    return a + b * cos(6.28318 * (c * t + d));
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let aspect = u.resolution.x / u.resolution.y;
    let scale = 5.0 + u.bass * 2.0;
    let p = vec2<f32>(in.uv.x * aspect, in.uv.y) * scale;

    let cell = floor(p);
    let f = fract(p);

    // First and second nearest seed distances (F1, F2). The gap between
    // them gives clean borders, the F1 cell id drives the color.
    var f1 = 8.0;
    var f2 = 8.0;
    var id = vec2<f32>(0.0);

    for (var j = -1; j <= 1; j = j + 1) {
        for (var i = -1; i <= 1; i = i + 1) {
            let g = vec2<f32>(f32(i), f32(j));
            var o = hash2(cell + g);
            // Animate each seed in a little orbit
            o = 0.5 + 0.5 * sin(u.time * (0.6 + u.mid) + 6.28318 * o);
            let r = g + o - f;
            let d = dot(r, r);
            if (d < f1) {
                f2 = f1;
                f1 = d;
                id = cell + g;
            } else if (d < f2) {
                f2 = d;
            }
        }
    }

    let edge = sqrt(f2) - sqrt(f1);

    // Cell fill color from its id, cycling slowly
    let cid = hash2(id);
    var col = palette(cid.x + u.time * 0.03 + u.mid * 0.3);

    // Brighten cells whose seed sits where the spectrum is hot
    let bin = u32(cid.y * 96.0);
    var spec = 0.0;
    if (bin < 512u) { spec = spectrum[bin]; }
    col = col * (0.6 + spec * 2.5 + u.amplitude * 0.6);

    // Glowing borders — highs make them crisp, beat flashes them white
    let border_w = 0.06 + u.high * 0.06;
    let border = smoothstep(border_w, 0.0, edge);
    let glow = vec3<f32>(0.6, 0.9, 1.0) * border * (0.5 + u.beat);
    col = mix(col, col + glow, border);

    return vec4<f32>(col, 1.0);
}
