//! Offline `wav → mp4` renderer for the hyperspace visualizer.
//!
//! Decodes an audio file, drives the oscilloscope scene (or any scene.toml)
//! frame-by-frame in a headless wgpu offscreen render loop, and pipes the
//! rendered frames to ffmpeg together with the original audio to produce an
//! mp4 with both a video and an audio stream.
//!
//! Usage:
//!   cargo run --release --features render --example render -- <input.wav> <output.mp4> [scene.toml] [fps]
//!
//! Defaults: scene = scenes/composed.toml, fps = 30, resolution = 1280x720.
//!
//! This reuses the real scene parsing (`src/scene.rs`), the real uniform
//! layout (`src/uniforms.rs`), and the same audio-buffer convention the live
//! engine uploads to shaders:
//!   [0..512)   = FFT spectrum (log-scaled, matching src/audio.rs)
//!   [512..1024)  = waveform L
//!   [1024..1536) = waveform R
//! The main shader + its post chain are rendered with the same ping-pong
//! feedback approach as `src/renderer.rs::render_with_overlay`, so the output
//! looks like actual hyperspace.

#[path = "../src/scene.rs"]
mod scene;
#[path = "../src/uniforms.rs"]
mod uniforms;

use rustfft::{num_complex::Complex, Fft, FftPlanner};
use scene::{LayoutMode, SceneConfig};
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::Arc;
use uniforms::Uniforms;
use wgpu::util::DeviceExt;

const FFT_SIZE: usize = 1024; // matches src/audio.rs
const WAVEFORM_SIZE: usize = 512;
const SPECTRUM_SIZE: usize = 512;
const AUDIO_BUFFER_SIZE: usize = SPECTRUM_SIZE + WAVEFORM_SIZE * 2; // 1536
const STATE_BUFFER_SIZE: usize = 16384; // matches scripting::STATE_BUFFER_SIZE upper bound

/// Parse a resolution preset ("16:9", "4:5", "1:1", "9:16") or explicit "WxH".
fn parse_resolution(s: &str) -> (u32, u32) {
    match s {
        "16:9" => (1280, 720),
        "4:5" => (1080, 1350),
        "1:1" => (1080, 1080),
        "9:16" => (1080, 1920),
        other => other
            .split_once('x')
            .and_then(|(w, h)| Some((w.trim().parse().ok()?, h.trim().parse().ok()?)))
            .unwrap_or_else(|| {
                eprintln!("unrecognized resolution '{}', using 1280x720", other);
                (1280, 720)
            }),
    }
}

fn main() -> anyhow::Result<()> {
    env_logger::init();
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!(
            "usage: {} <input.wav> <output.mp4> [scene.toml] [fps] [resolution: 16:9|4:5|1:1|9:16|WxH]",
            args[0]
        );
        std::process::exit(2);
    }
    let input = args[1].clone();
    let output = args[2].clone();
    let scene_path = args
        .get(3)
        .cloned()
        .unwrap_or_else(|| "scenes/composed.toml".to_string());
    let fps: u32 = args.get(4).and_then(|s| s.parse().ok()).unwrap_or(30);
    let (width, height) = args
        .get(5)
        .map(|s| parse_resolution(s))
        .unwrap_or((1280, 720));

    pollster::block_on(run(&input, &output, &scene_path, fps, width, height))
}

/// Decoded audio: interleaved-free L/R sample vectors + sample rate.
struct DecodedAudio {
    left: Vec<f32>,
    right: Vec<f32>,
    sample_rate: u32,
}

