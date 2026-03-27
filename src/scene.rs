use anyhow::Result;
use serde::Deserialize;
use std::collections::HashMap;
use std::path::Path;

#[derive(Debug, Deserialize)]
pub struct SceneConfig {
    #[serde(flatten)]
    pub outputs: HashMap<String, OutputConfig>,
}

#[derive(Debug, Deserialize)]
pub struct OutputConfig {
    pub shader: String,
    #[serde(default)]
    pub symmetric: bool,
}

/// Display layout mode.
#[derive(Debug, Clone, Copy)]
pub enum LayoutMode {
    /// Center + Sides (3 screens, 2 feeds)
    ThreeOutput,
    /// 3×3 grid of independent viewports
    NineOutput,
}

/// A resolved output viewport.
#[derive(Debug, Clone)]
pub struct Viewport {
    pub name: String,
    pub shader_path: String,
    pub symmetric: bool,
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
            LayoutMode::NineOutput => self.resolve_nine_output(),
        }
    }

    fn resolve_three_output(&self) -> Vec<Viewport> {
        let mut viewports = Vec::new();

        if let Some(center) = self.outputs.get("center") {
            viewports.push(Viewport {
                name: "center".into(),
                shader_path: center.shader.clone(),
                symmetric: center.symmetric,
                rect: [0.0, 0.0, 0.5, 1.0],
            });
        }

        if let Some(sides) = self.outputs.get("sides") {
            viewports.push(Viewport {
                name: "sides".into(),
                shader_path: sides.shader.clone(),
                symmetric: sides.symmetric,
                rect: [0.5, 0.0, 0.5, 1.0],
            });
        }

        viewports
    }

    fn resolve_nine_output(&self) -> Vec<Viewport> {
        let mut viewports = Vec::new();
        let cell_w = 1.0 / 3.0;
        let cell_h = 1.0 / 3.0;

        // Use numbered grid positions or named outputs
        let grid_names: Vec<String> = (0..9).map(|i| format!("grid_{}", i)).collect();

        for (idx, name) in grid_names.iter().enumerate() {
            let col = idx % 3;
            let row = idx / 3;

            if let Some(output) = self.outputs.get(name) {
                viewports.push(Viewport {
                    name: name.clone(),
                    shader_path: output.shader.clone(),
                    symmetric: output.symmetric,
                    rect: [
                        col as f32 * cell_w,
                        row as f32 * cell_h,
                        cell_w,
                        cell_h,
                    ],
                });
            }
        }

        // Also support named outputs (center, sides, etc.) falling back to first cells
        if viewports.is_empty() {
            for (idx, (name, output)) in self.outputs.iter().enumerate() {
                let col = idx % 3;
                let row = idx / 3;
                viewports.push(Viewport {
                    name: name.clone(),
                    shader_path: output.shader.clone(),
                    symmetric: output.symmetric,
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
        // When no grid_N keys exist, named outputs fill cells left-to-right
        let config = SceneConfig::from_str(DEFAULT_SCENE).unwrap();
        let vps = config.resolve_viewports(LayoutMode::NineOutput);

        assert_eq!(vps.len(), 2);
        for vp in &vps {
            // Each cell should be 1/3 × 1/3
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
        let vps = config.resolve_viewports(LayoutMode::NineOutput);

        assert_eq!(vps.len(), 3);

        let g0 = vps.iter().find(|v| v.name == "grid_0").unwrap();
        assert!((g0.rect[0]).abs() < 1e-6); // col 0
        assert!((g0.rect[1]).abs() < 1e-6); // row 0

        let g4 = vps.iter().find(|v| v.name == "grid_4").unwrap();
        assert!((g4.rect[0] - 1.0 / 3.0).abs() < 1e-6); // col 1
        assert!((g4.rect[1] - 1.0 / 3.0).abs() < 1e-6); // row 1

        let g8 = vps.iter().find(|v| v.name == "grid_8").unwrap();
        assert!((g8.rect[0] - 2.0 / 3.0).abs() < 1e-6); // col 2
        assert!((g8.rect[1] - 2.0 / 3.0).abs() < 1e-6); // row 2
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
}
