use anyhow::Result;
use cpal::traits::StreamTrait;
use rustfft::{num_complex::Complex, FftPlanner};
use std::sync::{Arc, Mutex};

pub const FFT_SIZE: usize = 1024;

// ============================================================
// Tuning constants — the soul of the visual feel
// ============================================================

const NOISE_FLOOR: f32 = 1e-5;

// Base attack/release per band — these get MODULATED by the crest factor
// Transient material (kick) will use the fast end, sustained (pad) the slow end
const BASS_ATTACK_RANGE: [f32; 2] = [0.3, 0.8];   // [sustained, transient]
const BASS_RELEASE_RANGE: [f32; 2] = [0.04, 0.2];  // [sustained, transient]
const MID_ATTACK_RANGE: [f32; 2] = [0.25, 0.7];
const MID_RELEASE_RANGE: [f32; 2] = [0.05, 0.18];
const HIGH_ATTACK_RANGE: [f32; 2] = [0.4, 0.85];
const HIGH_RELEASE_RANGE: [f32; 2] = [0.1, 0.35];
const AMP_ATTACK_RANGE: [f32; 2] = [0.25, 0.7];
const AMP_RELEASE_RANGE: [f32; 2] = [0.03, 0.12];

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

    // Additional analysis
    pub onset: f32,       // spectral flux — fires on note onsets, transients
    pub sub_bass: f32,    // 20-60Hz — sub rumble, separate from kick
    pub presence: f32,    // 4-8kHz — vocal presence, cymbal shimmer

    // Adaptive dynamics
    pub crest: f32,       // crest factor (0-1 normalized): 0=sustained, 1=transient
    pub centroid: f32,    // spectral centroid (0-1 normalized): 0=bassy, 1=bright

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
            crest: 0.0,
            centroid: 0.0,
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

/// Compute crest factor from raw samples: peak / RMS, normalized to 0-1.
/// High crest (>3) = sharp transient. Low crest (<1.5) = sustained.
fn compute_crest(samples: &[(f32, f32)]) -> f32 {
    let mut peak = 0.0f32;
    let mut sum_sq = 0.0f32;
    for &(l, r) in samples {
        let mono = (l + r) * 0.5;
        peak = peak.max(mono.abs());
        sum_sq += mono * mono;
    }
    let rms = (sum_sq / samples.len() as f32).sqrt();
    if rms < 1e-8 { return 0.0; }
    let crest = peak / rms;
    // Normalize: crest of 1.0 (DC) → 0.0, crest of 5.0+ → 1.0
    ((crest - 1.0) / 4.0).clamp(0.0, 1.0)
}

/// Compute spectral centroid: weighted average frequency, normalized to 0-1.
fn compute_centroid(spectrum: &[f32], bin_hz: f32, max_hz: f32) -> f32 {
    let mut weighted_sum = 0.0f32;
    let mut total_energy = 0.0f32;
    for (i, &mag) in spectrum.iter().enumerate() {
        let freq = i as f32 * bin_hz;
        if freq > max_hz { break; }
        weighted_sum += freq * mag;
        total_energy += mag;
    }
    if total_energy < 1e-10 { return 0.0; }
    let centroid_hz = weighted_sum / total_energy;
    (centroid_hz / max_hz).clamp(0.0, 1.0)
}