/// Decode a wav file via hound. Handles f32 and int PCM, mono and stereo.
/// Mono is duplicated to both channels.
fn decode_wav(path: &str) -> anyhow::Result<DecodedAudio> {
    let mut reader = hound::WavReader::open(path)?;
    let spec = reader.spec();
    let channels = spec.channels as usize;

    // Read all samples as f32 regardless of source format.
    let samples: Vec<f32> = match spec.sample_format {
        hound::SampleFormat::Float => reader
            .samples::<f32>()
            .collect::<Result<Vec<_>, _>>()?,
        hound::SampleFormat::Int => {
            let max = (1i64 << (spec.bits_per_sample - 1)) as f32;
            reader
                .samples::<i32>()
                .map(|s| s.map(|v| v as f32 / max))
                .collect::<Result<Vec<_>, _>>()?
        }
    };

    let mut left = Vec::with_capacity(samples.len() / channels.max(1));
    let mut right = Vec::with_capacity(samples.len() / channels.max(1));
    if channels <= 1 {
        for &s in &samples {
            left.push(s);
            right.push(s);
        }
    } else {
        for frame in samples.chunks(channels) {
            left.push(frame[0]);
            right.push(*frame.get(1).unwrap_or(&frame[0]));
        }
    }

    Ok(DecodedAudio {
        left,
        right,
        sample_rate: spec.sample_rate,
    })
}

/// Compute the 1536-float audio buffer for the sample window ending at
/// `center` (in samples). Spectrum is log-scaled to match src/audio.rs so the
/// oscilloscope/spectrum shaders see the same value range as the live engine.
fn compute_audio_buffer(
    audio: &DecodedAudio,
    center: usize,
    fft: &Arc<dyn Fft<f32>>,
    scratch: &mut [Complex<f32>],
    buf: &mut [f32; AUDIO_BUFFER_SIZE],
) {
    let n = audio.left.len();
    // Window of FFT_SIZE samples ending at `center`.
    let start = center.saturating_sub(FFT_SIZE);
    let take = |src: &[f32], i: usize| -> f32 {
        let idx = start + i;
        if idx < n {
            src[idx]
        } else {
            0.0
        }
    };

    // Hann-windowed mono FFT for the spectrum.
    let mut fft_buf = vec![Complex::<f32>::default(); FFT_SIZE];
    for i in 0..FFT_SIZE {
        let w = 0.5
            * (1.0 - (2.0 * std::f32::consts::PI * i as f32 / FFT_SIZE as f32).cos());
        let mono = (take(&audio.left, i) + take(&audio.right, i)) * 0.5;
        fft_buf[i] = Complex::new(mono * w, 0.0);
    }
    fft.process_with_scratch(&mut fft_buf, scratch);

    // Spectrum: magnitude → dB → normalized 0..1 (matches src/audio.rs:454-458).
    let half = FFT_SIZE / 2; // 512 == SPECTRUM_SIZE
    for i in 0..half {
        let mag = fft_buf[i].norm() / FFT_SIZE as f32;
        let db = if mag > 1e-10 {
            20.0 * mag.log10()
        } else {
            -120.0
        };
        buf[i] = ((db + 60.0) / 60.0).clamp(0.0, 1.0);
    }

    // Raw waveform: last WAVEFORM_SIZE samples of the window, per channel.
    // The window's tail (closest to `center`) is the most recent audio.
    let wave_start = FFT_SIZE - WAVEFORM_SIZE; // 512
    for i in 0..WAVEFORM_SIZE {
        buf[SPECTRUM_SIZE + i] = take(&audio.left, wave_start + i);
        buf[SPECTRUM_SIZE + WAVEFORM_SIZE + i] = take(&audio.right, wave_start + i);
    }
}

/// Simple per-window band energy for the uniform fields (amplitude/bass/mid/high).
/// Not the full adaptive AGC from src/audio.rs — the scene's look is driven by
/// the audio_buf the shaders read directly; these uniforms are secondary.
fn compute_uniform_bands(buf: &[f32; AUDIO_BUFFER_SIZE], sample_rate: u32) -> (f32, f32, f32, f32) {
    // RMS over waveform L as amplitude.
    let wl = &buf[SPECTRUM_SIZE..SPECTRUM_SIZE + WAVEFORM_SIZE];
    let rms = (wl.iter().map(|s| s * s).sum::<f32>() / WAVEFORM_SIZE as f32).sqrt();
    let amplitude = (rms * 2.0).clamp(0.0, 1.0);

    let bin_hz = sample_rate as f32 / FFT_SIZE as f32;
    let band = |from_hz: f32, to_hz: f32| -> f32 {
        let from = (from_hz / bin_hz) as usize;
        let to = ((to_hz / bin_hz) as usize).min(SPECTRUM_SIZE);
        if to <= from {
            return 0.0;
        }
        buf[from..to].iter().sum::<f32>() / (to - from) as f32
    };
    let bass = band(60.0, 150.0).clamp(0.0, 1.0);
    let mid = band(150.0, 4000.0).clamp(0.0, 1.0);
    let high = band(4000.0, 16000.0).clamp(0.0, 1.0);
    (amplitude, bass, mid, high)
}

