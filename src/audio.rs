use anyhow::Result;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use rustfft::{num_complex::Complex, FftPlanner};
use std::sync::{Arc, Mutex};

const FFT_SIZE: usize = 1024;
const BEAT_THRESHOLD: f32 = 1.4;
const BEAT_DECAY: f32 = 0.95;

/// Raw audio analysis data shared between audio thread and render thread.
pub struct AudioData {
    pub amplitude: f32,
    pub beat: f32,
    pub bass: f32,
    pub mid: f32,
    pub high: f32,
    pub spectrum: Vec<f32>,
    // Internal state for beat detection
    energy_avg: f32,
}

impl Default for AudioData {
    fn default() -> Self {
        Self {
            amplitude: 0.0,
            beat: 0.0,
            bass: 0.0,
            mid: 0.0,
            high: 0.0,
            spectrum: vec![0.0; FFT_SIZE / 2],
            energy_avg: 0.0,
        }
    }
}

pub type SharedAudioData = Arc<Mutex<AudioData>>;

pub fn new_shared() -> SharedAudioData {
    Arc::new(Mutex::new(AudioData::default()))
}

/// Start capturing audio from the default input device.
/// Returns the stream handle (must be kept alive).
pub fn start_capture(shared: SharedAudioData) -> Result<cpal::Stream> {
    let host = cpal::default_host();

    let device = host
        .default_input_device()
        .ok_or_else(|| anyhow::anyhow!("no audio input device available"))?;

    log::info!("audio input device: {}", device.name().unwrap_or_default());

    let config = device.default_input_config()?;
    let sample_rate = config.sample_rate().0 as f32;
    let channels = config.channels() as usize;

    log::info!(
        "audio config: {}Hz, {} channels, {:?}",
        sample_rate,
        channels,
        config.sample_format()
    );

    let ring = Arc::new(Mutex::new(Vec::<f32>::with_capacity(FFT_SIZE * 2)));

    let ring_writer = ring.clone();
    let stream = device.build_input_stream(
        &config.into(),
        move |data: &[f32], _: &cpal::InputCallbackInfo| {
            let mut buf = ring_writer.lock().unwrap();
            // Mix to mono and push samples
            for frame in data.chunks(channels) {
                let sample: f32 = frame.iter().sum::<f32>() / channels as f32;
                buf.push(sample);
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
            let mut window = vec![0.0f32; FFT_SIZE];
            let mut fft_buf = vec![Complex::default(); FFT_SIZE];

            loop {
                std::thread::sleep(std::time::Duration::from_millis(8)); // ~120Hz analysis

                // Drain samples from ring buffer
                let samples: Vec<f32> = {
                    let mut buf = ring.lock().unwrap();
                    if buf.len() < FFT_SIZE {
                        continue;
                    }
                    // Take the most recent FFT_SIZE samples
                    let start = buf.len().saturating_sub(FFT_SIZE);
                    let out = buf[start..].to_vec();
                    buf.clear();
                    out
                };

                // Apply Hann window
                for (i, s) in samples.iter().enumerate().take(FFT_SIZE) {
                    let w =
                        0.5 * (1.0 - (2.0 * std::f32::consts::PI * i as f32 / FFT_SIZE as f32).cos());
                    window[i] = s * w;
                }

                // Compute amplitude (RMS)
                let rms = (window.iter().map(|s| s * s).sum::<f32>() / FFT_SIZE as f32).sqrt();

                // FFT
                for (i, w) in window.iter().enumerate() {
                    fft_buf[i] = Complex::new(*w, 0.0);
                }
                fft.process_with_scratch(&mut fft_buf, &mut scratch);

                // Magnitude spectrum (first half)
                let half = FFT_SIZE / 2;
                let mut spectrum = Vec::with_capacity(half);
                for i in 0..half {
                    let mag = fft_buf[i].norm() / FFT_SIZE as f32;
                    spectrum.push(mag);
                }

                // Band energies (approximate bin ranges for common sample rates)
                // bass: 20-250Hz, mid: 250-4000Hz, high: 4000-20000Hz
                let bin_hz = sample_rate / FFT_SIZE as f32;
                let bass_end = (250.0 / bin_hz) as usize;
                let mid_end = (4000.0 / bin_hz) as usize;
                let high_end = (20000.0 / bin_hz).min(half as f32) as usize;

                let band_energy = |from: usize, to: usize| -> f32 {
                    if to <= from {
                        return 0.0;
                    }
                    spectrum[from..to.min(half)]
                        .iter()
                        .map(|s| s * s)
                        .sum::<f32>()
                        / (to - from) as f32
                };

                let bass = band_energy(1, bass_end).sqrt();
                let mid = band_energy(bass_end, mid_end).sqrt();
                let high = band_energy(mid_end, high_end).sqrt();

                // Update shared data
                let mut data = shared.lock().unwrap();
                data.amplitude = rms;
                data.bass = bass;
                data.mid = mid;
                data.high = high;
                data.spectrum.copy_from_slice(&spectrum);

                // Simple beat detection: energy spike relative to running average
                let energy = bass * 2.0 + mid; // weight bass more
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
        // RMS of a sine wave is 1/sqrt(2) ≈ 0.7071
        assert!((r - std::f32::consts::FRAC_1_SQRT_2).abs() < 0.01);
    }

    #[test]
    fn hann_window_zeros_edges() {
        let mut buf = vec![1.0; 64];
        hann_window(&mut buf);
        // Hann window should be ~0 at edges
        assert!(buf[0].abs() < 1e-6);
        // Peak near center
        assert!(buf[32] > 0.9);
    }

    #[test]
    fn fft_produces_spectrum() {
        use rustfft::{num_complex::Complex, FftPlanner};

        let mut planner = FftPlanner::<f32>::new();
        let fft = planner.plan_fft_forward(FFT_SIZE);

        // Generate a 440Hz sine at 44100Hz sample rate
        let sample_rate = 44100.0f32;
        let freq = 440.0;
        let mut buf: Vec<Complex<f32>> = (0..FFT_SIZE)
            .map(|i| {
                let t = i as f32 / sample_rate;
                Complex::new((2.0 * std::f32::consts::PI * freq * t).sin(), 0.0)
            })
            .collect();

        fft.process(&mut buf);

        // Find peak bin
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

        // Should be within one bin of 440Hz
        assert!(
            (peak_freq - freq).abs() < bin_hz * 1.5,
            "peak at {}Hz, expected ~{}Hz",
            peak_freq,
            freq
        );
    }
}
