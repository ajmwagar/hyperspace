use anyhow::Result;
use cpal::traits::StreamTrait;
use rustfft::{num_complex::Complex, FftPlanner};
use std::sync::{Arc, Mutex};

pub const FFT_SIZE: usize = 1024;
const BEAT_THRESHOLD: f32 = 1.4;
const BEAT_DECAY: f32 = 0.95;
const NOISE_FLOOR: f32 = 1e-5; // gate out hiss below this RMS
const ATTACK: f32 = 0.6;       // EMA rise speed (0-1, higher = snappier)
const RELEASE: f32 = 0.12;     // EMA fall speed (0-1, higher = faster decay)
const AGC_ATTACK: f32 = 0.02;  // auto-gain rises slowly
const AGC_RELEASE: f32 = 0.001; // auto-gain falls very slowly (holds peaks)

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
    // Combined (average of L+R) — smoothed, auto-gained
    pub amplitude: f32,
    pub beat: f32,
    pub bass: f32,
    pub mid: f32,
    pub high: f32,
    pub spectrum: Vec<f32>,
    // Per-channel stereo — smoothed, auto-gained
    pub left: ChannelAnalysis,
    pub right: ChannelAnalysis,
    // Internal state
    energy_avg: f32,
    peak_amplitude: f32, // running peak for auto-gain
    peak_bass: f32,
    peak_mid: f32,
    peak_high: f32,
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
            peak_amplitude: 0.01,
            peak_bass: 0.01,
            peak_mid: 0.01,
            peak_high: 0.01,
        }
    }
}

/// Asymmetric EMA: fast attack, slow release — values jump up quickly but decay smoothly.
fn smooth(current: f32, target: f32) -> f32 {
    let alpha = if target > current { ATTACK } else { RELEASE };
    current + alpha * (target - current)
}

/// Update auto-gain peak tracker. Rises to meet signal, decays very slowly.
fn update_peak(peak: &mut f32, value: f32) {
    if value > *peak {
        *peak += AGC_ATTACK * (value - *peak);
    } else {
        *peak += AGC_RELEASE * (value - *peak);
    }
    *peak = peak.max(0.01); // never zero — avoid division by zero
}

/// Normalize a value against a running peak, clamped to 0..1.
fn auto_gain(value: f32, peak: f32) -> f32 {
    (value / peak).min(1.0)
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

                // Analyze both channels (raw)
                let raw_l = analyze_channel(&fft, &mut scratch, &window_l, &mut fft_buf_l, sample_rate);
                let raw_r = analyze_channel(&fft, &mut scratch, &window_r, &mut fft_buf_r, sample_rate);

                // Combined raw values
                let raw_amp = (raw_l.amplitude + raw_r.amplitude) * 0.5;
                let raw_bass = (raw_l.bass + raw_r.bass) * 0.5;
                let raw_mid = (raw_l.mid + raw_r.mid) * 0.5;
                let raw_high = (raw_l.high + raw_r.high) * 0.5;

                // Noise gate
                if raw_amp < NOISE_FLOOR {
                    let mut data = shared.lock().unwrap();
                    // Decay toward zero smoothly
                    data.amplitude = smooth(data.amplitude, 0.0);
                    data.bass = smooth(data.bass, 0.0);
                    data.mid = smooth(data.mid, 0.0);
                    data.high = smooth(data.high, 0.0);
                    data.left.amplitude = smooth(data.left.amplitude, 0.0);
                    data.left.bass = smooth(data.left.bass, 0.0);
                    data.left.mid = smooth(data.left.mid, 0.0);
                    data.left.high = smooth(data.left.high, 0.0);
                    data.right.amplitude = smooth(data.right.amplitude, 0.0);
                    data.right.bass = smooth(data.right.bass, 0.0);
                    data.right.mid = smooth(data.right.mid, 0.0);
                    data.right.high = smooth(data.right.high, 0.0);
                    data.beat *= BEAT_DECAY;
                    continue;
                }

                let half = FFT_SIZE / 2;

                // Update auto-gain peaks
                let mut data = shared.lock().unwrap();
                update_peak(&mut data.peak_amplitude, raw_amp);
                update_peak(&mut data.peak_bass, raw_bass);
                update_peak(&mut data.peak_mid, raw_mid);
                update_peak(&mut data.peak_high, raw_high);

                // Auto-gain normalize: scale to 0..1 based on recent peaks
                let norm_amp = auto_gain(raw_amp, data.peak_amplitude);
                let norm_bass = auto_gain(raw_bass, data.peak_bass);
                let norm_mid = auto_gain(raw_mid, data.peak_mid);
                let norm_high = auto_gain(raw_high, data.peak_high);

                // Smooth combined values (fast attack, slow release)
                data.amplitude = smooth(data.amplitude, norm_amp);
                data.bass = smooth(data.bass, norm_bass);
                data.mid = smooth(data.mid, norm_mid);
                data.high = smooth(data.high, norm_high);

                // Smooth + normalize per-channel
                let norm_l_amp = auto_gain(raw_l.amplitude, data.peak_amplitude);
                let norm_r_amp = auto_gain(raw_r.amplitude, data.peak_amplitude);
                data.left.amplitude = smooth(data.left.amplitude, norm_l_amp);
                data.right.amplitude = smooth(data.right.amplitude, norm_r_amp);
                data.left.bass = smooth(data.left.bass, auto_gain(raw_l.bass, data.peak_bass));
                data.right.bass = smooth(data.right.bass, auto_gain(raw_r.bass, data.peak_bass));
                data.left.mid = smooth(data.left.mid, auto_gain(raw_l.mid, data.peak_mid));
                data.right.mid = smooth(data.right.mid, auto_gain(raw_r.mid, data.peak_mid));
                data.left.high = smooth(data.left.high, auto_gain(raw_l.high, data.peak_high));
                data.right.high = smooth(data.right.high, auto_gain(raw_r.high, data.peak_high));

                // Spectrum: combine, log-scale, smooth
                for i in 0..half {
                    let raw = (raw_l.spectrum[i] + raw_r.spectrum[i]) * 0.5;
                    // Log scale: map tiny FFT values to visible range
                    // 20*log10(x) dB, normalized so -60dB..0dB maps to 0..1
                    let db = if raw > 1e-10 { 20.0 * raw.log10() } else { -120.0 };
                    let norm = ((db + 60.0) / 60.0).clamp(0.0, 1.0);
                    // Smooth each bin
                    data.spectrum[i] = smooth(data.spectrum[i], norm);
                }
                data.left.spectrum.copy_from_slice(&raw_l.spectrum);
                data.right.spectrum.copy_from_slice(&raw_r.spectrum);

                // Beat detection on normalized signal
                let energy = norm_bass * 2.0 + norm_mid;
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
