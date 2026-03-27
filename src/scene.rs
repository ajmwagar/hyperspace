use anyhow::Result;
use serde::Deserialize;
use std::collections::HashMap;
use std::path::Path;

#[derive(Debug, Deserialize, Default)]
pub struct SceneConfig {
    #[serde(default)]
    pub audio: AudioConfig,
    /// Clip definitions for the visual sample board.
    /// Triggered by keyboard (key field) or CV (cv_channel + cv_threshold).
    #[serde(default)]
    pub clips: Vec<ClipConfig>,
    #[serde(flatten)]
    pub outputs: HashMap<String, OutputConfig>,
}

/// A triggerable visual clip — like a pad on an MPC but for visuals.
#[derive(Debug, Deserialize, Clone)]
pub struct ClipConfig {
    /// Display name
    pub name: String,
    /// Main shader path
    pub shader: String,
    /// Post-processing chain
    #[serde(default)]
    pub post: Vec<String>,
    /// Keyboard key to trigger (e.g. "q", "w", "e", "a", "s", "d")
    pub key: Option<String>,
    /// CV channel (0-7) that triggers this clip
    pub cv_channel: Option<usize>,
    /// CV threshold (0.0-1.0) — clip triggers when CV exceeds this. Default: 0.5
    #[serde(default = "default_cv_threshold")]
    pub cv_threshold: f32,
}

fn default_cv_threshold() -> f32 {
    0.5
}

#[derive(Debug, Deserialize, Default, Clone)]
pub struct AudioConfig {
    /// Audio device name substring to match (e.g. "Scarlett"). Default: system default.
    pub device: Option<String>,
    /// Comma-separated channel pair, e.g. "4,5" for loopback. Default: auto-detect.
    pub channels: Option<String>,
    /// Now playing text, e.g. "Artist - Title". Updated dynamically via Lua API.
    pub now_playing: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct OutputConfig {
    pub shader: String,
    #[serde(default)]
    pub symmetric: bool,
    /// Post-processing shader chain (applied in order after main shader)
    #[serde(default)]
    pub post: Vec<String>,
    /// Overlay image path (PNG with alpha, composited on top)
    pub overlay: Option<String>,
    /// Video sources for the video_player shader (crossfaded sequence)
    #[serde(default)]
    pub video_sources: Vec<String>,
    /// Video overlay path (MP4/GIF, loops continuously, toggled by key/CV)
    pub video_overlay: Option<String>,
    /// Key to toggle video overlay visibility (e.g. "t")
    pub video_overlay_key: Option<String>,
    /// CV channel to gate video overlay (high = visible)
    pub video_overlay_cv: Option<usize>,
}

/// Display layout mode.
#[derive(Debug, Clone, Copy)]
pub enum LayoutMode {
    /// Center + Sides (3 screens, 2 feeds)
    ThreeOutput,
    /// Configurable grid of independent viewports (cols × rows)
    Grid { cols: u32, rows: u32 },
}

impl LayoutMode {
    /// Parse layout from CLI arg: "9" (legacy 3x3), "3x4", "4x3", etc.
    pub fn parse(s: &str) -> Option<Self> {
        if let Some((c, r)) = s.split_once('x') {
            let cols = c.trim().parse().ok()?;
            let rows = r.trim().parse().ok()?;
            Some(Self::Grid { cols, rows })
        } else {
            // Legacy: single number = NxN or known alias
            let n: u32 = s.parse().ok()?;
            match n {
                9 => Some(Self::Grid { cols: 3, rows: 3 }),
                12 => Some(Self::Grid { cols: 4, rows: 3 }),
                _ => {
                    let side = (n as f32).sqrt().ceil() as u32;
                    Some(Self::Grid { cols: side, rows: side })
                }
            }
        }
    }
}

/// A resolved output viewport.
#[derive(Debug, Clone)]
pub struct Viewport {
    pub name: String,
    pub shader_path: String,
    pub symmetric: bool,
    /// Post-processing shader paths (applied in order)
    pub post: Vec<String>,
    /// Overlay image path (PNG with alpha)
    pub overlay: Option<String>,
    /// Video sources for video_player shader
    pub video_sources: Vec<String>,
    /// Video overlay config
    pub video_overlay: Option<String>,
    pub video_overlay_key: Option<String>,
    pub video_overlay_cv: Option<usize>,
    /// Normalized rect within the framebuffer: (x, y, w, h) in 0..1
    pub rect: [f32; 4],
}

impl SceneConfig {
    pub fn load(path: &Path) -> Result<Self> {
        let text = std::fs::read_to_string(path)?;
        Self::from_str(&text)
    }

