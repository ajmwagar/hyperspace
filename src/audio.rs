use anyhow::Result;
use cpal::traits::StreamTrait;
use rustfft::{num_complex::Complex, FftPlanner};
use std::sync::{Arc, Mutex};

pub const FFT_SIZE: usize = 1024;
const BEAT_THRESHOLD: f32 = 1.4;
const BEAT_DECAY: f32 = 0.95;

/// Which two channels to capture from the audio device.
#[derive(Debug, Clone, Copy)]
pub struct ChannelPair {
    pub left: usize,
    pub right: usize,
}

impl ChannelPair {
    /// Smart default: on 6-channel devices (Scarlett 4i4), use channels 4-5 (loopback).
    /// On 2-channel devices, use 0-1.
    pub fn default_for(num_channels: usize) -> Self {
        if num_channels >= 6 {
            // Scarlett 4i4 4th Gen: ch 0-3 = analog inputs, ch 4-5 = loopback
            Self { left: 4, right: 5 }
        } else {
            Self { left: 0, right: 1.min(num_channels.saturating_sub(1)) }
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        let parts: Vec<&str> = s.split(',').collect();
        if parts.len() == 2 {
            let l = parts[0].trim().parse().ok()?;
            let r = parts[1].trim().parse().ok()?;
            Some(Self { left: l, right: r })
        } else {
            None
        }
    }
}

/// Per-channel analysis results.
#[derive(Debug, Clone, Default)]
pub struct ChannelAnalysis {
    pub amplitude: f32,
    pub bass: f32,
    pub mid: f32,
    pub high: f32,
    pub spectrum: Vec<f32>,
}

/// Raw audio analysis data shared between audio thread and render thread.
pub struct AudioData {
    // Combined (average of L+R)
    pub amplitude: f32,
    pub beat: f32,
    pub bass: f32,
    pub mid: f32,
    pub high: f32,
    pub spectrum: Vec<f32>,
    // Per-channel stereo
    pub left: ChannelAnalysis,
    pub right: ChannelAnalysis,
    // Internal state for beat detection
    energy_avg: f32,
}

impl Default for AudioData {
    fn default() -> Self {
        let half = FFT_SIZE / 2;
        Self {
            amplitude: 0.0,
            beat: 0.0,
            bass: 0.0,
            mid: 0.0,
            high: 0.0,
            spectrum: vec![0.0; half],
            left: ChannelAnalysis { spectrum: vec![0.0; half], ..Default::default() },
            right: ChannelAnalysis { spectrum: vec![0.0; half], ..Default::default() },
            energy_avg: 0.0,
        }
    }
}

pub type SharedAudioData = Arc<Mutex<AudioData>>;

pub fn new_shared() -> SharedAudioData {
    Arc::new(Mutex::new(AudioData::default()))
}

/// Start capturing audio from a specific device.
/// Captures a stereo pair of channels. Returns the stream handle (must be kept alive).
pub fn start_capture_device(shared: SharedAudioData, device: cpal::Device, channels_override: Option<ChannelPair>) -> Result<cpal::Stream> {
    use cpal::traits::DeviceTrait;

    log::info!("audio input device: {}", device.name().unwrap_or_default());

    let config = device.default_input_config()?;
    let sample_rate = config.sample_rate().0 as f32;
    let num_channels = config.channels() as usize;

    let pair = channels_override.unwrap_or_else(|| ChannelPair::default_for(num_channels));

    log::info!(
        "audio config: {}Hz, {} device channels, capturing L={} R={}, {:?}",
        sample_rate, num_channels, pair.left, pair.right, config.sample_format()
    );

    if pair.left >= num_channels || pair.right >= num_channels {
        anyhow::bail!(
            "channel {} or {} out of range (device has {} channels)",
            pair.left, pair.right, num_channels
        );
    }

    // Ring buffers: interleaved L, R pairs
    let ring = Arc::new(Mutex::new(Vec::<(f32, f32)>::with_capacity(FFT_SIZE * 2)));

    let ring_writer = ring.clone();
    let stream = device.build_input_stream(
        &config.into(),
        move |data: &[f32], _: &cpal::InputCallbackInfo| {
            let mut buf = ring_writer.lock().unwrap();
            for frame in data.chunks(num_channels) {
                let l = frame.get(pair.left).copied().unwrap_or(0.0);
                let r = frame.get(pair.right).copied().unwrap_or(0.0);
                buf.push((l, r));
            }
        },
        |err| log::error!("audio stream error: {}", err),
        None,
    )?;

    stream.play()?;

    // Spawn analysis thread
    std::thread::Builder::new()
        .name("audio-analysis".into())
        .spawn(move || {
            let mut planner = FftPlanner::<f32>::new();
            let fft = planner.plan_fft_forward(FFT_SIZE);
            let mut scratch = vec![Complex::default(); fft.get_inplace_scratch_len()];

            let mut window_l = vec![0.0f32; FFT_SIZE];
            let mut window_r = vec![0.0f32; FFT_SIZE];
            let mut fft_buf_l = vec![Complex::default(); FFT_SIZE];
            let mut fft_buf_r = vec![Complex::default(); FFT_SIZE];

            loop {
                std::thread::sleep(std::time::Duration::from_millis(8)); // ~120Hz analysis

                // Drain stereo samples from ring buffer
                let samples: Vec<(f32, f32)> = {
                    let mut buf = ring.lock().unwrap();
                    if buf.len() < FFT_SIZE {
                        continue;
                    }
                    let start = buf.len().saturating_sub(FFT_SIZE);
                    let out = buf[start..].to_vec();
                    buf.clear();
                    out
                };

                // Deinterleave and apply Hann window
                for (i, &(l, r)) in samples.iter().enumerate().take(FFT_SIZE) {
                    let w = 0.5 * (1.0 - (2.0 * std::f32::consts::PI * i as f32 / FFT_SIZE as f32).cos());
                    window_l[i] = l * w;
                    window_r[i] = r * w;
                }

                // Analyze both channels
                let left = analyze_channel(&fft, &mut scratch, &window_l, &mut fft_buf_l, sample_rate);
                let right = analyze_channel(&fft, &mut scratch, &window_r, &mut fft_buf_r, sample_rate);

                // Combined (average)
                let amplitude = (left.amplitude + right.amplitude) * 0.5;
                let bass = (left.bass + right.bass) * 0.5;
                let mid = (left.mid + right.mid) * 0.5;
                let high = (left.high + right.high) * 0.5;

                let half = FFT_SIZE / 2;
                let mut spectrum = vec![0.0f32; half];
                for i in 0..half {
                    spectrum[i] = (left.spectrum[i] + right.spectrum[i]) * 0.5;
                }

                // Update shared data
                let mut data = shared.lock().unwrap();
                data.amplitude = amplitude;
                data.bass = bass;
                data.mid = mid;
                data.high = high;
                data.spectrum.copy_from_slice(&spectrum);
                data.left = left;
                data.right = right;

                // Beat detection on combined signal
                let energy = bass * 2.0 + mid;
                if energy > data.energy_avg * BEAT_THRESHOLD && data.beat < 0.3 {
                    data.beat = 1.0;
                } else {
                    data.beat *= BEAT_DECAY;
                }
                data.energy_avg = data.energy_avg * 0.95 + energy * 0.05;
            }
        })?;

    Ok(stream)
}

fn analyze_channel(
    fft: &std::sync::Arc<dyn rustfft::Fft<f32>>,
    scratch: &mut [Complex<f32>],
    windowed: &[f32],
    fft_buf: &mut [Complex<f32>],
    sample_rate: f32,
) -> ChannelAnalysis {
    let n = windowed.len();
    let half = n / 2;

    // RMS
    let rms = (windowed.iter().map(|s| s * s).sum::<f32>() / n as f32).sqrt();

    // FFT
    for (i, &w) in windowed.iter().enumerate() {
        fft_buf[i] = Complex::new(w, 0.0);
    }
    fft.process_with_scratch(fft_buf, scratch);

    // Magnitude spectrum
    let mut spectrum = Vec::with_capacity(half);
    for i in 0..half {
        spectrum.push(fft_buf[i].norm() / n as f32);
    }

    // Band energies
    let bin_hz = sample_rate / n as f32;
    let bass_end = (250.0 / bin_hz) as usize;
    let mid_end = (4000.0 / bin_hz) as usize;
    let high_end = (20000.0 / bin_hz).min(half as f32) as usize;

    let band_energy = |from: usize, to: usize| -> f32 {
        if to <= from { return 0.0; }
        spectrum[from..to.min(half)].iter().map(|s| s * s).sum::<f32>() / (to - from) as f32
    };

    ChannelAnalysis {
        amplitude: rms,
        bass: band_energy(1, bass_end).sqrt(),
        mid: band_energy(bass_end, mid_end).sqrt(),
        high: band_energy(mid_end, high_end).sqrt(),
        spectrum,
    }
}

/// Compute RMS amplitude of a sample buffer.
pub fn rms(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    (samples.iter().map(|s| s * s).sum::<f32>() / samples.len() as f32).sqrt()
}

/// Apply a Hann window in-place.
pub fn hann_window(samples: &mut [f32]) {
    let n = samples.len() as f32;
    for (i, s) in samples.iter_mut().enumerate() {
        let w = 0.5 * (1.0 - (2.0 * std::f32::consts::PI * i as f32 / n).cos());
        *s *= w;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn audio_data_defaults() {
        let data = AudioData::default();
        assert_eq!(data.amplitude, 0.0);
        assert_eq!(data.beat, 0.0);
        assert_eq!(data.bass, 0.0);
        assert_eq!(data.spectrum.len(), FFT_SIZE / 2);
        assert_eq!(data.left.spectrum.len(), FFT_SIZE / 2);
        assert_eq!(data.right.spectrum.len(), FFT_SIZE / 2);
    }

    #[test]
    fn shared_audio_data() {
        let shared = new_shared();
        {
            let mut data = shared.lock().unwrap();
            data.amplitude = 0.5;
            data.beat = 1.0;
        }
        let data = shared.lock().unwrap();
        assert_eq!(data.amplitude, 0.5);
        assert_eq!(data.beat, 1.0);
    }

    #[test]
    fn channel_pair_defaults() {
        let pair = ChannelPair::default_for(6);
        assert_eq!(pair.left, 4);
        assert_eq!(pair.right, 5);

        let pair = ChannelPair::default_for(2);
        assert_eq!(pair.left, 0);
        assert_eq!(pair.right, 1);

        let pair = ChannelPair::default_for(1);
        assert_eq!(pair.left, 0);
        assert_eq!(pair.right, 0);
    }

    #[test]
    fn channel_pair_parse() {
        let pair = ChannelPair::parse("4,5").unwrap();
        assert_eq!(pair.left, 4);
        assert_eq!(pair.right, 5);

        let pair = ChannelPair::parse("0, 1").unwrap();
        assert_eq!(pair.left, 0);
        assert_eq!(pair.right, 1);

        assert!(ChannelPair::parse("bad").is_none());
    }

    #[test]
    fn rms_silence() {
        assert_eq!(rms(&[0.0; 1024]), 0.0);
        assert_eq!(rms(&[]), 0.0);
    }

    #[test]
    fn rms_dc_signal() {
        let samples = vec![0.5; 1024];
        assert!((rms(&samples) - 0.5).abs() < 1e-6);
    }

    #[test]
    fn rms_sine_wave() {
        let samples: Vec<f32> = (0..1024)
            .map(|i| (2.0 * std::f32::consts::PI * i as f32 / 1024.0).sin())
            .collect();
        let r = rms(&samples);
        assert!((r - std::f32::consts::FRAC_1_SQRT_2).abs() < 0.01);
    }

    #[test]
    fn hann_window_zeros_edges() {
        let mut buf = vec![1.0; 64];
        hann_window(&mut buf);
        assert!(buf[0].abs() < 1e-6);
        assert!(buf[32] > 0.9);
    }

    #[test]
    fn fft_produces_spectrum() {
        use rustfft::{num_complex::Complex, FftPlanner};

        let mut planner = FftPlanner::<f32>::new();
        let fft = planner.plan_fft_forward(FFT_SIZE);

        let sample_rate = 44100.0f32;
        let freq = 440.0;
        let mut buf: Vec<Complex<f32>> = (0..FFT_SIZE)
            .map(|i| {
                let t = i as f32 / sample_rate;
                Complex::new((2.0 * std::f32::consts::PI * freq * t).sin(), 0.0)
            })
            .collect();

        fft.process(&mut buf);

        let half = FFT_SIZE / 2;
        let magnitudes: Vec<f32> = buf[..half].iter().map(|c| c.norm()).collect();
        let peak_bin = magnitudes
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
            .unwrap()
            .0;

        let bin_hz = sample_rate / FFT_SIZE as f32;
        let peak_freq = peak_bin as f32 * bin_hz;

        assert!(
            (peak_freq - freq).abs() < bin_hz * 1.5,
            "peak at {}Hz, expected ~{}Hz",
            peak_freq,
            freq
        );
    }
}
