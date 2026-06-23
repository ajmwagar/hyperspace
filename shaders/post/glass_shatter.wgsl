// Post-processing: glass shatter on the drop.
// Breaks the image into Voronoi shards that fly apart on every beat, with
// dark crack lines between them and a bright glint along the fractures. As the
// beat envelope decays the shards snap back together. Chain last for impact.

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

fn hash2(p: vec2<f32>) -> vec2<f32> {
    let q = vec2<f32>(dot(p, vec2<f32>(127.1, 311.7)), dot(p, vec2<f32>(269.5, 183.3)));
    return fract(sin(q) * 43758.5453) * 2.0 - 1.0;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let aspect = u.resolution.x / u.resolution.y;
    let shatter = clamp(u.beat + u.onset * 0.5, 0.0, 1.0);

    let grid = 9.0;
    let p = vec2<f32>(in.uv.x * aspect, in.uv.y) * grid;
    let cell = floor(p);
    let f = fract(p);

    // Find nearest Voronoi seed (F1) and the runner-up (F2) for crack width.
    var f1 = 8.0;
    var f2 = 8.0;
    var id = vec2<f32>(0.0);
    for (var j = -1; j <= 1; j = j + 1) {
        for (var i = -1; i <= 1; i = i + 1) {
            let g = vec2<f32>(f32(i), f32(j));
            let seed = 0.5 + 0.5 * hash2(cell + g);
            let r = g + seed - f;
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

    // Each shard flies along its own random direction, scaled by the beat.
    let dir = normalize(hash2(id) + 0.001);
    let push = dir * shatter * 0.12 * (0.5 + length(hash2(id + 5.0)));
    let sample_uv = clamp(in.uv + push, vec2<f32>(0.001), vec2<f32>(0.999));
    var col = textureSample(prev_frame, prev_sampler, sample_uv).rgb;

    // Crack lines darken between shards; a glint rides the fracture on impact.
    let edge = sqrt(f2) - sqrt(f1);
    let crack = smoothstep(0.04, 0.0, edge);
    col = col * (1.0 - crack * (0.5 + shatter * 0.5));
    col = col + vec3<f32>(0.7, 0.85, 1.0) * crack * shatter * 0.8;

    return vec4<f32>(col, 1.0);
}
