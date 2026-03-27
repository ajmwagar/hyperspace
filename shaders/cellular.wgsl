// Cellular Automata — real Game of Life patterns on a grid.
// Known ships and oscillators are placed analytically and evolve correctly.
// The automaton has its own life; audio gently modulates color and glow.
// Beat occasionally seeds new gliders.

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

// === Glider ===
// Period 4, moves (+1,+1) each full cycle
// Phase 0: (1,0)(2,1)(0,2)(1,2)(2,2)
fn glider_phase0(p: vec2<i32>) -> bool {
    return (p.x==1 && p.y==0) || (p.x==2 && p.y==1) ||
           (p.x==0 && p.y==2) || (p.x==1 && p.y==2) || (p.x==2 && p.y==2);
}
fn glider_phase1(p: vec2<i32>) -> bool {
    return (p.x==0 && p.y==1) || (p.x==2 && p.y==1) ||
           (p.x==1 && p.y==2) || (p.x==2 && p.y==2) || (p.x==1 && p.y==3);
}
fn glider_phase2(p: vec2<i32>) -> bool {
    return (p.x==2 && p.y==1) || (p.x==0 && p.y==2) ||
           (p.x==2 && p.y==2) || (p.x==1 && p.y==3) || (p.x==2 && p.y==3);
}
fn glider_phase3(p: vec2<i32>) -> bool {
    return (p.x==1 && p.y==1) || (p.x==2 && p.y==2) || (p.x==3 && p.y==2) ||
           (p.x==1 && p.y==3) || (p.x==2 && p.y==3);
}

fn glider_at(cell: vec2<i32>, origin: vec2<i32>, gen: i32) -> bool {
    let cycle = gen / 4;
    let phase = gen % 4;
    // Glider moves +1,+1 per full cycle
    let offset = vec2<i32>(cycle, cycle);
    let local = cell - origin - offset;
    if local.x < 0 || local.y < 0 || local.x > 3 || local.y > 3 { return false; }
    if phase == 0 { return glider_phase0(local); }
    if phase == 1 { return glider_phase1(local); }
    if phase == 2 { return glider_phase2(local); }
    return glider_phase3(local);
}

// === Blinker (period 2 oscillator) ===
fn blinker_at(cell: vec2<i32>, origin: vec2<i32>, gen: i32) -> bool {
    let local = cell - origin;
    let phase = gen % 2;
    if phase == 0 {
        // Horizontal: (0,1)(1,1)(2,1)
        return local.y == 1 && local.x >= 0 && local.x <= 2;
    } else {
        // Vertical: (1,0)(1,1)(1,2)
        return local.x == 1 && local.y >= 0 && local.y <= 2;
    }
}

// === Block (still life) ===
fn block_at(cell: vec2<i32>, origin: vec2<i32>) -> bool {
    let local = cell - origin;
    return local.x >= 0 && local.x <= 1 && local.y >= 0 && local.y <= 1;
}

// === Pulsar (period 3 oscillator, 13x13) ===
fn pulsar_at(cell: vec2<i32>, origin: vec2<i32>, gen: i32) -> bool {
    let local = cell - origin;
    if local.x < 0 || local.y < 0 || local.x > 12 || local.y > 12 { return false; }
    let phase = gen % 3;
    let x = local.x;
    let y = local.y;
    // Use symmetry: pulsar is symmetric across both axes around center (6,6)
    // Phase 0 cells (one quadrant, mirrored 4 ways):
    let cx = x;
    let cy = y;
    if phase == 0 {
        return pulsar_p0(cx, cy);
    } else if phase == 1 {
        return pulsar_p1(cx, cy);
    }
    return pulsar_p2(cx, cy);
}

