// Cellular Automata — displays GoL state from Lua script.
// State buffer is a 128×128 grid of floats:
//   0.0 = dead, 0.6 = newborn, approaching 1.0 = aged, decaying = trail.

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
@group(0) @binding(1) var<storage, read> audio_buf: array<f32>;
@group(0) @binding(2) var<storage, read> state: array<f32>;

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

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let uv = in.uv;
    let grid_w = 128.0;
    let grid_h = 128.0;

    let cell = vec2<u32>(floor(uv * vec2<f32>(grid_w, grid_h)));
    let cell_uv = fract(uv * vec2<f32>(grid_w, grid_h));

    // Read cell value from state buffer
    let state_idx = cell.y * u32(grid_w) + cell.x;
    var life = 0.0;
    if state_idx < 16384u {
        life = state[state_idx];
    }

    // Cell shape: rounded with gap
    let edge = smoothstep(0.0, 0.12, cell_uv.x) * smoothstep(1.0, 0.88, cell_uv.x)
             * smoothstep(0.0, 0.12, cell_uv.y) * smoothstep(1.0, 0.88, cell_uv.y);

    // Color based on cell value
    // 0.0 = dead (dark), 0.5-0.6 = newborn (bright), ~1.0 = old (warm), decaying = trail
    let alive = step(0.5, life);
    let age = clamp((life - 0.5) * 2.0, 0.0, 1.0);

    // Newborn: bright cyan/white. Aged: warm teal. Trail: dim purple.
    let newborn_col = vec3<f32>(0.3, 1.0, 0.8);
    let aged_col = vec3<f32>(0.0, 0.6, 0.4);
    let trail_col = vec3<f32>(0.15, 0.05, 0.25);

    var cell_col = vec3<f32>(0.0);
    if life > 0.5 {
        cell_col = mix(newborn_col, aged_col, age);
    } else if life > 0.01 {
        // Dying trail
        cell_col = trail_col * (life / 0.5);
    }

    // Background
    var col = vec3<f32>(0.008, 0.008, 0.015);

    // Draw cell
    col = mix(col, cell_col, edge * step(0.01, life));

    // Subtle grid lines
    let grid_line = (1.0 - edge) * 0.01;
    col += vec3<f32>(0.02, 0.02, 0.04) * grid_line;

    // Beat: subtle pulse
    col += vec3<f32>(0.02, 0.01, 0.04) * u.beat * 0.3;

    return vec4<f32>(col, 1.0);
}
