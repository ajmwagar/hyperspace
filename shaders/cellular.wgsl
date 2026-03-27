// Cellular Automata — emergent life on a grid.
// The automaton runs on its own clock, evolving deterministically.
// Audio modulates the rules: bass shifts the birth threshold,
// mids alter the survival range, beat injects random life.
// Visual state is computed from hash-based pseudo-history.

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

fn hash2(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}

// Deterministic cell state at a given generation and position
fn cell_state(cell: vec2<f32>, gen: f32) -> f32 {
    // Hash gives a pseudo-random initial state
    let seed = hash2(cell + gen * 0.01);

    // Count "neighbors" — use surrounding cell hashes from previous gen
    let prev_gen = gen - 1.0;
    var neighbors = 0.0;
    for (var dx = -1; dx <= 1; dx++) {
        for (var dy = -1; dy <= 1; dy++) {
            if dx == 0 && dy == 0 { continue; }
            let nc = cell + vec2<f32>(f32(dx), f32(dy));
            let ns = hash2(nc + prev_gen * 0.01);
            if ns > 0.5 {
                neighbors += 1.0;
            }
        }
    }

    let was_alive = hash2(cell + prev_gen * 0.01) > 0.5;

    // Game of Life rules, modulated by audio
    let birth_threshold = 2.8 + u.bass * 0.4;  // normally 3, bass lowers it → more birth
    let survive_lo = 1.8 - u.mid * 0.3;         // normally 2, mids widen survival
    let survive_hi = 3.2 + u.mid * 0.3;         // normally 3

    var alive = false;
    if was_alive {
        alive = neighbors >= survive_lo && neighbors <= survive_hi;
    } else {
        alive = neighbors >= birth_threshold && neighbors <= birth_threshold + 0.4;
    }

    // Beat: inject random life
    if u.beat > 0.5 && seed > (1.0 - u.beat * 0.3) {
        alive = true;
    }

    if alive { return 1.0; } else { return 0.0; }
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let uv = in.uv;

    // Grid resolution
    let grid_size = 80.0;
    let cell = floor(uv * grid_size);
    let cell_uv = fract(uv * grid_size);

    // Generation: advances at a steady pace, audio doesn't speed it up
    let gen = floor(u.time * 4.0); // ~4 generations per second

    // Multi-layer: blend current + recent generations for trails
    var life = 0.0;
    life += cell_state(cell, gen) * 1.0;
    life += cell_state(cell, gen - 1.0) * 0.5;
    life += cell_state(cell, gen - 2.0) * 0.25;
    life += cell_state(cell, gen - 3.0) * 0.12;

    // Cell shape: rounded square with gap
    let edge = smoothstep(0.0, 0.08, cell_uv.x) * smoothstep(1.0, 0.92, cell_uv.x)
             * smoothstep(0.0, 0.08, cell_uv.y) * smoothstep(1.0, 0.92, cell_uv.y);

    // === Color ===
    // Living cells: cool palette, generation-based hue
    let age = cell_state(cell, gen - 1.0) + cell_state(cell, gen - 2.0);
    let hue = fract(age * 0.15 + u.time * 0.02 + hash2(cell) * 0.1);

    // Palette: teals, purples, blues
    var cell_col = vec3<f32>(0.0);
    let h = hue * 3.0;
    if h < 1.0 {
        cell_col = mix(vec3<f32>(0.0, 0.8, 0.6), vec3<f32>(0.2, 0.4, 1.0), h);
    } else if h < 2.0 {
        cell_col = mix(vec3<f32>(0.2, 0.4, 1.0), vec3<f32>(0.6, 0.1, 0.8), h - 1.0);
    } else {
        cell_col = mix(vec3<f32>(0.6, 0.1, 0.8), vec3<f32>(0.0, 0.8, 0.6), h - 2.0);
    }

    // Newly born cells flash bright
    let just_born = cell_state(cell, gen) * (1.0 - cell_state(cell, gen - 1.0));
    cell_col += vec3<f32>(0.3, 0.3, 0.3) * just_born;

    // Brightness from life value (trails fade)
    let brightness = clamp(life, 0.0, 1.0);

    // Background: very dark
    var col = vec3<f32>(0.01, 0.01, 0.02);

    // Draw cells
    col = mix(col, cell_col * brightness, edge * step(0.01, life));

    // Grid lines (very subtle)
    let grid_line = (1.0 - edge) * 0.02;
    col += vec3<f32>(0.05, 0.05, 0.1) * grid_line;

    // Spectrum overlay: subtle glow columns driven by spectrum
    let spec_col = floor(uv.x * 64.0);
    let spec_idx = u32(spec_col * 8.0);
    var spec_val = 0.0;
    if spec_idx < 512u {
        spec_val = spectrum[spec_idx];
    }
    col += vec3<f32>(0.0, 0.03, 0.05) * spec_val * 0.5;

    // Beat pulse: brief grid flash
    col += vec3<f32>(0.05, 0.02, 0.08) * u.beat * 0.4;

    return vec4<f32>(col, 1.0);
}