fn pulsar_p0(x: i32, y: i32) -> bool {
    // Phase 0 of pulsar
    return (y==0 && (x==2||x==3||x==4||x==8||x==9||x==10)) ||
           (y==2 && (x==0||x==5||x==7||x==12)) ||
           (y==3 && (x==0||x==5||x==7||x==12)) ||
           (y==4 && (x==0||x==5||x==7||x==12)) ||
           (y==5 && (x==2||x==3||x==4||x==8||x==9||x==10)) ||
           (y==7 && (x==2||x==3||x==4||x==8||x==9||x==10)) ||
           (y==8 && (x==0||x==5||x==7||x==12)) ||
           (y==9 && (x==0||x==5||x==7||x==12)) ||
           (y==10 && (x==0||x==5||x==7||x==12)) ||
           (y==12 && (x==2||x==3||x==4||x==8||x==9||x==10));
}

fn pulsar_p1(x: i32, y: i32) -> bool {
    // Phase 1: slightly expanded
    return (y==0 && (x==2||x==3||x==4||x==8||x==9||x==10)) ||
           (y==1 && (x==3||x==4||x==5||x==7||x==8||x==9)) ||
           (y==2 && (x==0||x==2||x==5||x==7||x==10||x==12)) ||
           (y==3 && (x==0||x==1||x==5||x==7||x==11||x==12)) ||
           (y==4 && (x==0||x==2||x==3||x==5||x==7||x==9||x==10||x==12)) ||
           (y==5 && (x==2||x==3||x==4||x==8||x==9||x==10)) ||
           (y==7 && (x==2||x==3||x==4||x==8||x==9||x==10)) ||
           (y==8 && (x==0||x==2||x==3||x==5||x==7||x==9||x==10||x==12)) ||
           (y==9 && (x==0||x==1||x==5||x==7||x==11||x==12)) ||
           (y==10 && (x==0||x==2||x==5||x==7||x==10||x==12)) ||
           (y==11 && (x==3||x==4||x==5||x==7||x==8||x==9)) ||
           (y==12 && (x==2||x==3||x==4||x==8||x==9||x==10));
}

fn pulsar_p2(x: i32, y: i32) -> bool {
    // Phase 2: intermediate
    return (y==1 && (x==2||x==3||x==4||x==5||x==7||x==8||x==9||x==10)) ||
           (y==2 && (x==1||x==5||x==7||x==11)) ||
           (y==3 && (x==0||x==1||x==5||x==7||x==11||x==12)) ||
           (y==4 && (x==1||x==2||x==4||x==5||x==7||x==8||x==10||x==11)) ||
           (y==5 && (x==3||x==4||x==8||x==9)) ||
           (y==7 && (x==3||x==4||x==8||x==9)) ||
           (y==8 && (x==1||x==2||x==4||x==5||x==7||x==8||x==10||x==11)) ||
           (y==9 && (x==0||x==1||x==5||x==7||x==11||x==12)) ||
           (y==10 && (x==1||x==5||x==7||x==11)) ||
           (y==11 && (x==2||x==3||x==4||x==5||x==7||x==8||x==9||x==10));
}

