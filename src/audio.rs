use anyhow::Result;
use cpal::traits::StreamTrait;
use rustfft::{num_complex::Complex, FftPlanner};
use std::sync::{Arc, Mutex};

pub const FFT_SIZE: usize = 1024;

// ============================================================
// Tuning constants — the soul of the visual feel
// ============================================================

const NOISE_FLOOR: f32 = 1e-5;

// Per-band attack/release — bass sustains, highs snap
const BASS_ATTACK: f32 = 0.4;
const BASS_RELEASE: f32 = 0.06;   // slow decay — bass hangs in the air
const MID_ATTACK: f32 = 0.5;
const MID_RELEASE: f32 = 0.12;    // moderate decay
const HIGH_ATTACK: f32 = 0.7;
const HIGH_RELEASE: f32 = 0.25;   // fast decay — highs are transient
const AMP_ATTACK: f32 = 0.5;
const AMP_RELEASE: f32 = 0.08;    // overall envelope sustains

// AGC: much less aggressive — let dynamics breathe
const AGC_ATTACK: f32 = 0.005;    // rises very slowly (was 0.02)
const AGC_RELEASE: f32 = 0.0003;  // decays extremely slowly — holds the room level

// Beat detection
const BEAT_THRESHOLD: f32 = 1.5;  // slightly higher threshold, less trigger-happy
const BEAT_DECAY: f32 = 0.92;     // faster beat decay so it's more of a pulse

// Onset detection (spectral flux)
const ONSET_ATTACK: f32 = 0.8;    // onsets are instant
const ONSET_RELEASE: f32 = 0.3;   // decay quickly — it's a transient detector
const ONSET_THRESHOLD: f32 = 0.02; // minimum flux to register

// Spectrum smoothing
const SPECTRUM_ATTACK: f32 = 0.6;
const SPECTRUM_RELEASE: f32 = 0.08;

// ============================================================
// Data types
// ============================================================

/// Which two channels to capture from the audio device.
#[derive(Debug, Clone, Copy)]
pub struct ChannelPair {
    pub left: usize,
    pub right: usize,
}

impl ChannelPair {
    pub fn default_for(num_channels: usize) -> Self {
        if num_channels >= 6 {
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
    // Combined (average of L+R) — smoothed with per-band curves, soft AGC
    pub amplitude: f32,
    pub beat: f32,
    pub bass: f32,
    pub mid: f32,
    pub high: f32,
    pub spectrum: Vec<f32>,

    // New: additional analysis
    pub onset: f32,       // spectral flux — fires on note onsets, transients
    pub sub_bass: f32,    // 20-60Hz — sub rumble, separate from kick
    pub presence: f32,    // 4-8kHz — vocal presence, cymbal shimmer

    // Per-channel stereo
    pub left: ChannelAnalysis,
    pub right: ChannelAnalysis,

    // Raw waveform
    pub waveform_l: Vec<f32>,
    pub waveform_r: Vec<f32>,

    // Internal state
    energy_avg: f32,
    peak_amplitude: f32,
    peak_bass: f32,
    peak_mid: f32,
    peak_high: f32,
    prev_spectrum: Vec<f32>,  // for spectral flux (onset detection)
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
            onset: 0.0,
            sub_bass: 0.0,
            presence: 0.0,
            left: ChannelAnalysis { spectrum: vec![0.0; half], ..Default::default() },
            right: ChannelAnalysis { spectrum: vec![0.0; half], ..Default::default() },
            waveform_l: vec![0.0; 512],
            waveform_r: vec![0.0; 512],
            energy_avg: 0.0,
            peak_amplitude: 0.01,
            peak_bass: 0.01,
            peak_mid: 0.01,
            peak_high: 0.01,
            prev_spectrum: vec![0.0; half],
        }
    }
}

/// Per-band asymmetric EMA with custom attack/release.
fn smooth_band(current: f32, target: f32, attack: f32, release: f32) -> f32 {
    let alpha = if target > current { attack } else { release };
    current + alpha * (target - current)
}

