# Spec: Multi-Buffer Simulation Pipeline (`sim` feature)

Status: **proposal** · Feature flag: `sim` (default **off**)

## 1. Motivation

Today every shader's output is a near-instant function of the current audio
(`f(time, audio)`), or — at most — reads a single feedback texture that doubles
as both simulation state *and* the displayed image (`reaction_diffusion`,
`ink_flow`). That conflation forces ugly compromises (8-bit state, "show the raw
chemicals", no separate pretty render) and rules out real physics.

We want **stateful, memory-based effects**: audio *injects energy*, and an
autonomous simulation carries it forward — ripples that keep spreading and
reflect off edges after the drop, fluid that swirls on, sand that piles up.
That needs:

- **Persistent simulation buffers** separate from the display (ShaderToy
  "Buffer A/B" model).
- **Float precision** (sim accumulation in 8-bit unorm is lossy/hacky).
- **Sub-stepping** (wave/fluid sims need several iterations per frame).
- **Sim → shade separation** (a hidden sim buffer, a pretty display pass).

This must be **opt-in and zero-cost when unused**: gated behind a Cargo feature
and only active for scenes that declare buffers. Nothing about the existing 27
shaders / current pipeline changes when the feature is off or no buffers are
declared.

## 2. Feature flag

```toml
# Cargo.toml
[features]
sim = []   # multi-buffer simulation pipeline (off by default)
```

What `sim` gates:
- Parsing of `[[ <viewport>.buffer ]]` tables in scene TOML.
- The expanded bind-group layout (adds buffer texture slots 5..8).
- The per-frame buffer execution loop in the renderer(s).

Behavior matrix:

| build | scene declares buffers? | result |
|---|---|---|
| `sim` **off** (default) | no | identical to today, zero overhead |
| `sim` **off** | yes | **warn loudly + ignore buffers**, render display shader only |
| `sim` **on** | no | identical to today (no buffer passes emitted) |
| `sim` **on** | yes | full simulation pipeline runs |

*Decision A:* feature-off + buffers present → I recommend **warn-and-skip** (keeps
scene files portable across builds) rather than a hard error. Flaggable.

## 3. Scene schema

A viewport may declare ordered simulation buffers that run *before* its display
shader each frame. The display shader (the existing `shader =`) samples them.

```toml
[center]
shader = "shaders/sim/water_shade.wgsl"     # display pass: reads the buffers
post   = ["shaders/post/crt.wgsl"]          # unchanged, runs after display

# Simulation buffers, executed in declared order every frame.
[[center.buffer]]
name   = "height"                  # documentation/label; slot = declaration order
shader = "shaders/sim/wave.wgsl"
format = "rgba16f"                 # rgba16f (default) | rgba32f | r32f
scale  = 1.0                       # sim resolution = scale × viewport (0.5 = half-res)
steps  = 4                         # sub-steps per frame (ping-ponged N times)
wrap   = "clamp"                   # clamp (default) | repeat | mirror  (edge behaviour)
```

- Buffers are addressed by **declaration order**: buffer 0 → binding 5, buffer 1
  → binding 6, … (up to 4). `name` is for humans/logs.
- A sim shader reading "itself" reads its own slot (bound to its *previous*
  texture during its pass — classic ping-pong).
- Buffers may read each other (e.g. a `velocity` buffer reads `height`).
- The display shader and post chain are unchanged conceptually; they can now
  also sample buffers 5..8.

*Decision B:* cap at **4 buffers/viewport** (bindings 5–8). Enough for fluid
(velocity+dye+pressure) with room to spare; keeps the BGL small.

## 4. Runtime model (per viewport, per frame)

```
for buf in buffers (declared order):
    repeat `buf.steps` times:
        bind: uniforms@0, audio@1, state@2, sampler@3, prev_frame@4(display fb),
              buffers@5..8 (each at its current READ texture)
        render buf.shader  →  buf's WRITE texture     # ping-pong, swap read/write
run display shader  →  display feedback texture       # samples buffers@5..8
run post chain                                         # exactly as today
blit → surface / readback
```

- **Float precision:** sim buffers default `rgba16f` (filterable everywhere we
  target, incl. lavapipe). `r32f` available for single-channel height fields
  (nearest sampling). *Decision C:* default `rgba16f`.
- **Resolution independence:** each buffer sized `scale × viewport`; everything
  sampled in normalized UV so it's res-agnostic. Sims can run at half-res for
  speed and still shade at full res.
- **Boundaries:** per-buffer sampler `wrap` mode controls edge behaviour — e.g.
  `clamp` makes waves reflect, `repeat` makes them wrap (toroidal).
- **Time step:** sim shaders own their `dt`/wave-speed constants internally;
  `steps` multiplies the simulation rate per displayed frame.
- **Init:** buffers cleared to black on creation (like current feedback), so
  sims must self-seed or tolerate a zero start (same convention as
  `reaction_diffusion`).

## 5. Shader interface (bindings)

Extends the current layout (0 uniforms, 1 audio, 2 Lua state, 3 sampler,
4 prev_frame) with **buffer texture slots 5..8**:

```wgsl
@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var<storage, read> spectrum: array<f32>;
@group(0) @binding(2) var<storage, read> state: array<f32>;
@group(0) @binding(3) var samp: sampler;
@group(0) @binding(4) var prev_frame: texture_2d<f32>;   // display feedback
// sim buffers (declaration order); unused slots bound to a 1x1 dummy:
@group(0) @binding(5) var buf0: texture_2d<f32>;
@group(0) @binding(6) var buf1: texture_2d<f32>;
@group(0) @binding(7) var buf2: texture_2d<f32>;
@group(0) @binding(8) var buf3: texture_2d<f32>;
```

A shader only declares the bindings it uses (wgpu allows unused bound
resources), so existing shaders are unaffected by the larger layout.

## 6. Worked example — wave-equation ripples (the real one)

`shaders/sim/wave.wgsl` — buffer 0 (`rgba16f`, `wrap="clamp"`, `steps=4`),
reads itself at `buf0`. Stores `r = height`, `g = previous height`:

```wgsl
// h_next = (2h - h_prev) + c² · ∇²h, with damping. Audio injects drops.
let texel = 1.0 / u.resolution;
let c = textureSample(buf0, samp, uv).xy;            // (h, h_prev)
let l = sample(uv+dx).x + sample(uv-dx).x
      + sample(uv+dy).x + sample(uv-dy).x - 4.0*c.x; // ∇²h
var h = (2.0*c.x - c.y) + 0.25 * l;                  // c²=0.25 (stable)
h = h * 0.996;                                        // slow energy bleed
// inject on the beat / continuously — energy then propagates on its own:
h = h + u.beat * gaussian(uv, dropPos) * 0.5;
return vec4(h, c.x, 0.0, 1.0);                        // new height, old height
```

`shaders/sim/water_shade.wgsl` — display pass, reads `buf0.x` as height,
derives a normal from its gradient, shades sunlight + caustics → the pretty
water. **No 8-bit hacks, real propagation, reflects off the walls, and the pool
keeps rippling through a breakdown.**

Scene `scenes/pond.toml` wires it; runs with the `sim` feature:
```
cargo run --features sim -- scenes/pond.toml
cargo run --release --features render,sim --example render -- song.wav out.mp4 scenes/pond.toml
```

## 7. Implementation plan (phased)

1. **MVP in `offscreen.rs` + `examples/render.rs`** (behind `sim`). This is the
   headless path I can actually test here (software GPU) and it drives the
   renders we share. Adds: `BufferSpec` parse, per-buffer ping-pong textures
   (float), expanded BGL, the execution loop, dummy-fill of unused slots.
2. **Port to `src/renderer.rs`** (live engine) — same structs/loop; this is the
   on-hardware path. Lower priority (can't test it here without a display).
3. **First consumers:** `sim/wave.wgsl` + `sim/water_shade.wgsl` + `scenes/pond.toml`.
4. **Docs + a naga test extension** to validate `shaders/sim/*.wgsl`.

Shared code: factor the buffer/exec logic so `renderer.rs` and `offscreen.rs`
don't duplicate (e.g. a small `sim` module), since they already duplicate the
single-buffer feedback today.

## 8. Scene schema additions (Rust)

`src/scene.rs` — gated `#[cfg(feature = "sim")]`:
```rust
pub struct BufferSpec {
    pub name: String,
    pub shader: String,
    pub format: BufferFormat,   // Rgba16f | Rgba32f | R32f
    pub scale: f32,             // default 1.0
    pub steps: u32,             // default 1
    pub wrap: WrapMode,         // Clamp | Repeat | Mirror
}
// Viewport gains: pub buffers: Vec<BufferSpec>   (empty = today's behaviour)
```

## 9. Risks / notes

- **Cost:** N buffers × `steps` extra fullscreen passes/frame. Opt-in per scene;
  `scale < 1` mitigates. Float buffers cost more bandwidth than 8-bit.
- **BGL change is global** in a `sim` build (bindings 5–8 added). Existing
  shaders keep working (unused bindings allowed); kept out of default builds by
  the feature gate.
- **`r32f` filtering** isn't guaranteed filterable on all backends — default
  `rgba16f` avoids that; document the caveat.
- **Two renderers** still duplicated; factor shared sim code to avoid drift.
- Unlocks a whole class beyond ripples: fluid (Navier–Stokes), smoke, boids,
  sand/erosion, slime-mold, heat diffusion — all "audio injects, physics
  carries on."

## 10. Decisions needed

- **A.** feature-off + buffers present → warn-and-skip (recommended) vs error.
- **B.** max buffers = 4 (recommended).
- **C.** default format `rgba16f` (recommended).
- **D.** land in `offscreen.rs`/`render` first (recommended), port to live
  `renderer.rs` after.
