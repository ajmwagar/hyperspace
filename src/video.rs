use anyhow::Result;
use std::path::Path;
use std::process::Command;

/// A decoded video overlay — all frames pre-loaded as RGBA byte arrays.
/// Playback advances with the clock regardless of visibility.
pub struct VideoOverlay {
    pub frames: Vec<VideoFrame>,
    pub fps: f32,
    pub width: u32,
    pub height: u32,
    pub visible: bool,
}

pub struct VideoFrame {
    pub rgba: Vec<u8>,
}

impl VideoOverlay {
    /// Load a video file (MP4, GIF, etc.) via ffmpeg.
    /// Downscales to max_width while preserving aspect ratio.
    pub fn load(path: &str, max_width: u32) -> Result<Self> {
        let ext = Path::new(path)
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_lowercase();

        // Use ffmpeg for all video formats (MP4, GIF, WebM, etc.)
        Self::load_ffmpeg(path, max_width)
    }

    fn load_ffmpeg(path: &str, max_width: u32) -> Result<Self> {
        // First get dimensions and fps
        let probe = Command::new("ffprobe")
            .args(["-v", "quiet", "-print_format", "json", "-show_streams", path])
            .output()?;

        if !probe.status.success() {
            anyhow::bail!("ffprobe failed on {}", path);
        }

        let probe_json: serde_json::Value = serde_json::from_slice(&probe.stdout)
            .map_err(|e| anyhow::anyhow!("ffprobe parse error: {}", e))?;

        let stream = &probe_json["streams"][0];
        let src_w = stream["width"].as_u64().unwrap_or(512) as u32;
        let src_h = stream["height"].as_u64().unwrap_or(512) as u32;
        let fps_str = stream["r_frame_rate"].as_str().unwrap_or("30/1");
        let fps = parse_fps(fps_str);
        let num_frames = stream["nb_frames"]
            .as_str()
            .and_then(|s| s.parse::<u32>().ok())
            .unwrap_or(100);

        // Calculate output dimensions (preserve aspect ratio)
        let scale = (max_width as f32 / src_w as f32).min(1.0);
        let out_w = ((src_w as f32 * scale) as u32) & !1; // even width
        let out_h = ((src_h as f32 * scale) as u32) & !1; // even height

        log::info!(
            "video overlay: {} ({}x{} @ {}fps, {} frames → {}x{})",
            path, src_w, src_h, fps, num_frames, out_w, out_h
        );

        // Decode all frames as raw RGBA via ffmpeg
        let output = Command::new("ffmpeg")
            .args([
                "-i", path,
                "-vf", &format!("scale={}:{},format=rgba", out_w, out_h),
                "-f", "rawvideo",
                "-pix_fmt", "rgba",
                "-v", "quiet",
                "-",
            ])
            .output()?;

        if !output.status.success() {
            anyhow::bail!("ffmpeg decode failed for {}", path);
        }

        let frame_size = (out_w * out_h * 4) as usize;
        let total_bytes = output.stdout.len();
        let frame_count = total_bytes / frame_size;

        log::info!("  decoded {} frames ({:.1} MB)", frame_count, total_bytes as f64 / 1e6);

        let mut frames = Vec::with_capacity(frame_count);
        for i in 0..frame_count {
            let start = i * frame_size;
            let end = start + frame_size;
            frames.push(VideoFrame {
                rgba: output.stdout[start..end].to_vec(),
            });
        }

        Ok(Self {
            frames,
            fps,
            width: out_w,
            height: out_h,
            visible: false,
        })
    }

    /// Get the current frame index based on wall clock time (always advancing, loops).
    pub fn frame_at(&self, time: f32) -> usize {
        if self.frames.is_empty() {
            return 0;
        }
        let idx = (time * self.fps) as usize;
        idx % self.frames.len()
    }

    pub fn toggle(&mut self) {
        self.visible = !self.visible;
        log::info!("video overlay: {}", if self.visible { "ON" } else { "OFF" });
    }
}

fn parse_fps(s: &str) -> f32 {
    if let Some((num, den)) = s.split_once('/') {
        let n: f32 = num.parse().unwrap_or(30.0);
        let d: f32 = den.parse().unwrap_or(1.0);
        if d > 0.0 { n / d } else { 30.0 }
    } else {
        s.parse().unwrap_or(30.0)
    }
}
