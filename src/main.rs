mod audio;
mod clips;
mod control;
mod cv;
mod renderer;
mod scene;
mod scripting;
mod text;
mod uniforms;
mod video;

use anyhow::Result;
use scene::LayoutMode;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;
use uniforms::Uniforms;
use winit::application::ApplicationHandler;
use winit::event::WindowEvent;
use winit::event_loop::{ActiveEventLoop, EventLoop};
use winit::window::{Window, WindowId};

struct App {
    scene_path: PathBuf,
    layout_mode: LayoutMode,
    // Initialized after resume
    state: Option<AppState>,
    // Audio/CV shared state (created early, before window)
    audio_shared: audio::SharedAudioData,
    cv_shared: cv::SharedCvData,
    // Visual sample board
    clip_board: clips::ClipBoard,
    // Global Lua controller
    controller: control::Controller,
    control_state: control::SharedControlState,
    // Text overlay for now playing
    text_renderer: text::TextRenderer,
    // Keep audio stream alive
    _audio_stream: Option<cpal::Stream>,
}

struct AppState {
    window: Arc<Window>,
    renderer: renderer::Renderer,
    start_time: Instant,
    last_frame: Instant,
    /// Now playing overlay texture (rendered from text, uploaded on change)
    now_playing_texture: Option<NowPlayingOverlay>,
}

struct NowPlayingOverlay {
    texture: wgpu::Texture,
    bind_group: wgpu::BindGroup,
}

impl App {
    fn new(scene_path: PathBuf, layout_mode: LayoutMode) -> Result<Self> {
        let audio_shared = audio::new_shared();
        let cv_shared = cv::new_shared();

        // Load scene config early to get audio settings + clips
        let scene_config = scene::SceneConfig::load(&scene_path).ok();
        let audio_config = scene_config
            .as_ref()
            .map(|c| c.audio.clone())
            .unwrap_or_default();
        let clip_configs = scene_config
            .as_ref()
            .map(|c| c.clips.clone())
            .unwrap_or_default();
        let clip_board = clips::ClipBoard::new(clip_configs);

        // Create Lua controller from config
        let default_config = scene::SceneConfig::from_str("").unwrap_or_default();
        let config_ref = scene_config.as_ref().unwrap_or(&default_config);
        let (controller, control_state) = control::Controller::new(config_ref)?;
        let text_renderer = text::TextRenderer::new(512, 512);

        // Parse channel override from scene config
        let channels = audio_config
            .channels
            .as_deref()
            .and_then(audio::ChannelPair::parse);

        // Start audio capture with device selection from scene config
        let audio_stream = match start_audio(&audio_shared, &audio_config, channels) {
            Ok(stream) => {
                log::info!("audio capture started");
                Some(stream)
            }
            Err(e) => {
                log::warn!("audio capture failed, running without audio: {}", e);
                None
            }
        };

        // Start CV reader
        if let Err(e) = cv::start_cv_reader(cv_shared.clone()) {
            log::warn!("CV reader failed: {}", e);
        }

        Ok(Self {
            scene_path,
            layout_mode,
            state: None,
            audio_shared,
            cv_shared,
            clip_board,
            controller,
            control_state,
            text_renderer,
            _audio_stream: audio_stream,
        })
    }
}

fn start_audio(
    shared: &audio::SharedAudioData,
    config: &scene::AudioConfig,
    channels: Option<audio::ChannelPair>,
) -> Result<cpal::Stream> {
    use cpal::traits::{DeviceTrait, HostTrait};

    let host = cpal::default_host();

    let device = if let Some(ref name_filter) = config.device {
        // Find device matching the name substring
        let devices: Vec<_> = host.input_devices()?.collect();
        let found = devices.into_iter().find(|d| {
            d.name()
                .map(|n| n.to_lowercase().contains(&name_filter.to_lowercase()))
                .unwrap_or(false)
        });
        match found {
            Some(d) => {
                log::info!("matched audio device '{}' for filter '{}'",
                    d.name().unwrap_or_default(), name_filter);
                d
            }
            None => {
                log::warn!("no device matching '{}', falling back to default", name_filter);
                host.default_input_device()
                    .ok_or_else(|| anyhow::anyhow!("no audio input device"))?
            }
        }
    } else {
        host.default_input_device()
            .ok_or_else(|| anyhow::anyhow!("no audio input device"))?
    };

    audio::start_capture_device(shared.clone(), device, channels)
}

