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

/// An enumerated audio device with its host info.
#[derive(Clone)]
struct AudioDeviceInfo {
    host_id: cpal::HostId,
    name: String,
    channels: usize,
    index_in_host: usize,
    is_output: bool, // true = output device (shown for reference, may support loopback)
}

struct App {
    scene_path: PathBuf,
    layout_mode: LayoutMode,
    state: Option<AppState>,
    audio_shared: audio::SharedAudioData,
    cv_shared: cv::SharedCvData,
    // Audio device management
    audio_devices: Vec<AudioDeviceInfo>,
    audio_device_index: usize,
    audio_channels: Option<audio::ChannelPair>,
    // Visual sample board
    clip_board: clips::ClipBoard,
    // Global Lua controller
    controller: control::Controller,
    control_state: control::SharedControlState,
    text_renderer: text::TextRenderer,
    _audio_stream: Option<cpal::Stream>,
}

struct AppState {
    window: Arc<Window>,
    renderer: renderer::Renderer,
    start_time: Instant,
    last_frame: Instant,
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

        let default_config = scene::SceneConfig::default();
        let config_ref = scene_config.as_ref().unwrap_or(&default_config);
        let (controller, control_state) = control::Controller::new(config_ref, scene_path.to_str().unwrap_or(""))?;
        let text_renderer = text::TextRenderer::new(512, 512);

        let channels = audio_config
            .channels
            .as_deref()
            .and_then(audio::ChannelPair::parse);

        // Enumerate all devices across all hosts
        let audio_devices = enumerate_all_devices();
        log::info!("found {} audio input devices across all hosts", audio_devices.len());

        // Find the matching device
        let audio_device_index = find_device_index(&audio_devices, &audio_config);

        // Start audio capture
        let audio_stream = if !audio_devices.is_empty() {
            switch_to_device_info(&audio_devices[audio_device_index], &audio_shared, channels)
        } else {
            log::warn!("no audio input devices found");
            None
        };

        if let Err(e) = cv::start_cv_reader(cv_shared.clone()) {
            log::warn!("CV reader failed: {}", e);
        }

        Ok(Self {
            scene_path,
            layout_mode,
            state: None,
            audio_shared,
            cv_shared,
            audio_devices,
            audio_device_index,
            audio_channels: channels,
            clip_board,
            controller,
            control_state,
            text_renderer,
            _audio_stream: audio_stream,
        })
    }
}

/// Enumerate input devices from ALL available audio hosts.
/// On Linux this finds ALSA hardware devices that PulseAudio/PipeWire hide.
fn enumerate_all_devices() -> Vec<AudioDeviceInfo> {
    use cpal::traits::{DeviceTrait, HostTrait};

    let available = cpal::available_hosts();
    log::info!("available audio hosts: {:?}", available);

    let mut all_devices = Vec::new();

    for host_id in &available {
        let host = match cpal::host_from_id(*host_id) {
            Ok(h) => h,
            Err(_) => continue,
        };

        // Collect input devices
        if let Ok(devices) = host.input_devices() {
            for (idx, device) in devices.enumerate() {
                let name = device.name().unwrap_or_else(|_| "unknown".into());
                let channels = device
                    .default_input_config()
                    .map(|c| c.channels() as usize)
                    .unwrap_or(0);
                if channels == 0 { continue; }
                all_devices.push(AudioDeviceInfo {
                    host_id: *host_id,
                    name,
                    channels,
                    index_in_host: idx,
                    is_output: false,
                });
            }
        }

        // Collect output devices too (some can be opened as input for loopback/monitor)
        if let Ok(devices) = host.output_devices() {
            for (idx, device) in devices.enumerate() {
                let name = device.name().unwrap_or_else(|_| "unknown".into());
                // Check if this output device also supports input capture
                let input_channels = device
                    .default_input_config()
                    .map(|c| c.channels() as usize)
                    .unwrap_or(0);
                let output_channels = device
                    .default_output_config()
                    .map(|c| c.channels() as usize)
                    .unwrap_or(0);
                if output_channels == 0 { continue; }
                all_devices.push(AudioDeviceInfo {
                    host_id: *host_id,
                    name,
                    channels: if input_channels > 0 { input_channels } else { output_channels },
                    index_in_host: idx,
                    is_output: true,
                });
            }
        }
    }

    // Deduplicate by name (same device might appear in multiple hosts)
    all_devices.sort_by(|a, b| a.name.cmp(&b.name));
    all_devices.dedup_by(|a, b| a.name == b.name);

    all_devices
}