/// One compiled pipeline (main shader + post chain) with its feedback textures.
struct Pipeline {
    main: wgpu::RenderPipeline,
    post: Vec<wgpu::RenderPipeline>,
    state_buffer: wgpu::Buffer,
    fb_textures: [wgpu::Texture; 2],
    fb_views: [wgpu::TextureView; 2],
    result_idx: usize,
}

async fn run(input: &str, output: &str, scene_path: &str, fps: u32, width: u32, height: u32) -> anyhow::Result<()> {
    // ---- decode audio ----
    let audio = decode_wav(input)?;
    let total_samples = audio.left.len();
    let duration = total_samples as f64 / audio.sample_rate as f64;
    let total_frames = (duration * fps as f64).ceil() as usize;
    println!(
        "decoded {}: {}Hz, {} samples, {:.2}s → {} frames @ {}fps",
        input, audio.sample_rate, total_samples, duration, total_frames, fps
    );

    // ---- scene: take the first viewport (e.g. [center] in composed.toml) ----
    let config = SceneConfig::load(Path::new(scene_path))?;
    let viewports = config.resolve_viewports(LayoutMode::ThreeOutput);
    let vp = viewports
        .into_iter()
        .find(|v| v.name == "center")
        .or_else(|| {
            config
                .resolve_viewports(LayoutMode::ThreeOutput)
                .into_iter()
                .next()
        })
        .ok_or_else(|| anyhow::anyhow!("scene {} has no usable viewport", scene_path))?;
    println!("scene: {} + {} post pass(es)", vp.shader_path, vp.post.len());

    // ---- wgpu init (headless) ----
    let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor::default());
    let adapter = instance
        .request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            ..Default::default()
        })
        .await
        .map_err(|_| anyhow::anyhow!("no GPU adapter"))?;
    let (device, queue) = adapter
        .request_device(&wgpu::DeviceDescriptor::default())
        .await?;

    // Render in non-srgb RGBA so the bytes we read back are exactly what we
    // feed ffmpeg as rawvideo rgba.
    let format = wgpu::TextureFormat::Rgba8Unorm;

    let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
        mag_filter: wgpu::FilterMode::Linear,
        min_filter: wgpu::FilterMode::Linear,
        address_mode_u: wgpu::AddressMode::ClampToEdge,
        address_mode_v: wgpu::AddressMode::ClampToEdge,
        ..Default::default()
    });

    let bgl = bind_group_layout(&device);

    let uniform_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("uniforms"),
        contents: bytemuck::bytes_of(&Uniforms {
            resolution: [width as f32, height as f32],
            ..Uniforms::default()
        }),
        usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
    });

    let audio_buf_gpu = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("audio"),
        size: (AUDIO_BUFFER_SIZE * 4) as u64,
        usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });

    let pipeline = build_pipeline(&device, &queue, format, &bgl, &vp, width, height)?;

    // ---- readback buffer ----
    let bytes_per_row = align_to(width * 4, 256);
    let readback = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("readback"),
        size: (bytes_per_row * height) as u64,
        usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
        mapped_at_creation: false,
    });

    // ---- spawn ffmpeg, pipe rawvideo to stdin, mux original audio ----
    let mut ffmpeg = Command::new("ffmpeg")
        .args([
            "-y",
            "-f", "rawvideo",
            "-pix_fmt", "rgba",
            "-s", &format!("{}x{}", width, height),
            "-r", &fps.to_string(),
            "-i", "-",
            "-i", input,
            "-c:v", "libx264",
            "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-b:a", "256k",
            "-ac", "2", // upmix mono → stereo (AAC rejects "1 channel (FL)" layouts)
            "-shortest",
            output,
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()?;
    let mut ffmpeg_in = ffmpeg.stdin.take().expect("ffmpeg stdin");

    // ---- FFT planner ----
    let mut planner = FftPlanner::<f32>::new();
    let fft = planner.plan_fft_forward(FFT_SIZE);
    let mut scratch = vec![Complex::default(); fft.get_inplace_scratch_len()];

    let mut pipeline = pipeline;
    let mut audio_data = [0.0f32; AUDIO_BUFFER_SIZE];

    for frame_idx in 0..total_frames {
        let time = frame_idx as f32 / fps as f32;
        // Sample window aligned so the most recent audio is at this frame's time.
        let center = ((time as f64) * audio.sample_rate as f64) as usize;

        compute_audio_buffer(&audio, center, &fft, &mut scratch, &mut audio_data);
        queue.write_buffer(&audio_buf_gpu, 0, bytemuck::cast_slice(&audio_data));

        let (amplitude, bass, mid, high) =
            compute_uniform_bands(&audio_data, audio.sample_rate);
        let u = Uniforms {
            time,
            delta_time: 1.0 / fps as f32,
            resolution: [width as f32, height as f32],
            amplitude,
            bass,
            mid,
            high,
            amplitude_l: amplitude,
            amplitude_r: amplitude,
            ..Uniforms::default()
        };
        queue.write_buffer(&uniform_buf, 0, bytemuck::bytes_of(&u));

        render_frame(
            &device,
            &queue,
            &bgl,
            &uniform_buf,
            &audio_buf_gpu,
            &sampler,
            &mut pipeline,
        );

        // Copy the final result texture to the readback buffer.
        let final_tex = &pipeline.fb_textures[pipeline.result_idx];
        let mut enc = device.create_command_encoder(&Default::default());
        enc.copy_texture_to_buffer(
            final_tex.as_image_copy(),
            wgpu::TexelCopyBufferInfo {
                buffer: &readback,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(bytes_per_row),
                    rows_per_image: Some(height),
                },
            },
            wgpu::Extent3d {
                width: width,
                height: height,
                depth_or_array_layers: 1,
            },
        );
        queue.submit(std::iter::once(enc.finish()));

        // Map, de-pad rows, feed to ffmpeg.
        let slice = readback.slice(..);
        let (tx, rx) = std::sync::mpsc::channel();
        slice.map_async(wgpu::MapMode::Read, move |r| tx.send(r).unwrap());
        device.poll(wgpu::PollType::Wait).unwrap();
        rx.recv().unwrap().unwrap();
        {
            let data = slice.get_mapped_range();
            let row_bytes = (width * 4) as usize;
            for row in 0..height as usize {
                let src = row * bytes_per_row as usize;
                ffmpeg_in.write_all(&data[src..src + row_bytes])?;
            }
        }
        readback.unmap();

        if frame_idx % fps as usize == 0 {
            println!("  frame {}/{} ({:.0}%)", frame_idx, total_frames, 100.0 * frame_idx as f32 / total_frames as f32);
        }
    }

    drop(ffmpeg_in); // EOF → ffmpeg finalizes
    let status = ffmpeg.wait()?;
    if !status.success() {
        anyhow::bail!("ffmpeg exited with status {}", status);
    }
    println!("done → {}", output);
    Ok(())
}