    pub fn from_str(s: &str) -> Result<Self> {
        let config: SceneConfig = toml::from_str(s)?;
        Ok(config)
    }

    /// Resolve viewports based on config and layout mode.
    pub fn resolve_viewports(&self, mode: LayoutMode) -> Vec<Viewport> {
        match mode {
            LayoutMode::ThreeOutput => self.resolve_three_output(),
            LayoutMode::Grid { cols, rows } => self.resolve_grid(cols, rows),
        }
    }

    fn resolve_three_output(&self) -> Vec<Viewport> {
        let mut viewports = Vec::new();

        let has_center = self.outputs.contains_key("center");
        let has_sides = self.outputs.contains_key("sides");

        if let Some(center) = self.outputs.get("center") {
            // If center is the only viewport, go fullscreen
            let rect = if has_sides { [0.0, 0.0, 0.5, 1.0] } else { [0.0, 0.0, 1.0, 1.0] };
            viewports.push(Viewport {
                name: "center".into(),
                shader_path: center.shader.clone(),
                symmetric: center.symmetric,
                post: center.post.clone(),
                overlay: center.overlay.clone(),
                video_sources: center.video_sources.clone(),
                video_overlay: center.video_overlay.clone(),
                video_overlay_key: center.video_overlay_key.clone(),
                video_overlay_cv: center.video_overlay_cv,
                rect,
            });
        }

        if let Some(sides) = self.outputs.get("sides") {
            let rect = if has_center { [0.5, 0.0, 0.5, 1.0] } else { [0.0, 0.0, 1.0, 1.0] };
            viewports.push(Viewport {
                name: "sides".into(),
                shader_path: sides.shader.clone(),
                symmetric: sides.symmetric,
                post: sides.post.clone(),
                overlay: sides.overlay.clone(),
                video_sources: sides.video_sources.clone(),
                video_overlay: sides.video_overlay.clone(),
                video_overlay_key: sides.video_overlay_key.clone(),
                video_overlay_cv: sides.video_overlay_cv,
                rect,
            });
        }

        viewports
    }