impl ApplicationHandler for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.state.is_some() {
            return;
        }

        let window_attrs = Window::default_attributes()
            .with_title("hyperspace")
            .with_maximized(true);

        let window = Arc::new(event_loop.create_window(window_attrs).unwrap());

        let mut renderer = pollster::block_on(renderer::Renderer::new(window.clone())).unwrap();

        // Load scene config
        match scene::SceneConfig::load(&self.scene_path) {
            Ok(config) => {
                let viewports = config.resolve_viewports(self.layout_mode);
                for vp in viewports {
                    log::info!("loading shader for viewport '{}': {}", vp.name, vp.shader_path);
                    if let Err(e) = renderer.load_shader(vp) {
                        log::error!("failed to load shader: {}", e);
                    }
                }
            }
            Err(e) => {
                log::error!("failed to load scene config: {}", e);
            }
        }

        window.request_redraw();

        // Create now playing overlay if set in config
        let np_overlay = {
            let ctrl = self.control_state.lock().unwrap();
            if !ctrl.now_playing_artist.is_empty() || !ctrl.now_playing_title.is_empty() {
                let pixels = self.text_renderer.render_now_playing(
                    &ctrl.now_playing_artist,
                    &ctrl.now_playing_title,
                );
                Some(create_now_playing_overlay(&renderer, &pixels))
            } else {
                None
            }
        };

        self.state = Some(AppState {
            window,
            renderer,
            start_time: Instant::now(),
            last_frame: Instant::now(),
            now_playing_texture: np_overlay,
        });
    }

    fn window_event(
        &mut self,
        event_loop: &ActiveEventLoop,
        _window_id: WindowId,
        event: WindowEvent,
    ) {
        let state = match self.state.as_mut() {
            Some(s) => s,
            None => return,
        };

        match event {
            WindowEvent::CloseRequested => {
                event_loop.exit();
            }
            WindowEvent::Resized(size) => {
                state.renderer.resize(size.width, size.height);
            }
            WindowEvent::KeyboardInput { event, .. } => {
                use winit::keyboard::{KeyCode, PhysicalKey};
                if event.state != winit::event::ElementState::Pressed {
                    // Only handle key down
                } else if event.physical_key == PhysicalKey::Code(KeyCode::Escape) {
                    event_loop.exit();
                } else {
                    // Try clip board first (letter keys for clips)
                    let key_str = match event.physical_key {
                        PhysicalKey::Code(KeyCode::KeyQ) => Some("q"),
                        PhysicalKey::Code(KeyCode::KeyW) => Some("w"),
                        PhysicalKey::Code(KeyCode::KeyE) => Some("e"),
                        PhysicalKey::Code(KeyCode::KeyR) => Some("r"),
                        PhysicalKey::Code(KeyCode::KeyA) => Some("a"),
                        PhysicalKey::Code(KeyCode::KeyS) => Some("s"),
                        PhysicalKey::Code(KeyCode::KeyD) => Some("d"),
                        PhysicalKey::Code(KeyCode::KeyF) => Some("f"),
                        PhysicalKey::Code(KeyCode::KeyZ) => Some("z"),
                        PhysicalKey::Code(KeyCode::KeyX) => Some("x"),
                        PhysicalKey::Code(KeyCode::KeyC) => Some("c"),
                        PhysicalKey::Code(KeyCode::KeyV) => Some("v"),
                        PhysicalKey::Code(KeyCode::KeyT) => Some("t"),
                        PhysicalKey::Code(KeyCode::KeyG) => Some("g"),
                        PhysicalKey::Code(KeyCode::KeyB) => Some("b"),
                        _ => None,
                    };
                    if let Some(key) = key_str {
                        // Pass to Lua controller first
                        self.controller.on_key(key);
                        // Then video overlay toggle
                        state.renderer.toggle_video_by_key(key);
                        // Then clip board
                        if self.clip_board.on_key(key, &mut state.renderer, self.layout_mode) {
                            return;
                        }
                    }

                    // Scene switching: number keys 1-9, 0 load scene files
                    let scene_idx = match event.physical_key {
                        PhysicalKey::Code(KeyCode::Digit1) => Some(0),
                        PhysicalKey::Code(KeyCode::Digit2) => Some(1),
                        PhysicalKey::Code(KeyCode::Digit3) => Some(2),
                        PhysicalKey::Code(KeyCode::Digit4) => Some(3),
                        PhysicalKey::Code(KeyCode::Digit5) => Some(4),
                        PhysicalKey::Code(KeyCode::Digit6) => Some(5),
                        PhysicalKey::Code(KeyCode::Digit7) => Some(6),
                        PhysicalKey::Code(KeyCode::Digit8) => Some(7),
                        PhysicalKey::Code(KeyCode::Digit9) => Some(8),
                        PhysicalKey::Code(KeyCode::Digit0) => Some(9),
                        _ => None,
                    };
                    if let Some(idx) = scene_idx {
                        if let Ok(mut entries) = std::fs::read_dir("scenes") {
                            let mut scenes: Vec<_> = entries
                                .filter_map(|e| e.ok())
                                .filter(|e| e.path().extension().is_some_and(|ext| ext == "toml"))
                                .collect();
                            scenes.sort_by_key(|e| e.file_name());
                            if let Some(entry) = scenes.get(idx) {
                                let path = entry.path();
                                log::info!("switching to scene: {}", path.display());
                                match scene::SceneConfig::load(&path) {
                                    Ok(config) => {
                                        state.renderer.pipelines.clear();
                                        let viewports = config.resolve_viewports(self.layout_mode);
                                        for vp in viewports {
                                            log::info!("  loading viewport '{}': {}", vp.name, vp.shader_path);
                                            if let Err(e) = state.renderer.load_shader(vp) {
                                                log::error!("  failed: {}", e);
                                            }
                                        }
                                    }
                                    Err(e) => log::error!("failed to load scene: {}", e),
                                }
                            }
                        }
                    }
                }
            }
            WindowEvent::RedrawRequested => {
                let now = Instant::now();
                let dt = now.duration_since(state.last_frame).as_secs_f32();
                state.last_frame = now;

                // Gather audio data
                let audio = self.audio_shared.lock().unwrap();

                // Gather CV data
                let cv = *self.cv_shared.lock().unwrap();

                // Pass CV to Lua controller
                for ch in 0..8 {
                    self.controller.on_cv(ch, cv[ch]);
                }

                // Check CV triggers for clip board and video overlays
                if !self.clip_board.is_empty() {
                    self.clip_board.check_cv(&cv, &mut state.renderer, self.layout_mode);
                }
                state.renderer.gate_video_by_cv(&cv);

                // Process controller actions (scene switches, now playing, etc.)
                let ctrl = self.controller.drain();
                if let Some(scene_path) = ctrl.pending_scene {
                    log::info!("[controller] switching scene: {}", scene_path);
                    if let Ok(config) = scene::SceneConfig::load(std::path::Path::new(&scene_path)) {
                        state.renderer.pipelines.clear();
                        for vp in config.resolve_viewports(self.layout_mode) {
                            let _ = state.renderer.load_shader(vp);
                        }
                    }
                }
                for key in &ctrl.video_toggles {
                    state.renderer.toggle_video_by_key(key);
                }

                // Update now playing overlay if text changed
                if ctrl.now_playing_changed {
                    let pixels = self.text_renderer.render_now_playing(
                        &ctrl.now_playing_artist,
                        &ctrl.now_playing_title,
                    );
                    state.now_playing_texture = Some(create_now_playing_overlay(&state.renderer, &pixels));
                    log::info!("now playing: {} - {}", ctrl.now_playing_artist, ctrl.now_playing_title);
                }

                // Beat detection → notify controller
                if audio.beat > 0.7 {
                    self.controller.on_beat();
                }

                // Upload current video frames
                let elapsed = state.start_time.elapsed().as_secs_f32();
                state.renderer.update_video_sequences(elapsed);
                state.renderer.update_video_frames(elapsed);

                let uniforms = Uniforms {
                    time: state.start_time.elapsed().as_secs_f32(),
                    delta_time: dt,
                    resolution: [
                        state.renderer.surface_config.width as f32,
                        state.renderer.surface_config.height as f32,
                    ],
                    amplitude: audio.amplitude,
                    beat: audio.beat,
                    bass: audio.bass,
                    mid: audio.mid,
                    high: audio.high,
                    cv,
                    scene_id: 0,
                    amplitude_l: audio.left.amplitude,
                    amplitude_r: audio.right.amplitude,
                    bass_l: audio.left.bass,
                    bass_r: audio.right.bass,
                    mid_l: audio.left.mid,
                    mid_r: audio.right.mid,
                    high_l: audio.left.high,
                    high_r: audio.right.high,
                    ..Default::default()
                };

                state.renderer.update_uniforms(&uniforms);
                state.renderer.update_scripts(&scripting::ScriptUniforms {
                    time: uniforms.time,
                    delta_time: uniforms.delta_time,
                    amplitude: uniforms.amplitude,
                    beat: uniforms.beat,
                    bass: uniforms.bass,
                    mid: uniforms.mid,
                    high: uniforms.high,
                    amplitude_l: uniforms.amplitude_l,
                    amplitude_r: uniforms.amplitude_r,
                });
                state.renderer.update_audio_buffer(
                    &audio.spectrum,
                    &audio.waveform_l,
                    &audio.waveform_r,
                );

                drop(audio); // release lock before render

                let np_bg = state.now_playing_texture.as_ref().map(|np| &np.bind_group);
                if let Err(e) = state.renderer.render_with_overlay(np_bg) {
                    log::error!("render error: {}", e);
                }

                state.window.request_redraw();
            }
            _ => {}
        }
    }
}

fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    let scene_path = std::env::args()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("scenes/default.toml"));

    let layout_mode = match std::env::args().nth(2).as_deref() {
        Some(s) => LayoutMode::parse(s).unwrap_or(LayoutMode::ThreeOutput),
        None => LayoutMode::ThreeOutput,
    };

    log::info!("hyperspace starting");
    log::info!("scene: {}", scene_path.display());
    log::info!("layout: {:?}", layout_mode);

    let mut app = App::new(scene_path, layout_mode)?;

    let event_loop = EventLoop::new()?;
    event_loop.run_app(&mut app)?;

    Ok(())
}

fn create_now_playing_overlay(renderer: &renderer::Renderer, pixels: &[u8]) -> NowPlayingOverlay {
    use wgpu::util::DeviceExt;
    let w = 512u32;
    let h = 512u32;

    let texture = renderer.device.create_texture(&wgpu::TextureDescriptor {
        label: Some("now_playing"),
        size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rgba8UnormSrgb,
        usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
        view_formats: &[],
    });

    renderer.queue.write_texture(
        texture.as_image_copy(),
        pixels,
        wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(4 * w), rows_per_image: Some(h) },
        wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
    );

    let view = texture.create_view(&Default::default());
    let bind_group = renderer.device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("now_playing_bg"),
        layout: &renderer.blit_bind_group_layout,
        entries: &[
            wgpu::BindGroupEntry {
                binding: 0,
                resource: wgpu::BindingResource::TextureView(&view),
            },
            wgpu::BindGroupEntry {
                binding: 1,
                resource: wgpu::BindingResource::Sampler(&renderer.sampler),
            },
        ],
    });

    NowPlayingOverlay { texture, bind_group }
}