fn find_device_index(devices: &[AudioDeviceInfo], config: &scene::AudioConfig) -> usize {
    if let Some(ref name_filter) = config.device {
        let filter_lower = name_filter.to_lowercase();
        for (i, d) in devices.iter().enumerate() {
            if d.name.to_lowercase().contains(&filter_lower) {
                return i;
            }
        }
    }
    0
}

fn switch_to_device_info(
    info: &AudioDeviceInfo,
    shared: &audio::SharedAudioData,
    channels: Option<audio::ChannelPair>,
) -> Option<cpal::Stream> {
    use cpal::traits::{DeviceTrait, HostTrait};

    let host = cpal::host_from_id(info.host_id).ok()?;

    // For output devices, try to find matching input device by name
    // (on macOS CoreAudio, devices appear in both input and output lists)
    let device = if info.is_output {
        // First try: find an input device with the same name
        let input_match = host.input_devices().ok()?.find(|d| {
            d.name().map(|n| n == info.name).unwrap_or(false)
        });
        if let Some(d) = input_match {
            d
        } else {
            // Fallback: try opening the output device (won't work for capture usually)
            host.output_devices().ok()?.nth(info.index_in_host)?
        }
    } else {
        host.input_devices().ok()?.nth(info.index_in_host)?
    };

    let pair = channels.unwrap_or_else(|| audio::ChannelPair::default_for(info.channels));
    log::info!(
        "audio: [{}] {} ({}ch, L={} R={}, host={:?})",
        info.index_in_host, info.name, info.channels, pair.left, pair.right, info.host_id
    );

    match audio::start_capture_device(shared.clone(), device, Some(pair)) {
        Ok(stream) => Some(stream),
        Err(e) => {
            log::error!("failed to start audio on '{}': {}", info.name, e);
            None
        }
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
        let devices: Vec<_> = host.input_devices()?.collect();
        let found = devices.into_iter().find(|d| {
            d.name()
                .map(|n| n.to_lowercase().contains(&name_filter.to_lowercase()))
                .unwrap_or(false)
        });
        match found {
            Some(d) => d,
            None => host
                .default_input_device()
                .ok_or_else(|| anyhow::anyhow!("no audio input device"))?,
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
                        PhysicalKey::Code(KeyCode::KeyI) => Some("i"),
                        _ => None,
                    };

                    // i = list audio devices
                    if let Some("i") = key_str {
                        self.audio_devices = enumerate_all_devices();
                        log::info!("=== Audio Devices ===");
                        for (i, d) in self.audio_devices.iter().enumerate() {
                            let marker = if i == self.audio_device_index { " ← active" } else { "" };
                            let hint = if d.is_output {
                                " (output — use BlackHole or device loopback to capture)"
                            } else if d.channels >= 6 {
                                " (try channels 4,5 for loopback)"
                            } else {
                                ""
                            };
                            let kind = if d.is_output { "OUT" } else { "IN " };
                            log::info!("  [{}] {} {} ({}ch){}{}", i, kind, d.name, d.channels, marker, hint);
                        }
                        if let Some(pair) = self.audio_channels {
                            log::info!("  channels: L={} R={}", pair.left, pair.right);
                        } else {
                            log::info!("  channels: auto");
                        }
                        log::info!("=== [ ] = device, {{ }} = channels ===");
                        return;
                    }

                    // [ ] = cycle device
                    if event.physical_key == PhysicalKey::Code(KeyCode::BracketLeft) {
                        // Check for shift (channel cycling)
                        if let Some(text) = &event.text {
                            if text.as_str() == "{" {
                                let current = self.audio_channels
                                    .unwrap_or(audio::ChannelPair { left: 0, right: 1 });
                                if current.left >= 2 {
                                    let new_pair = audio::ChannelPair {
                                        left: current.left - 2,
                                        right: current.right - 2,
                                    };
                                    self.audio_channels = Some(new_pair);
                                    log::info!("channel pair: L={} R={}", new_pair.left, new_pair.right);
                                    if let Some(stream) = switch_to_device_info(
                                        &self.audio_devices[self.audio_device_index],
                                        &self.audio_shared,
                                        Some(new_pair),
                                    ) {
                                        self._audio_stream = Some(stream);
                                    }
                                }
                                return;
                            }
                        }
                        // Regular [ = previous input device (skip output-only)
                        let mut idx = self.audio_device_index;
                        while idx > 0 {
                            idx -= 1;
                            if !self.audio_devices[idx].is_output {
                                self.audio_device_index = idx;
                                if let Some(stream) = switch_to_device_info(
                                    &self.audio_devices[idx],
                                    &self.audio_shared,
                                    self.audio_channels,
                                ) {
                                    self._audio_stream = Some(stream);
                                }
                                break;
                            }
                        }
                        return;
                    }
                    if event.physical_key == PhysicalKey::Code(KeyCode::BracketRight) {
                        // Check for shift (channel cycling)
                        if let Some(text) = &event.text {
                            if text.as_str() == "}" {
                                let current = self.audio_channels
                                    .unwrap_or(audio::ChannelPair { left: 0, right: 1 });
                                let new_pair = audio::ChannelPair {
                                    left: current.left + 2,
                                    right: current.right + 2,
                                };
                                self.audio_channels = Some(new_pair);
                                log::info!("channel pair: L={} R={}", new_pair.left, new_pair.right);
                                if let Some(stream) = switch_to_device_info(
                                    &self.audio_devices[self.audio_device_index],
                                    &self.audio_shared,
                                    Some(new_pair),
                                ) {
                                    self._audio_stream = Some(stream);
                                }
                                return;
                            }
                        }
                        // Regular ] = next input device (skip output-only)
                        let mut idx = self.audio_device_index;
                        while idx + 1 < self.audio_devices.len() {
                            idx += 1;
                            if !self.audio_devices[idx].is_output {
                                self.audio_device_index = idx;
                                if let Some(stream) = switch_to_device_info(
                                    &self.audio_devices[idx],
                                    &self.audio_shared,
                                    self.audio_channels,
                                ) {
                                    self._audio_stream = Some(stream);
                                }
                                break;
                            }
                        }
                        return;
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
                        if let Ok(entries) = std::fs::read_dir("scenes") {
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

                    if let Some(key) = key_str {
                        self.controller.on_key(key);
                        state.renderer.toggle_video_by_key(key);
                        if self.clip_board.on_key(key, &mut state.renderer, self.layout_mode) {
                            return;
                        }
                    }
                }
            }
            WindowEvent::RedrawRequested => {
                let now = Instant::now();
                let dt = now.duration_since(state.last_frame).as_secs_f32();
                state.last_frame = now;

                let audio = self.audio_shared.lock().unwrap();
                let cv = *self.cv_shared.lock().unwrap();

                for ch in 0..8 {
                    self.controller.on_cv(ch, cv[ch]);
                }

                if !self.clip_board.is_empty() {
                    self.clip_board.check_cv(&cv, &mut state.renderer, self.layout_mode);
                }
                state.renderer.gate_video_by_cv(&cv);

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
                if ctrl.advance_video {
                    state.renderer.advance_video_sequences();
                }
                for key in &ctrl.video_toggles {
                    state.renderer.toggle_video_by_key(key);
                }

                if ctrl.now_playing_changed {
                    let pixels = self.text_renderer.render_now_playing(
                        &ctrl.now_playing_artist,
                        &ctrl.now_playing_title,
                    );
                    state.now_playing_texture = Some(create_now_playing_overlay(&state.renderer, &pixels));
                    log::info!("now playing: {} - {}", ctrl.now_playing_artist, ctrl.now_playing_title);
                }

                if audio.beat > 0.7 {
                    self.controller.on_beat();
                }
                self.controller.on_tick(dt);

                let elapsed = state.start_time.elapsed().as_secs_f32();
                state.renderer.update_video_sequences(elapsed);
                state.renderer.update_video_frames(elapsed);

                let uniforms = Uniforms {
                    time: elapsed,
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
                    onset: audio.onset,
                    sub_bass: audio.sub_bass,
                    presence: audio.presence,
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

                drop(audio);

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

    // --list-audio: print devices and exit
    if std::env::args().any(|a| a == "--list-audio") {
        let devices = enumerate_all_devices();
        println!("Audio Devices:");
        for (i, d) in devices.iter().enumerate() {
            let kind = if d.is_output { "OUT" } else { "IN " };
            println!("  [{}] {} {} ({}ch, {:?})", i, kind, d.name, d.channels, d.host_id);
        }
        return Ok(());
    }

    log::info!("hyperspace starting");
    log::info!("scene: {}", scene_path.display());
    log::info!("layout: {:?}", layout_mode);

    let mut app = App::new(scene_path, layout_mode)?;

    let event_loop = EventLoop::new()?;
    event_loop.run_app(&mut app)?;

    Ok(())
}

fn create_now_playing_overlay(renderer: &renderer::Renderer, pixels: &[u8]) -> NowPlayingOverlay {
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

    // Flip Y for correct orientation when blitted
    let stride = (w * 4) as usize;
    let mut flipped = vec![0u8; pixels.len()];
    for row in 0..h as usize {
        let src = row * stride;
        let dst = (h as usize - 1 - row) * stride;
        flipped[dst..dst + stride].copy_from_slice(&pixels[src..src + stride]);
    }

    renderer.queue.write_texture(
        texture.as_image_copy(),
        &flipped,
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