    fn resolve_grid(&self, cols: u32, rows: u32) -> Vec<Viewport> {
        let mut viewports = Vec::new();
        let cell_w = 1.0 / cols as f32;
        let cell_h = 1.0 / rows as f32;
        let total = cols * rows;

        let grid_names: Vec<String> = (0..total).map(|i| format!("grid_{}", i)).collect();

        for (idx, name) in grid_names.iter().enumerate() {
            let col = idx as u32 % cols;
            let row = idx as u32 / cols;

            if let Some(output) = self.outputs.get(name) {
                viewports.push(Viewport {
                    name: name.clone(),
                    shader_path: output.shader.clone(),
                    symmetric: output.symmetric,
                    post: output.post.clone(),
                    overlay: output.overlay.clone(),
                    video_sources: output.video_sources.clone(),
                    video_overlay: output.video_overlay.clone(),
                    video_overlay_key: output.video_overlay_key.clone(),
                    video_overlay_cv: output.video_overlay_cv,
                    rect: [
                        col as f32 * cell_w,
                        row as f32 * cell_h,
                        cell_w,
                        cell_h,
                    ],
                });
            }
        }

        // Fallback: named outputs fill cells left-to-right
        if viewports.is_empty() {
            for (idx, (name, output)) in self.outputs.iter().enumerate() {
                let col = idx as u32 % cols;
                let row = idx as u32 / cols;
                viewports.push(Viewport {
                    name: name.clone(),
                    shader_path: output.shader.clone(),
                    symmetric: output.symmetric,
                    post: output.post.clone(),
                    overlay: output.overlay.clone(),
                    video_sources: output.video_sources.clone(),
                    video_overlay: output.video_overlay.clone(),
                    video_overlay_key: output.video_overlay_key.clone(),
                    video_overlay_cv: output.video_overlay_cv,
                    rect: [
                        col as f32 * cell_w,
                        row as f32 * cell_h,
                        cell_w,
                        cell_h,
                    ],
                });
            }
        }

        viewports
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DEFAULT_SCENE: &str = r#"
[center]
shader = "shaders/hyperspace_tunnel.wgsl"

[sides]
shader = "shaders/engine_gauges.wgsl"
symmetric = true
"#;

    #[test]
    fn parse_default_scene() {
        let config = SceneConfig::from_str(DEFAULT_SCENE).unwrap();
        assert_eq!(config.outputs.len(), 2);

        let center = &config.outputs["center"];
        assert_eq!(center.shader, "shaders/hyperspace_tunnel.wgsl");
        assert!(!center.symmetric);

        let sides = &config.outputs["sides"];
        assert_eq!(sides.shader, "shaders/engine_gauges.wgsl");
        assert!(sides.symmetric);
    }

    #[test]
    fn parse_audio_config() {
        let toml = r#"
[audio]
device = "Scarlett"
channels = "4,5"

[center]
shader = "shaders/test.wgsl"
"#;
        let config = SceneConfig::from_str(toml).unwrap();
        assert_eq!(config.audio.device.as_deref(), Some("Scarlett"));
        assert_eq!(config.audio.channels.as_deref(), Some("4,5"));
        assert!(config.outputs.contains_key("center"));
    }

    #[test]
    fn audio_config_defaults_when_missing() {
        let config = SceneConfig::from_str(DEFAULT_SCENE).unwrap();
        assert!(config.audio.device.is_none());
        assert!(config.audio.channels.is_none());
    }

    #[test]
    fn three_output_viewports() {
        let config = SceneConfig::from_str(DEFAULT_SCENE).unwrap();
        let vps = config.resolve_viewports(LayoutMode::ThreeOutput);

        assert_eq!(vps.len(), 2);

        let center = vps.iter().find(|v| v.name == "center").unwrap();
        assert_eq!(center.rect, [0.0, 0.0, 0.5, 1.0]);

        let sides = vps.iter().find(|v| v.name == "sides").unwrap();
        assert_eq!(sides.rect, [0.5, 0.0, 0.5, 1.0]);
        assert!(sides.symmetric);
    }

    #[test]
    fn nine_output_fallback_to_named() {
        let config = SceneConfig::from_str(DEFAULT_SCENE).unwrap();
        let vps = config.resolve_viewports(LayoutMode::Grid { cols: 3, rows: 3 });

        assert_eq!(vps.len(), 2);
        for vp in &vps {
            assert!((vp.rect[2] - 1.0 / 3.0).abs() < 1e-6);
            assert!((vp.rect[3] - 1.0 / 3.0).abs() < 1e-6);
        }
    }

    #[test]
    fn nine_output_grid_keys() {
        let toml = r#"
[grid_0]
shader = "shaders/a.wgsl"

[grid_4]
shader = "shaders/b.wgsl"

[grid_8]
shader = "shaders/c.wgsl"
"#;
        let config = SceneConfig::from_str(toml).unwrap();
        let vps = config.resolve_viewports(LayoutMode::Grid { cols: 3, rows: 3 });

        assert_eq!(vps.len(), 3);

        let g0 = vps.iter().find(|v| v.name == "grid_0").unwrap();
        assert!((g0.rect[0]).abs() < 1e-6);
        assert!((g0.rect[1]).abs() < 1e-6);

        let g4 = vps.iter().find(|v| v.name == "grid_4").unwrap();
        assert!((g4.rect[0] - 1.0 / 3.0).abs() < 1e-6);
        assert!((g4.rect[1] - 1.0 / 3.0).abs() < 1e-6);

        let g8 = vps.iter().find(|v| v.name == "grid_8").unwrap();
        assert!((g8.rect[0] - 2.0 / 3.0).abs() < 1e-6);
        assert!((g8.rect[1] - 2.0 / 3.0).abs() < 1e-6);
    }

    #[test]
    fn symmetric_defaults_false() {
        let toml = r#"
[center]
shader = "shaders/test.wgsl"
"#;
        let config = SceneConfig::from_str(toml).unwrap();
        assert!(!config.outputs["center"].symmetric);
    }

    #[test]
    fn load_scene_file() {
        let config = SceneConfig::load(Path::new("scenes/default.toml")).unwrap();
        assert!(config.outputs.contains_key("center"));
        assert!(config.outputs.contains_key("sides"));
    }

    #[test]
    fn parse_post_processing_chain() {
        let toml = r#"
[center]
shader = "shaders/oscilloscope.wgsl"
post = ["shaders/post/flow_spiral.wgsl", "shaders/post/colormap_neon.wgsl"]
"#;
        let config = SceneConfig::from_str(toml).unwrap();
        let center = &config.outputs["center"];
        assert_eq!(center.post.len(), 2);
        assert_eq!(center.post[0], "shaders/post/flow_spiral.wgsl");
        assert_eq!(center.post[1], "shaders/post/colormap_neon.wgsl");
    }

    #[test]
    fn post_defaults_empty() {
        let config = SceneConfig::from_str(DEFAULT_SCENE).unwrap();
        assert!(config.outputs["center"].post.is_empty());
    }

    #[test]
    fn post_carried_to_viewports() {
        let toml = r#"
[center]
shader = "shaders/test.wgsl"
post = ["shaders/post/flow_spiral.wgsl"]
"#;
        let config = SceneConfig::from_str(toml).unwrap();
        let vps = config.resolve_viewports(LayoutMode::ThreeOutput);
        assert_eq!(vps[0].post.len(), 1);
    }

    #[test]
    fn layout_mode_parse_grid() {
        match LayoutMode::parse("4x3") {
            Some(LayoutMode::Grid { cols: 4, rows: 3 }) => {}
            other => panic!("expected Grid 4x3, got {:?}", other),
        }
        match LayoutMode::parse("3x3") {
            Some(LayoutMode::Grid { cols: 3, rows: 3 }) => {}
            other => panic!("expected Grid 3x3, got {:?}", other),
        }
    }

    #[test]
    fn layout_mode_parse_legacy() {
        match LayoutMode::parse("9") {
            Some(LayoutMode::Grid { cols: 3, rows: 3 }) => {}
            other => panic!("expected Grid 3x3 from '9', got {:?}", other),
        }
        match LayoutMode::parse("12") {
            Some(LayoutMode::Grid { cols: 4, rows: 3 }) => {}
            other => panic!("expected Grid 4x3 from '12', got {:?}", other),
        }
    }

    #[test]
    fn layout_mode_parse_invalid() {
        assert!(LayoutMode::parse("abc").is_none());
    }

    #[test]
    fn grid_4x3_produces_12_cells() {
        let toml = (0..12)
            .map(|i| format!("[grid_{}]\nshader = \"shaders/test.wgsl\"\n", i))
            .collect::<String>();
        let config = SceneConfig::from_str(&toml).unwrap();
        let vps = config.resolve_viewports(LayoutMode::Grid { cols: 4, rows: 3 });
        assert_eq!(vps.len(), 12);
        // Check cell sizes
        for vp in &vps {
            assert!((vp.rect[2] - 0.25).abs() < 1e-6); // 1/4 width
            assert!((vp.rect[3] - 1.0/3.0).abs() < 1e-6); // 1/3 height
        }
    }
}