/// Render the main shader then the post chain into the feedback textures,
/// ping-ponging exactly like src/renderer.rs::render_with_overlay.
fn render_frame(
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    bgl: &wgpu::BindGroupLayout,
    uniform_buf: &wgpu::Buffer,
    audio_buf: &wgpu::Buffer,
    sampler: &wgpu::Sampler,
    pipeline: &mut Pipeline,
) {
    let make_bg = |read_view: &wgpu::TextureView| {
        device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: uniform_buf.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: audio_buf.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 2, resource: pipeline.state_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::Sampler(sampler) },
                wgpu::BindGroupEntry { binding: 4, resource: wgpu::BindingResource::TextureView(read_view) },
            ],
        })
    };

    // Main shader: reads fb[result_idx], writes fb[1-result_idx].
    let read_idx = pipeline.result_idx;
    let write_idx = 1 - read_idx;
    {
        let bg = make_bg(&pipeline.fb_views[read_idx]);
        let mut enc = device.create_command_encoder(&Default::default());
        let mut pass = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("main"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &pipeline.fb_views[write_idx],
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Load,
                    store: wgpu::StoreOp::Store,
                },
            })],
            ..Default::default()
        });
        pass.set_pipeline(&pipeline.main);
        pass.set_bind_group(0, &bg, &[]);
        pass.draw(0..3, 0..1);
        drop(pass);
        queue.submit(std::iter::once(enc.finish()));
    }

    // Post chain: ping-pong.
    let mut current = write_idx;
    for post in &pipeline.post {
        let post_read = current;
        let post_write = 1 - post_read;
        let bg = make_bg(&pipeline.fb_views[post_read]);
        let mut enc = device.create_command_encoder(&Default::default());
        let mut pass = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("post"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &pipeline.fb_views[post_write],
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Load,
                    store: wgpu::StoreOp::Store,
                },
            })],
            ..Default::default()
        });
        pass.set_pipeline(post);
        pass.set_bind_group(0, &bg, &[]);
        pass.draw(0..3, 0..1);
        drop(pass);
        queue.submit(std::iter::once(enc.finish()));
        current = post_write;
    }
    pipeline.result_idx = current;
}