/// Update auto-gain peak tracker — much gentler than before.
fn update_peak(peak: &mut f32, value: f32) {
    if value > *peak {
        *peak += AGC_ATTACK * (value - *peak);
    } else {
        *peak += AGC_RELEASE * (value - *peak);
    }
    *peak = peak.max(0.005);
}

/// Soft normalize — uses sqrt curve instead of linear divide.
/// This preserves more dynamic range than straight normalization.
/// Quiet is still quiet, loud is still loud, but nothing clips.
fn soft_normalize(value: f32, peak: f32) -> f32 {
    let ratio = value / peak;
    // Soft knee: below 0.5 ratio, linear. Above, compress.
    if ratio < 0.5 {
        ratio * 1.2  // slight boost to quiet signals
    } else {
        let compressed = 0.6 + 0.4 * ((ratio - 0.5) / 0.5).sqrt();
        compressed.min(1.0)
    }
}

pub type SharedAudioData = Arc<Mutex<AudioData>>;

pub fn new_shared() -> SharedAudioData {
    Arc::new(Mutex::new(AudioData::default()))
}

/// Start capturing audio from a specific device.
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
                std::thread::sleep(std::time::Duration::from_millis(8));

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

                // Raw waveform
                let wave_start = samples.len().saturating_sub(512);
                let raw_wave_l: Vec<f32> = samples[wave_start..].iter().map(|&(l, _)| l).collect();
                let raw_wave_r: Vec<f32> = samples[wave_start..].iter().map(|&(_, r)| r).collect();

                // Hann window + deinterleave
                for (i, &(l, r)) in samples.iter().enumerate().take(FFT_SIZE) {
                    let w = 0.5 * (1.0 - (2.0 * std::f32::consts::PI * i as f32 / FFT_SIZE as f32).cos());
                    window_l[i] = l * w;
                    window_r[i] = r * w;
                }

                // FFT both channels
                let raw_l = analyze_channel(&fft, &mut scratch, &window_l, &mut fft_buf_l, sample_rate);
                let raw_r = analyze_channel(&fft, &mut scratch, &window_r, &mut fft_buf_r, sample_rate);

                // Combined raw
                let raw_amp = (raw_l.amplitude + raw_r.amplitude) * 0.5;
                let raw_bass = (raw_l.bass + raw_r.bass) * 0.5;
                let raw_mid = (raw_l.mid + raw_r.mid) * 0.5;
                let raw_high = (raw_l.high + raw_r.high) * 0.5;

                // Noise gate
                if raw_amp < NOISE_FLOOR {
                    let mut data = shared.lock().unwrap();
                    data.amplitude = smooth_band(data.amplitude, 0.0, AMP_ATTACK, AMP_RELEASE);
                    data.bass = smooth_band(data.bass, 0.0, BASS_ATTACK, BASS_RELEASE);
                    data.mid = smooth_band(data.mid, 0.0, MID_ATTACK, MID_RELEASE);
                    data.high = smooth_band(data.high, 0.0, HIGH_ATTACK, HIGH_RELEASE);
                    data.sub_bass = smooth_band(data.sub_bass, 0.0, BASS_ATTACK, BASS_RELEASE * 0.5);
                    data.presence = smooth_band(data.presence, 0.0, HIGH_ATTACK, HIGH_RELEASE);
                    data.onset = smooth_band(data.onset, 0.0, ONSET_ATTACK, ONSET_RELEASE);
                    data.left.amplitude = smooth_band(data.left.amplitude, 0.0, AMP_ATTACK, AMP_RELEASE);
                    data.right.amplitude = smooth_band(data.right.amplitude, 0.0, AMP_ATTACK, AMP_RELEASE);
                    data.beat *= BEAT_DECAY;
                    continue;
                }

                let half = FFT_SIZE / 2;

                // ============================================================
                // Soft AGC — preserves dynamics, doesn't flatten
                // ============================================================
                let mut data = shared.lock().unwrap();
                update_peak(&mut data.peak_amplitude, raw_amp);
                update_peak(&mut data.peak_bass, raw_bass);
                update_peak(&mut data.peak_mid, raw_mid);
                update_peak(&mut data.peak_high, raw_high);

                let norm_amp = soft_normalize(raw_amp, data.peak_amplitude);
                let norm_bass = soft_normalize(raw_bass, data.peak_bass);
                let norm_mid = soft_normalize(raw_mid, data.peak_mid);
                let norm_high = soft_normalize(raw_high, data.peak_high);

                // ============================================================
                // Per-band smoothing — each band has its own character
                // ============================================================
                data.amplitude = smooth_band(data.amplitude, norm_amp, AMP_ATTACK, AMP_RELEASE);
                data.bass = smooth_band(data.bass, norm_bass, BASS_ATTACK, BASS_RELEASE);
                data.mid = smooth_band(data.mid, norm_mid, MID_ATTACK, MID_RELEASE);
                data.high = smooth_band(data.high, norm_high, HIGH_ATTACK, HIGH_RELEASE);

                // ============================================================
                // Extra bands: sub-bass (20-60Hz) and presence (4-8kHz)
                // ============================================================
                let bin_hz = sample_rate / FFT_SIZE as f32;
                let combined_spectrum: Vec<f32> = (0..half)
                    .map(|i| (raw_l.spectrum[i] + raw_r.spectrum[i]) * 0.5)
                    .collect();

                let band_energy = |from_hz: f32, to_hz: f32| -> f32 {
                    let from = (from_hz / bin_hz) as usize;
                    let to = (to_hz / bin_hz).min(half as f32) as usize;
                    if to <= from { return 0.0; }
                    combined_spectrum[from..to].iter().map(|s| s * s).sum::<f32>() / (to - from) as f32
                };

                let raw_sub = band_energy(20.0, 60.0).sqrt();
                let raw_presence = band_energy(4000.0, 8000.0).sqrt();
                let norm_sub = soft_normalize(raw_sub, data.peak_bass); // share bass peak
                let norm_presence = soft_normalize(raw_presence, data.peak_high); // share high peak
                data.sub_bass = smooth_band(data.sub_bass, norm_sub, BASS_ATTACK, BASS_RELEASE * 0.5);
                data.presence = smooth_band(data.presence, norm_presence, HIGH_ATTACK, HIGH_RELEASE);

                // ============================================================
                // Spectral flux (onset detection)
                // ============================================================
                let mut flux = 0.0f32;
                for i in 0..half {
                    let diff = combined_spectrum[i] - data.prev_spectrum[i];
                    if diff > 0.0 {
                        flux += diff; // only positive changes (onsets, not offsets)
                    }
                }
                flux /= half as f32;
                let onset_raw = if flux > ONSET_THRESHOLD { flux * 50.0 } else { 0.0 };
                data.onset = smooth_band(data.onset, onset_raw.min(1.0), ONSET_ATTACK, ONSET_RELEASE);

                // Store current spectrum for next frame's flux calculation
                data.prev_spectrum.copy_from_slice(&combined_spectrum);

                // ============================================================
                // Per-channel stereo (same soft AGC + per-band smoothing)
                // ============================================================
                let norm_l_amp = soft_normalize(raw_l.amplitude, data.peak_amplitude);
                let norm_r_amp = soft_normalize(raw_r.amplitude, data.peak_amplitude);
                data.left.amplitude = smooth_band(data.left.amplitude, norm_l_amp, AMP_ATTACK, AMP_RELEASE);
                data.right.amplitude = smooth_band(data.right.amplitude, norm_r_amp, AMP_ATTACK, AMP_RELEASE);
                data.left.bass = smooth_band(data.left.bass, soft_normalize(raw_l.bass, data.peak_bass), BASS_ATTACK, BASS_RELEASE);
                data.right.bass = smooth_band(data.right.bass, soft_normalize(raw_r.bass, data.peak_bass), BASS_ATTACK, BASS_RELEASE);
                data.left.mid = smooth_band(data.left.mid, soft_normalize(raw_l.mid, data.peak_mid), MID_ATTACK, MID_RELEASE);
                data.right.mid = smooth_band(data.right.mid, soft_normalize(raw_r.mid, data.peak_mid), MID_ATTACK, MID_RELEASE);
                data.left.high = smooth_band(data.left.high, soft_normalize(raw_l.high, data.peak_high), HIGH_ATTACK, HIGH_RELEASE);
                data.right.high = smooth_band(data.right.high, soft_normalize(raw_r.high, data.peak_high), HIGH_ATTACK, HIGH_RELEASE);

                // ============================================================
                // Spectrum: log-scale with per-bin smoothing
                // ============================================================
                for i in 0..half {
                    let raw = combined_spectrum[i];
                    let db = if raw > 1e-10 { 20.0 * raw.log10() } else { -120.0 };
                    let norm = ((db + 60.0) / 60.0).clamp(0.0, 1.0);
                    data.spectrum[i] = smooth_band(data.spectrum[i], norm, SPECTRUM_ATTACK, SPECTRUM_RELEASE);
                }
                data.left.spectrum.copy_from_slice(&raw_l.spectrum);
                data.right.spectrum.copy_from_slice(&raw_r.spectrum);

                // Waveform
                let wl = &mut data.waveform_l;
                wl.resize(raw_wave_l.len(), 0.0);
                wl.copy_from_slice(&raw_wave_l);
                let wr = &mut data.waveform_r;
                wr.resize(raw_wave_r.len(), 0.0);
                wr.copy_from_slice(&raw_wave_r);

                // ============================================================
                // Beat detection — on raw energy, not normalized
                // This means quiet sections DON'T trigger beats
                // ============================================================
                let energy = raw_bass * 2.0 + raw_mid;
                if energy > data.energy_avg * BEAT_THRESHOLD && data.beat < 0.3 {
                    data.beat = 1.0;
                } else {
                    data.beat *= BEAT_DECAY;
                }
                data.energy_avg = data.energy_avg * 0.93 + energy * 0.07;
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

    let rms = (windowed.iter().map(|s| s * s).sum::<f32>() / n as f32).sqrt();

    for (i, &w) in windowed.iter().enumerate() {
        fft_buf[i] = Complex::new(w, 0.0);
    }
    fft.process_with_scratch(fft_buf, scratch);

    let mut spectrum = Vec::with_capacity(half);
    for i in 0..half {
        spectrum.push(fft_buf[i].norm() / n as f32);
    }

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
        assert_eq!(data.onset, 0.0);
        assert_eq!(data.sub_bass, 0.0);
        assert_eq!(data.presence, 0.0);
        assert_eq!(data.spectrum.len(), FFT_SIZE / 2);
        assert_eq!(data.prev_spectrum.len(), FFT_SIZE / 2);
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
    }

    #[test]
    fn channel_pair_parse() {
        let pair = ChannelPair::parse("4,5").unwrap();
        assert_eq!(pair.left, 4);
        assert_eq!(pair.right, 5);

        assert!(ChannelPair::parse("bad").is_none());
    }

    #[test]
    fn soft_normalize_dynamics() {
        // Quiet signal against loud peak — should still be low
        assert!(soft_normalize(0.1, 1.0) < 0.2);
        // Loud signal at peak — should be near 1.0
        assert!(soft_normalize(1.0, 1.0) > 0.9);
        // Half signal — should be compressed but not flattened
        let half = soft_normalize(0.5, 1.0);
        assert!(half > 0.5 && half < 0.8);
    }

    #[test]
    fn per_band_smoothing() {
        // Bass should decay slower than highs
        let bass = smooth_band(1.0, 0.0, BASS_ATTACK, BASS_RELEASE);
        let high = smooth_band(1.0, 0.0, HIGH_ATTACK, HIGH_RELEASE);
        assert!(bass > high, "bass should decay slower: bass={} high={}", bass, high);
    }

    #[test]
    fn rms_silence() {
        assert_eq!(rms(&[0.0; 1024]), 0.0);
        assert_eq!(rms(&[]), 0.0);
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
