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
//! The actual scene rendering is performed by the reusable, device-injected
//! [`hyperspace::ScopeRenderer`] (see `src/offscreen.rs`). This example owns the
//! wgpu device, the audio analysis, and the ffmpeg muxing; it hands the device
//! and a target texture view to the renderer each frame. The audio-buffer
//! convention the shaders read:
//!   [0..512)     = FFT spectrum (log-scaled, matching src/audio.rs)
//!   [512..1024)  = waveform L
//!   [1024..1536) = waveform R

use hyperspace::{ScopeBands, ScopeRenderer, AUDIO_BUFFER_SIZE};
use rustfft::{num_complex::Complex, Fft, FftPlanner};
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::Arc;

const FFT_SIZE: usize = 1024; // matches src/audio.rs
const WAVEFORM_SIZE: usize = 512;
const SPECTRUM_SIZE: usize = 512;

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
        hound::SampleFormat::Float => reader.samples::<f32>().collect::<Result<Vec<_>, _>>()?,
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
        let w = 0.5 * (1.0 - (2.0 * std::f32::consts::PI * i as f32 / FFT_SIZE as f32).cos());
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

/// Stateful per-frame band + transient analysis for the uniform fields.
/// Not the full adaptive AGC from src/audio.rs, but close enough that
/// beat/onset-synced shaders fire offline: spectral-flux onsets, an
/// energy-threshold beat (kick + low mids), plus sub-bass and presence bands.
struct BandAnalyzer {
    sample_rate: u32,
    prev_spectrum: Vec<f32>,
    energy_avg: f32,
    beat: f32,
    onset: f32,
    sub_bass: f32,
    presence: f32,
}

impl BandAnalyzer {
    fn new(sample_rate: u32) -> Self {
        Self {
            sample_rate,
            prev_spectrum: vec![0.0; SPECTRUM_SIZE],
            energy_avg: 0.0,
            beat: 0.0,
            onset: 0.0,
            sub_bass: 0.0,
            presence: 0.0,
        }
    }

    fn update(&mut self, buf: &[f32; AUDIO_BUFFER_SIZE]) -> ScopeBands {
        let bin_hz = self.sample_rate as f32 / FFT_SIZE as f32;
        let band = |from_hz: f32, to_hz: f32| -> f32 {
            let from = (from_hz / bin_hz) as usize;
            let to = ((to_hz / bin_hz) as usize).min(SPECTRUM_SIZE);
            if to <= from {
                return 0.0;
            }
            buf[from..to].iter().sum::<f32>() / (to - from) as f32
        };

        // RMS over waveform L as amplitude.
        let wl = &buf[SPECTRUM_SIZE..SPECTRUM_SIZE + WAVEFORM_SIZE];
        let rms = (wl.iter().map(|s| s * s).sum::<f32>() / WAVEFORM_SIZE as f32).sqrt();
        let amplitude = (rms * 2.0).clamp(0.0, 1.0);

        let bass = band(60.0, 150.0).clamp(0.0, 1.0);
        let mid = band(150.0, 4000.0).clamp(0.0, 1.0);
        let high = band(4000.0, 16000.0).clamp(0.0, 1.0);
        let sub_bass = band(20.0, 60.0).clamp(0.0, 1.0);
        let presence = band(4000.0, 8000.0).clamp(0.0, 1.0);

        // Spectral flux → onset (positive changes only), like src/audio.rs.
        let spectrum = &buf[0..SPECTRUM_SIZE];
        let mut flux = 0.0f32;
        for i in 0..SPECTRUM_SIZE {
            let d = spectrum[i] - self.prev_spectrum[i];
            if d > 0.0 {
                flux += d;
            }
        }
        flux /= SPECTRUM_SIZE as f32;
        self.prev_spectrum.copy_from_slice(spectrum);
        let onset_raw = if flux > 0.0006 { (flux * 120.0).min(1.0) } else { 0.0 };
        // Instant attack, gradual release.
        self.onset = onset_raw.max(self.onset * 0.7);

        // Beat: energy over a running average (kick + low mids), gated so it
        // pulses rather than latches.
        let energy = bass * 2.0 + mid;
        if energy > self.energy_avg * 1.4 && self.beat < 0.3 {
            self.beat = 1.0;
        } else {
            self.beat *= 0.80;
        }
        self.energy_avg = self.energy_avg * 0.93 + energy * 0.07;

        // Light smoothing on the extra bands.
        self.sub_bass = self.sub_bass * 0.6 + sub_bass * 0.4;
        self.presence = self.presence * 0.5 + presence * 0.5;

        ScopeBands {
            amplitude,
            bass,
            mid,
            high,
            beat: self.beat,
            onset: self.onset,
            sub_bass: self.sub_bass,
            presence: self.presence,
        }
    }
}