/// Interpolate between [sustained, transient] based on crest factor.
fn adaptive_param(range: [f32; 2], crest: f32) -> f32 {
    range[0] + (range[1] - range[0]) * crest
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

                // ============================================================
                // Adaptive dynamics from crest factor
                // ============================================================
                let crest = compute_crest(&samples);
                let bass_attack = adaptive_param(BASS_ATTACK_RANGE, crest);
                let bass_release = adaptive_param(BASS_RELEASE_RANGE, crest);
                let mid_attack = adaptive_param(MID_ATTACK_RANGE, crest);
                let mid_release = adaptive_param(MID_RELEASE_RANGE, crest);
                let high_attack = adaptive_param(HIGH_ATTACK_RANGE, crest);
                let high_release = adaptive_param(HIGH_RELEASE_RANGE, crest);
                let amp_attack = adaptive_param(AMP_ATTACK_RANGE, crest);
                let amp_release = adaptive_param(AMP_RELEASE_RANGE, crest);

                // Noise gate (use adaptive release for smooth decay to zero)
                if raw_amp < NOISE_FLOOR {
                    let mut data = shared.lock().unwrap();
                    data.amplitude = smooth_band(data.amplitude, 0.0, amp_attack, amp_release);
                    data.bass = smooth_band(data.bass, 0.0, bass_attack, bass_release);
                    data.mid = smooth_band(data.mid, 0.0, mid_attack, mid_release);
                    data.high = smooth_band(data.high, 0.0, high_attack, high_release);
                    data.sub_bass = smooth_band(data.sub_bass, 0.0, bass_attack, bass_release * 0.5);
                    data.presence = smooth_band(data.presence, 0.0, high_attack, high_release);
                    data.onset = smooth_band(data.onset, 0.0, ONSET_ATTACK, ONSET_RELEASE);
                    data.left.amplitude = smooth_band(data.left.amplitude, 0.0, amp_attack, amp_release);
                    data.right.amplitude = smooth_band(data.right.amplitude, 0.0, amp_attack, amp_release);
                    data.beat *= BEAT_DECAY;
                    data.crest = smooth_band(data.crest, 0.0, 0.3, 0.05);
                    continue;
                }

                let half = FFT_SIZE / 2;

                // ============================================================
                // Soft AGC + adaptive smoothing
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

                // Store crest + compute centroid
                data.crest = smooth_band(data.crest, crest, 0.5, 0.1);

                // Per-band smoothing with adaptive attack/release
                data.amplitude = smooth_band(data.amplitude, norm_amp, amp_attack, amp_release);
                data.bass = smooth_band(data.bass, norm_bass, bass_attack, bass_release);
                data.mid = smooth_band(data.mid, norm_mid, mid_attack, mid_release);
                data.high = smooth_band(data.high, norm_high, high_attack, high_release);

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
                data.sub_bass = smooth_band(data.sub_bass, norm_sub, bass_attack, bass_release * 0.5);
                data.presence = smooth_band(data.presence, norm_presence, high_attack, high_release);

                // Spectral centroid: where is the "center of mass" of the frequency content?
                let centroid = compute_centroid(&combined_spectrum, bin_hz, 16000.0);
                data.centroid = smooth_band(data.centroid, centroid, 0.3, 0.08);

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
                data.left.amplitude = smooth_band(data.left.amplitude, norm_l_amp, amp_attack, amp_release);
                data.right.amplitude = smooth_band(data.right.amplitude, norm_r_amp, amp_attack, amp_release);
                data.left.bass = smooth_band(data.left.bass, soft_normalize(raw_l.bass, data.peak_bass), bass_attack, bass_release);
                data.right.bass = smooth_band(data.right.bass, soft_normalize(raw_r.bass, data.peak_bass), bass_attack, bass_release);
                data.left.mid = smooth_band(data.left.mid, soft_normalize(raw_l.mid, data.peak_mid), mid_attack, mid_release);
                data.right.mid = smooth_band(data.right.mid, soft_normalize(raw_r.mid, data.peak_mid), mid_attack, mid_release);
                data.left.high = smooth_band(data.left.high, soft_normalize(raw_l.high, data.peak_high), high_attack, high_release);
                data.right.high = smooth_band(data.right.high, soft_normalize(raw_r.high, data.peak_high), high_attack, high_release);

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

    // Tighter bands: bass focuses on kick/bass guitar, not low-end mud
    let bin_hz = sample_rate / n as f32;
    let bass_end = (150.0 / bin_hz) as usize;   // was 250Hz — now 60-150Hz (kick + bass fundamental)
    let mid_end = (4000.0 / bin_hz) as usize;
    let high_end = (20000.0 / bin_hz).min(half as f32) as usize;

    let bass_start = (60.0 / bin_hz) as usize;  // start at 60Hz, skip sub-bass

    let band_energy = |from: usize, to: usize| -> f32 {
        if to <= from { return 0.0; }
        spectrum[from..to.min(half)].iter().map(|s| s * s).sum::<f32>() / (to - from) as f32
    };

    ChannelAnalysis {
        amplitude: rms,
        bass: band_energy(bass_start, bass_end).sqrt(),
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
        // Bass should decay slower than highs (at any crest level)
        let crest = 0.5; // mid-range crest
        let bass_r = adaptive_param(BASS_RELEASE_RANGE, crest);
        let high_r = adaptive_param(HIGH_RELEASE_RANGE, crest);
        let bass = smooth_band(1.0, 0.0, 0.5, bass_r);
        let high = smooth_band(1.0, 0.0, 0.5, high_r);
        assert!(bass > high, "bass should decay slower: bass={} high={}", bass, high);
    }

    #[test]
    fn adaptive_params_range() {
        // Crest 0 (sustained) → slow end, crest 1 (transient) → fast end
        let slow = adaptive_param(BASS_ATTACK_RANGE, 0.0);
        let fast = adaptive_param(BASS_ATTACK_RANGE, 1.0);
        assert_eq!(slow, BASS_ATTACK_RANGE[0]);
        assert_eq!(fast, BASS_ATTACK_RANGE[1]);
        assert!(fast > slow, "transient attack should be faster");
    }

    #[test]
    fn crest_factor_ranges() {
        // Silence → 0
        let silence: Vec<(f32, f32)> = vec![(0.0, 0.0); 1024];
        assert_eq!(compute_crest(&silence), 0.0);
        // Pure sine → low crest (~1.4, maps to ~0.1)
        let sine: Vec<(f32, f32)> = (0..1024)
            .map(|i| {
                let s = (2.0 * std::f32::consts::PI * i as f32 / 1024.0).sin();
                (s, s)
            })
            .collect();
        let c = compute_crest(&sine);
        assert!(c < 0.3, "sine crest should be low: {}", c);
        // Impulse → high crest
        let mut impulse: Vec<(f32, f32)> = vec![(0.0, 0.0); 1024];
        impulse[0] = (1.0, 1.0);
        let c = compute_crest(&impulse);
        assert!(c > 0.8, "impulse crest should be high: {}", c);
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