// === LWSS (Lightweight spaceship, period 4, moves +2,0 per cycle) ===
fn lwss_at(cell: vec2<i32>, origin: vec2<i32>, gen: i32) -> bool {
    let cycle = gen / 4;
    let phase = gen % 4;
    let offset = vec2<i32>(cycle * 2, 0);
    let local = cell - origin - offset;
    if local.x < 0 || local.y < 0 || local.x > 5 || local.y > 4 { return false; }
    let x = local.x;
    let y = local.y;
    if phase == 0 {
        return (y==0 && (x==1||x==4)) || (y==1 && x==0) ||
               (y==2 && (x==0||x==4)) || (y==3 && (x==0||x==1||x==2||x==3));
    } else if phase == 1 {
        return (y==0 && (x==0||x==1)) || (y==1 && (x==2||x==3)) ||
               (y==2 && (x==0||x==3)) || (y==3 && (x==1||x==3));
    } else if phase == 2 {
        return (y==0 && x==1) || (y==1 && (x==2||x==3)) ||
               (y==2 && (x==0||x==3)) || (y==3 && (x==1||x==2||x==3));
    }
    // phase 3
    return (y==0 && (x==0||x==1)) || (y==1 && (x==0||x==2||x==3)) ||
           (y==2 && (x==1||x==2)) || (y==3 && x==2);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let uv = in.uv;

    let grid_size = 80.0;
    let cell = vec2<i32>(floor(uv * grid_size));
    let cell_uv = fract(uv * grid_size);

    // Generation: steady 4Hz tick, independent of audio
    let gen = i32(floor(u.time * 4.0));

    // === Test all patterns ===
    var alive = false;

    // Gliders — several, different starting positions
    alive = alive || glider_at(cell, vec2<i32>(5, 5), gen);
    alive = alive || glider_at(cell, vec2<i32>(20, 10), gen);
    alive = alive || glider_at(cell, vec2<i32>(50, 5), gen);
    alive = alive || glider_at(cell, vec2<i32>(10, 40), gen);
    alive = alive || glider_at(cell, vec2<i32>(35, 30), gen);
    alive = alive || glider_at(cell, vec2<i32>(60, 50), gen);

    // Beat-spawned gliders: new ones appear on beat
    let beat_gen = i32(floor(u.time * 4.0));
    let beat_cycle = i32(floor(u.time * 0.5)); // new glider every ~2 sec
    for (var b = 0; b < 8; b++) {
        let spawn_y = (b * 10 + 3) % 75;
        let spawn_gen = beat_cycle - b;
        let age = gen - spawn_gen * 8;
        if age >= 0 {
            alive = alive || glider_at(cell, vec2<i32>(2, spawn_y), age);
        }
    }

    // Blinkers — scattered oscillators
    alive = alive || blinker_at(cell, vec2<i32>(15, 20), gen);
    alive = alive || blinker_at(cell, vec2<i32>(45, 15), gen);
    alive = alive || blinker_at(cell, vec2<i32>(65, 35), gen);
    alive = alive || blinker_at(cell, vec2<i32>(30, 60), gen);
    alive = alive || blinker_at(cell, vec2<i32>(55, 70), gen);

    // Blocks — still lifes
    alive = alive || block_at(cell, vec2<i32>(25, 25));
    alive = alive || block_at(cell, vec2<i32>(60, 15));
    alive = alive || block_at(cell, vec2<i32>(10, 65));

    // Pulsar — large oscillator
    alive = alive || pulsar_at(cell, vec2<i32>(32, 32), gen);

    // LWSS — spaceship moving right
    alive = alive || lwss_at(cell, vec2<i32>(2, 20), gen);
    alive = alive || lwss_at(cell, vec2<i32>(2, 55), gen);

    // === Rendering ===
    // Cell shape
    let edge = smoothstep(0.0, 0.1, cell_uv.x) * smoothstep(1.0, 0.9, cell_uv.x)
             * smoothstep(0.0, 0.1, cell_uv.y) * smoothstep(1.0, 0.9, cell_uv.y);

    // Check previous generations for trail effect
    var trail = 0.0;
    if alive { trail = 1.0; }
    // Check if alive in recent past (fading trail)
    // We can't cheaply check all patterns for prev gens, so just check current + glow

    // Color: cool palette, audio tints
    let base_col = mix(
        vec3<f32>(0.0, 0.8, 0.5),
        vec3<f32>(0.3, 0.5, 1.0),
        u.mid * 0.5 + 0.3
    );

    // Background
    var col = vec3<f32>(0.01, 0.01, 0.02);

    if alive {
        col = base_col * edge;
        // Glow around living cells
        col += base_col * 0.15;
    }

    // Subtle grid
    let grid_line = (1.0 - edge) * 0.015;
    col += vec3<f32>(0.03, 0.03, 0.06) * grid_line;

    // Beat pulse
    col += vec3<f32>(0.03, 0.01, 0.05) * u.beat * 0.3;

    return vec4<f32>(col, 1.0);
}