async fn run(
    input: &str,
    output: &str,
    scene_path: &str,
    fps: u32,
    width: u32,
    height: u32,
) -> anyhow::Result<()> {
    // ---- decode audio ----
    let audio = decode_wav(input)?;
    let total_samples = audio.left.len();
    let duration = total_samples as f64 / audio.sample_rate as f64;
    let total_frames = (duration * fps as f64).ceil() as usize;
    println!(
        "decoded {}: {}Hz, {} samples, {:.2}s → {} frames @ {}fps",
        input, audio.sample_rate, total_samples, duration, total_frames, fps
    );

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

    // Render the final blit into an sRGB target. The shaders' colours are
    // authored for an sRGB display (like the live engine's surface), so the
    // blit's linear output must be sRGB-encoded on store; the bytes we read
    // back are then the correct display values to hand ffmpeg as rawvideo rgba.
    // (Without this the whole render comes out gamma-darkened.)
    let format = wgpu::TextureFormat::Rgba8UnormSrgb;

    // The scope renderer draws into this target each frame; we copy it back.
    let target = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("render_target"),
        size: wgpu::Extent3d {
            width,
            height,
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
        view_formats: &[],
    });
    let target_view = target.create_view(&Default::default());

    let mut scope = ScopeRenderer::new(
        &device,
        &queue,
        format,
        Path::new(scene_path),
        Path::new("."),
        width,
        height,
    )?;
    println!("scope renderer ready ({}x{})", width, height);

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
            "-f",
            "rawvideo",
            "-pix_fmt",
            "rgba",
            "-s",
            &format!("{}x{}", width, height),
            "-r",
            &fps.to_string(),
            "-i",
            "-",
            "-i",
            input,
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-b:a",
            "256k",
            "-ac",
            "2", // upmix mono → stereo (AAC rejects "1 channel (FL)" layouts)
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

    let mut audio_data = [0.0f32; AUDIO_BUFFER_SIZE];
    let mut analyzer = BandAnalyzer::new(audio.sample_rate);

    for frame_idx in 0..total_frames {
        let time = frame_idx as f32 / fps as f32;
        // Sample window aligned so the most recent audio is at this frame's time.
        let center = ((time as f64) * audio.sample_rate as f64) as usize;

        compute_audio_buffer(&audio, center, &fft, &mut scratch, &mut audio_data);
        let bands = analyzer.update(&audio_data);

        scope.render(&device, &queue, &target_view, &audio_data, time, bands);

        // Copy the rendered target texture to the readback buffer.
        let mut enc = device.create_command_encoder(&Default::default());
        enc.copy_texture_to_buffer(
            target.as_image_copy(),
            wgpu::TexelCopyBufferInfo {
                buffer: &readback,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(bytes_per_row),
                    rows_per_image: Some(height),
                },
            },
            wgpu::Extent3d {
                width,
                height,
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
            println!(
                "  frame {}/{} ({:.0}%)",
                frame_idx,
                total_frames,
                100.0 * frame_idx as f32 / total_frames as f32
            );
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

fn align_to(value: u32, alignment: u32) -> u32 {
    (value + alignment - 1) / alignment * alignment
}
