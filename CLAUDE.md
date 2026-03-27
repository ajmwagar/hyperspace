# Hyperspace

Audio-reactive video synthesis engine for CRT displays.

## Conventions

- Shaders live in `shaders/*.wgsl` and must declare the `Uniforms` struct and `spectrum` storage buffer matching `src/uniforms.rs`.
- Scene configs live in `scenes/*.toml`. Run with `cargo run -- scenes/<name>.toml` (append `9` for 3x3 grid mode).
- **`scenes/all.toml` must be kept up to date** — when adding a new shader, add it to the grid so all shaders are represented.

## Running

```
cargo run -- scenes/default.toml     # 3-output mode (center + sides)
cargo run -- scenes/all.toml 9       # 9-output 3x3 grid
```

## Testing

```
cargo test
```