fn build_pipeline(
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    format: wgpu::TextureFormat,
    bgl: &wgpu::BindGroupLayout,
    vp: &scene::Viewport,
    width: u32,
    height: u32,
) -> anyhow::Result<Pipeline> {
    let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: None,
        bind_group_layouts: &[bgl],
        push_constant_ranges: &[],
    });

    let make = |path: &str| -> anyhow::Result<wgpu::RenderPipeline> {
        let src = std::fs::read_to_string(path)?;
        let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some(path),
            source: wgpu::ShaderSource::Wgsl(src.into()),
        });
        Ok(device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some(path),
            layout: Some(&layout),
            vertex: wgpu::VertexState {
                module: &module,
                entry_point: Some("vs_main"),
                buffers: &[],
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &module,
                entry_point: Some("fs_main"),
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: Some(wgpu::BlendState::REPLACE),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: Default::default(),
            }),
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleList,
                ..Default::default()
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview: None,
            cache: None,
        }))
    };

    let main = make(&vp.shader_path)?;
    let post: Vec<_> = vp.post.iter().map(|p| make(p)).collect::<Result<_, _>>()?;

    let tex = |label: &str| {
        device.create_texture(&wgpu::TextureDescriptor {
            label: Some(label),
            size: wgpu::Extent3d { width: width, height: height, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                | wgpu::TextureUsages::TEXTURE_BINDING
                | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        })
    };
    let fb_a = tex("fb_a");
    let fb_b = tex("fb_b");
    let view_a = fb_a.create_view(&Default::default());
    let view_b = fb_b.create_view(&Default::default());

    let state_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("state"),
        contents: bytemuck::cast_slice(&vec![0.0f32; STATE_BUFFER_SIZE]),
        usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST,
    });

    // Clear both feedback textures so the first frames (LoadOp::Load) start black.
    {
        let mut enc = device.create_command_encoder(&Default::default());
        for v in [&view_a, &view_b] {
            enc.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("clear_fb"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: v,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                ..Default::default()
            });
        }
        queue.submit(std::iter::once(enc.finish()));
    }

    Ok(Pipeline {
        main,
        post,
        state_buffer,
        fb_textures: [fb_a, fb_b],
        fb_views: [view_a, view_b],
        result_idx: 0,
    })
}

fn bind_group_layout(device: &wgpu::Device) -> wgpu::BindGroupLayout {
    device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("render_bgl"),
        entries: &[
            wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            },
            wgpu::BindGroupLayoutEntry {
                binding: 1,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Storage { read_only: true },
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            },
            wgpu::BindGroupLayoutEntry {
                binding: 2,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Storage { read_only: true },
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            },
            wgpu::BindGroupLayoutEntry {
                binding: 3,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                count: None,
            },
            wgpu::BindGroupLayoutEntry {
                binding: 4,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Float { filterable: true },
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            },
        ],
    })
}

fn align_to(value: u32, alignment: u32) -> u32 {
    (value + alignment - 1) / alignment * alignment
}
