// Crystal Facets — a cut-gem / shattered-crystal Voronoi mosaic (distinct
// from acid_pools, which fills its cells with soft liquid colour). Each cell
// is a flat faceted gem with its own random tilt, so a moving key light throws
// hard specular glints across the field like light through cut crystal. Sharp
// beveled seams, not soft glow. Bass swells the facets, mids cycle the gem
// hues, highs sharpen the glints, the spectrum lights individual stones.

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

    // First/second nearest seed (F1, F2) plus the vector to the nearest seed
    // so we can dome each facet. The gap (F2-F1) gives the cut seams.
    var f1 = 8.0;
    var f2 = 8.0;
    var id = vec2<f32>(0.0);
    var rel = vec2<f32>(0.0);

    for (var j = -1; j <= 1; j = j + 1) {
        for (var i = -1; i <= 1; i = i + 1) {
            let g = vec2<f32>(f32(i), f32(j));
            var o = hash2(cell + g);
            // Animate each seed in a little orbit.
            o = 0.5 + 0.5 * sin(u.time * (0.6 + u.mid) + 6.28318 * o);
            let r = g + o - f;
            let d = dot(r, r);
            if (d < f1) {
                f2 = f1;
                f1 = d;
                id = cell + g;
                rel = r;
            } else if (d < f2) {
                f2 = d;
            }
        }
    }

    let edge = sqrt(f2) - sqrt(f1);
    let cid = hash2(id);

    // Each facet gets its own random tilt; doming it slightly toward the seed
    // gives a polished cut-stone curvature. Build a surface normal from both.
    let tilt = (hash2(id + 3.3) * 2.0 - 1.0) * 0.9;
    let n = normalize(vec3<f32>(tilt + rel * 1.2, 1.0));

    // Moving key light → glints sweep across the facets like cut crystal.
    let light = normalize(vec3<f32>(cos(u.time * 0.6), sin(u.time * 0.6), 0.8));
    let view = vec3<f32>(0.0, 0.0, 1.0);
    let diff = max(dot(n, light), 0.0);
    let spec = pow(max(dot(reflect(-light, n), view), 0.0), 38.0 + u.high * 60.0);

    // Gem base colour; the spectrum lights individual stones.
    var col = palette(cid.x + u.time * 0.03 + u.mid * 0.3);
    let bin = u32(cid.y * 96.0);
    var sp = 0.0;
    if (bin < 512u) { sp = spectrum[bin]; }
    col = col * (0.3 + diff * 0.9 + sp * 1.8 + u.amplitude * 0.4);

    // Hard specular glint (white) + beat flash.
    col = col + vec3<f32>(1.0) * spec * (0.7 + u.beat);

    // Sharp beveled seams: a dark cut between stones with a bright inner edge.
    let seam = smoothstep(0.05, 0.0, edge);
    let bevel = smoothstep(0.12, 0.05, edge) - seam;
    col = col * (1.0 - seam * 0.8) + vec3<f32>(0.8, 0.9, 1.0) * bevel * 0.5;

    return vec4<f32>(col, 1.0);
}
