mod audio;
mod cv;
mod renderer;
mod scene;
mod uniforms;

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
    // Keep audio stream alive
    _audio_stream: Option<cpal::Stream>,
}

struct AppState {
    window: Arc<Window>,
    renderer: renderer::Renderer,
    start_time: Instant,
    last_frame: Instant,
}

impl App {
    fn new(scene_path: PathBuf, layout_mode: LayoutMode) -> Result<Self> {
        let audio_shared = audio::new_shared();
        let cv_shared = cv::new_shared();

        // Load scene config early to get audio settings
        let audio_config = scene::SceneConfig::load(&scene_path)
            .ok()
            .map(|c| c.audio)
            .unwrap_or_default();

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

        self.state = Some(AppState {
            window,
            renderer,
            start_time: Instant::now(),
            last_frame: Instant::now(),
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
                if event.physical_key
                    == winit::keyboard::PhysicalKey::Code(winit::keyboard::KeyCode::Escape)
                    && event.state == winit::event::ElementState::Pressed
                {
                    event_loop.exit();
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
                state.renderer.update_spectrum(&audio.spectrum);

                drop(audio); // release lock before render

                if let Err(e) = state.renderer.render() {
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
        Some("9") => LayoutMode::NineOutput,
        _ => LayoutMode::ThreeOutput,
    };

    log::info!("hyperspace starting");
    log::info!("scene: {}", scene_path.display());
    log::info!("layout: {:?}", layout_mode);

    let mut app = App::new(scene_path, layout_mode)?;

    let event_loop = EventLoop::new()?;
    event_loop.run_app(&mut app)?;

    Ok(())
}
