use crate::cv;
use crate::renderer::Renderer;
use crate::scene::{ClipConfig, Viewport};
use std::collections::HashMap;

/// Visual sample board — maps keyboard keys and CV channels to shader clips.
pub struct ClipBoard {
    clips: Vec<ClipConfig>,
    key_map: HashMap<String, usize>,   // key → clip index
    cv_map: HashMap<usize, usize>,     // cv_channel → clip index
    cv_prev: [bool; 8],                // previous CV gate state (for edge detection)
    active_clip: Option<usize>,
}

impl ClipBoard {
    pub fn new(clips: Vec<ClipConfig>) -> Self {
        let mut key_map = HashMap::new();
        let mut cv_map = HashMap::new();

        for (i, clip) in clips.iter().enumerate() {
            if let Some(ref key) = clip.key {
                key_map.insert(key.to_lowercase(), i);
            }
            if let Some(ch) = clip.cv_channel {
                cv_map.insert(ch, i);
            }
        }

        if !clips.is_empty() {
            log::info!("clip board loaded: {} clips", clips.len());
            for (i, clip) in clips.iter().enumerate() {
                let trigger = match (&clip.key, clip.cv_channel) {
                    (Some(k), Some(cv)) => format!("key={}, cv={}", k, cv),
                    (Some(k), None) => format!("key={}", k),
                    (None, Some(cv)) => format!("cv={}", cv),
                    (None, None) => "no trigger".into(),
                };
                log::info!("  clip[{}] '{}': {} [{}]", i, clip.name, clip.shader, trigger);
            }
        }

        Self {
            clips,
            key_map,
            cv_map,
            cv_prev: [false; 8],
            active_clip: None,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.clips.is_empty()
    }

    /// Handle a keyboard key press. Returns true if a clip was triggered.
    pub fn on_key(&mut self, key: &str, renderer: &mut Renderer, layout: crate::scene::LayoutMode) -> bool {
        let key_lower = key.to_lowercase();
        if let Some(&idx) = self.key_map.get(&key_lower) {
            self.trigger_clip(idx, renderer, layout);
            return true;
        }
        false
    }

    /// Check CV channels for gate triggers (rising edge detection).
    pub fn check_cv(&mut self, cv_data: &cv::CvData, renderer: &mut Renderer, layout: crate::scene::LayoutMode) {
        // Collect triggers first to avoid borrow conflict
        let mut trigger = None;
        for (&channel, &clip_idx) in &self.cv_map {
            if channel >= 8 { continue; }
            let above = cv_data[channel] > self.clips[clip_idx].cv_threshold;
            let was_above = self.cv_prev[channel];
            if above && !was_above {
                trigger = Some(clip_idx);
            }
            self.cv_prev[channel] = above;
        }
        if let Some(idx) = trigger {
            self.trigger_clip(idx, renderer, layout);
        }
    }

    fn trigger_clip(&mut self, idx: usize, renderer: &mut Renderer, layout: crate::scene::LayoutMode) {
        if self.active_clip == Some(idx) {
            return; // already active
        }

        let clip = &self.clips[idx];
        log::info!("triggering clip '{}': {}", clip.name, clip.shader);

        // Replace all viewports with this clip's shader
        renderer.pipelines.clear();

        // Create viewports based on current layout
        let viewports = match layout {
            crate::scene::LayoutMode::ThreeOutput => {
                vec![Viewport {
                    name: clip.name.clone(),
                    shader_path: clip.shader.clone(),
                    symmetric: false,
                    post: clip.post.clone(),
                    overlay: None,
                    video_overlay: None,
                    video_overlay_key: None,
                    video_overlay_cv: None,
                    rect: [0.0, 0.0, 1.0, 1.0], // full screen
                }]
            }
            crate::scene::LayoutMode::Grid { .. } => {
                vec![Viewport {
                    name: clip.name.clone(),
                    shader_path: clip.shader.clone(),
                    symmetric: false,
                    post: clip.post.clone(),
                    overlay: None,
                    video_overlay: None,
                    video_overlay_key: None,
                    video_overlay_cv: None,
                    rect: [0.0, 0.0, 1.0, 1.0], // full screen for clips
                }]
            }
        };

        for vp in viewports {
            if let Err(e) = renderer.load_shader(vp) {
                log::error!("failed to load clip shader: {}", e);
            }
        }

        self.active_clip = Some(idx);
    }
}
