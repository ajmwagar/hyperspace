# Hyperspace

**Audio-reactive video synthesis engine for CRT displays.**

Rust. wgpu. WGSL shaders. Composite out to CRTs via Raspberry Pi.

## Inputs

- **Audio In** — USB audio device, line level. FFT, amplitude, beat detection exposed as shader uniforms.
- **CV In** — MCP3008 ADC over SPI. 8 channels, eurorack levels. Drives shader selection, parameters, scene triggers.
- **Local Playback** — PipeWire sink for Spotify/Navidrome/etc when not using modular.

## Outputs

Multiple independent shader pipelines rendered to separate display outputs.

- **3-output mode** — Center (HDMI-1), Sides (HDMI-2 → splitter to 2 CRTs). Two independent feeds, three screens.
- **9-output mode** — Single framebuffer divided into 3×3 grid. Each cell is an independent shader viewport. Output via splitter or dedicated multi-composite hardware.

## Shader Interface

Every shader gets the same uniform buffer:

```wgsl
struct Uniforms {
    time: f32,
    delta_time: f32,
    resolution: vec2<f32>,
    amplitude: f32,
    beat: f32,
    bass: f32,
    mid: f32,
    high: f32,
    cv: array<f32, 8>,
    scene_id: u32,
};
```

Plus an FFT spectrum buffer as storage.

## Scenes

TOML config maps shaders to outputs and CV to parameters:

```toml
[center]
shader = "shaders/hyperspace_tunnel.wgsl"

[sides]
shader = "shaders/engine_gauges.wgsl"
symmetric = true
```

## Stack

Rust, wgpu, WGSL, winit, cpal, rustfft, rppal (Pi GPIO/SPI).

## License

AGPLv3
