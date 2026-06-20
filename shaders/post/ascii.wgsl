// Post-processing: ASCII art dithering.
// Quantizes the previous pass into a grid of monospace glyphs whose density
// tracks local brightness — the classic terminal-art look. Bass enlarges the
// characters; beats flash them toward a phosphor green. Chain after any shader.

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

// 5x5 bitmap glyphs packed into 25-bit integers. p is in [-1,1] within a cell.
// Technique popularised by movAX13h's "ASCII art" shader.
fn character(n: i32, p_in: vec2<f32>) -> f32 {
    var p = floor(p_in * vec2<f32>(4.0, -4.0) + 2.5);
    if (p.x >= 0.0 && p.x <= 4.0 && p.y >= 0.0 && p.y <= 4.0) {
        let a = i32(p.x + 5.0 * p.y);
        if (((n >> u32(a)) & 1) == 1) {
            return 1.0;
        }
    }
    return 0.0;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    // Characters per screen width — bass makes them bigger (fewer per row).
    let chars = 80.0 - u.bass * 28.0;
    let cell = u.resolution.x / chars;

    let frag = in.uv * u.resolution;
    let cell_origin = floor(frag / cell) * cell;
    let cell_center_uv = (cell_origin + cell * 0.5) / u.resolution;

    // Average colour of the cell (single center tap — cheap and stable).
    let src = textureSample(prev_frame, prev_sampler, cell_center_uv).rgb;
    let gray = dot(src, vec3<f32>(0.3, 0.59, 0.11));

    // Pick a glyph by brightness, dark -> sparse, bright -> dense.
    var n = 4096;                       // .
    if (gray > 0.15) { n = 65600; }     // :
    if (gray > 0.30) { n = 163153; }    // *
    if (gray > 0.45) { n = 15255086; }  // o
    if (gray > 0.60) { n = 13199452; }  // &
    if (gray > 0.75) { n = 15252014; }  // 8
    if (gray > 0.90) { n = 11512810; }  // #

    // Local position within the cell, mapped to the glyph's [-1,1] space.
    let p = (fract(frag / cell) * 2.0 - 1.0);
    let glyph = character(n, p);

    // Colour the glyph with the source colour; beats push toward phosphor green.
    var col = src * glyph;
    let green = vec3<f32>(0.1, 1.0, 0.3) * gray * glyph;
    col = mix(col, green, u.beat * 0.6);

    return vec4<f32>(col, 1.0);
}
