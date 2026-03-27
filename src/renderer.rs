use anyhow::Result;
use std::path::Path;
use wgpu::util::DeviceExt;

use crate::scene::Viewport;
use crate::scripting;
use crate::uniforms::Uniforms;
use crate::video::VideoOverlay;

const SPECTRUM_SIZE: usize = 512;
const WAVEFORM_SIZE: usize = 512;
const AUDIO_BUFFER_SIZE: usize = SPECTRUM_SIZE + WAVEFORM_SIZE * 2;
const FEEDBACK_SIZE: u32 = 512; // offscreen texture resolution for feedback pipelines

/// Ping-pong framebuffers for feedback effects.
struct FeedbackState {
    textures: [wgpu::Texture; 2],
    views: [wgpu::TextureView; 2],
    /// Which texture holds the most recent complete result (read by next frame's main shader)
    result_idx: usize,
}

/// Loaded overlay image for compositing on top of a viewport.
struct OverlayState {
    bind_group: wgpu::BindGroup,
}

/// Video sequence: multiple loaded videos for crossfading playback.
pub struct VideoSequenceState {
    pub videos: Vec<VideoOverlay>,
    pub speed: f32,
}

/// Video overlay: GPU texture that gets updated with the current frame each render.
pub struct VideoOverlayState {
    pub data: VideoOverlay,
    pub texture: wgpu::Texture,
    pub view: wgpu::TextureView,
    pub bind_group: wgpu::BindGroup,
    pub toggle_key: Option<String>,
    pub cv_channel: Option<usize>,
}

/// A compiled shader pipeline for one viewport.
pub struct ShaderPipeline {
    pub viewport: Viewport,
    pub render_pipeline: wgpu::RenderPipeline,
    /// Post-processing shader chain (each reads prev pass output via prev_frame)
    pub post_pipelines: Vec<wgpu::RenderPipeline>,
    pub state_buffer: wgpu::Buffer,
    /// Two bind groups for ping-pong: [0] reads texture 0, [1] reads texture 1
    pub bind_groups: [wgpu::BindGroup; 2],
    pub feedback: Option<FeedbackState>,
    pub overlay: Option<OverlayState>,
    pub video: Option<VideoOverlayState>,
    pub video_sequence: Option<VideoSequenceState>,
    pub script: Option<scripting::ShaderScript>,
}

/// The GPU renderer managing all shader pipelines.
pub struct Renderer {
    pub device: wgpu::Device,
    pub queue: wgpu::Queue,
    pub surface: wgpu::Surface<'static>,
    pub surface_config: wgpu::SurfaceConfiguration,
    pub uniform_buffer: wgpu::Buffer,
    pub spectrum_buffer: wgpu::Buffer,
    pub bind_group_layout: wgpu::BindGroupLayout,
    pub sampler: wgpu::Sampler,
    pub dummy_texture_view: wgpu::TextureView,
    pub blit_pipeline: wgpu::RenderPipeline,
    pub blit_bind_group_layout: wgpu::BindGroupLayout,
    pub overlay_pipeline: wgpu::RenderPipeline, // same shader as blit but with alpha blending
    pub pipelines: Vec<ShaderPipeline>,
}

const BLIT_SHADER: &str = r#"
@group(0) @binding(0) var tex: texture_2d<f32>;
@group(0) @binding(1) var tex_sampler: sampler;

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) idx: u32) -> VertexOutput {
    var pos = array<vec2<f32>, 3>(
        vec2<f32>(-1.0, -1.0),
        vec2<f32>(3.0, -1.0),
        vec2<f32>(-1.0, 3.0),
    );
    var out: VertexOutput;
    out.position = vec4<f32>(pos[idx], 0.0, 1.0);
    out.uv = pos[idx] * 0.5 + 0.5;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    return textureSample(tex, tex_sampler, in.uv);
}
"#;

impl Renderer {
    pub async fn new(window: std::sync::Arc<winit::window::Window>) -> Result<Self> {
        let size = window.inner_size();

        let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor {
            backends: wgpu::Backends::all(),
            ..Default::default()
        });

        let surface = instance.create_surface(window)?;

        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                compatible_surface: Some(&surface),
                force_fallback_adapter: false,
            })
            .await
            .ok_or_else(|| anyhow::anyhow!("no suitable GPU adapter found"))?;

        log::info!("GPU adapter: {:?}", adapter.get_info().name);

        let (device, queue) = adapter
            .request_device(
                &wgpu::DeviceDescriptor {
                    label: Some("hyperspace"),
                    required_features: wgpu::Features::empty(),
                    required_limits: wgpu::Limits::default(),
                    ..Default::default()
                },
                None,
            )
            .await?;

        let surface_caps = surface.get_capabilities(&adapter);
        let surface_format = surface_caps
            .formats
            .iter()
            .find(|f| f.is_srgb())
            .copied()
            .unwrap_or(surface_caps.formats[0]);

        let surface_config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format: surface_format,
            width: size.width.max(1),
            height: size.height.max(1),
            present_mode: wgpu::PresentMode::AutoVsync,
            alpha_mode: surface_caps.alpha_modes[0],
            view_formats: vec![],
            desired_maximum_frame_latency: 2,
        };
        surface.configure(&device, &surface_config);

        // Uniform buffer
        let uniform_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("uniforms"),
            contents: bytemuck::bytes_of(&Uniforms::default()),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });

        // Audio storage buffer
        let spectrum_data = vec![0.0f32; AUDIO_BUFFER_SIZE];
        let spectrum_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("audio"),
            contents: bytemuck::cast_slice(&spectrum_data),
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST,
        });

        // Sampler for feedback texture
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("feedback_sampler"),
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            ..Default::default()
        });

        // 1x1 black dummy texture for non-feedback pipelines
        let dummy_texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("dummy"),
            size: wgpu::Extent3d { width: 1, height: 1, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8UnormSrgb,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        queue.write_texture(
            dummy_texture.as_image_copy(),
            &[0u8, 0, 0, 255],
            wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(4), rows_per_image: None },
            wgpu::Extent3d { width: 1, height: 1, depth_or_array_layers: 1 },
        );
        let dummy_texture_view = dummy_texture.create_view(&Default::default());

        // Main bind group layout: uniforms + audio + state + sampler + prev_frame texture
        let bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("hyperspace_bgl"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Storage { read_only: true },
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 2,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Storage { read_only: true },
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 3,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 4,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
            ],
        });

        // Blit pipeline (copies offscreen feedback texture to surface viewport)
        let blit_bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("blit_bgl"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        });

        let blit_shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("blit"),
            source: wgpu::ShaderSource::Wgsl(BLIT_SHADER.into()),
        });

        let blit_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("blit_layout"),
            bind_group_layouts: &[&blit_bind_group_layout],
            push_constant_ranges: &[],
        });

        let blit_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("blit"),
            layout: Some(&blit_layout),
            vertex: wgpu::VertexState {
                module: &blit_shader,
                entry_point: Some("vs_main"),
                buffers: &[],
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &blit_shader,
                entry_point: Some("fs_main"),
                targets: &[Some(wgpu::ColorTargetState {
                    format: surface_format,
                    blend: Some(wgpu::BlendState::REPLACE),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: Default::default(),
            }),
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleList,
                ..Default::default()
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview: None,
            cache: None,
        });

        // Overlay pipeline: same as blit but with alpha blending
        let overlay_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("overlay"),
            layout: Some(&blit_layout),
            vertex: wgpu::VertexState {
                module: &blit_shader,
                entry_point: Some("vs_main"),
                buffers: &[],
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &blit_shader,
                entry_point: Some("fs_main"),
                targets: &[Some(wgpu::ColorTargetState {
                    format: surface_format,
                    blend: Some(wgpu::BlendState::ALPHA_BLENDING),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: Default::default(),
            }),
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleList,
                ..Default::default()
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview: None,
            cache: None,
        });

        Ok(Self {
            device,
            queue,
            surface,
            surface_config,
            uniform_buffer,
            spectrum_buffer,
            bind_group_layout,
            sampler,
            dummy_texture_view,
            blit_pipeline,
            blit_bind_group_layout,
            overlay_pipeline,
            pipelines: Vec::new(),
        })
    }

    fn create_feedback_texture(&self, label: &str) -> (wgpu::Texture, wgpu::TextureView) {
        let tex = self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some(label),
            size: wgpu::Extent3d {
                width: FEEDBACK_SIZE,
                height: FEEDBACK_SIZE,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: self.surface_config.format,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        let view = tex.create_view(&Default::default());
        (tex, view)
    }

    fn create_bind_group(&self, state_buffer: &wgpu::Buffer, texture_view: &wgpu::TextureView) -> wgpu::BindGroup {
        self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &self.bind_group_layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: self.uniform_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: self.spectrum_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 2, resource: state_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::Sampler(&self.sampler) },
                wgpu::BindGroupEntry { binding: 4, resource: wgpu::BindingResource::TextureView(texture_view) },
            ],
        })
    }

    /// Load a shader and create a render pipeline for a viewport.
    pub fn load_shader(&mut self, viewport: Viewport) -> Result<()> {
        let shader_src = std::fs::read_to_string(Path::new(&viewport.shader_path))?;

        // Feedback is needed if the main shader uses prev_frame OR has post-processing
        let uses_feedback = shader_src.contains("prev_frame") || !viewport.post.is_empty();

        let shader_module = self.device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some(&viewport.name),
            source: wgpu::ShaderSource::Wgsl(shader_src.into()),
        });

        let target_format = if uses_feedback {
            self.surface_config.format // feedback renders to offscreen (same format)
        } else {
            self.surface_config.format
        };

        let pipeline_layout = self.device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some(&format!("{}_layout", viewport.name)),
            bind_group_layouts: &[&self.bind_group_layout],
            push_constant_ranges: &[],
        });

        let render_pipeline = self.device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some(&viewport.name),
            layout: Some(&pipeline_layout),
            vertex: wgpu::VertexState {
                module: &shader_module,
                entry_point: Some("vs_main"),
                buffers: &[],
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &shader_module,
                entry_point: Some("fs_main"),
                targets: &[Some(wgpu::ColorTargetState {
                    format: target_format,
                    blend: Some(wgpu::BlendState::REPLACE),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: Default::default(),
            }),
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleList,
                cull_mode: None,
                ..Default::default()
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview: None,
            cache: None,
        });

        // Compile post-processing shaders
        let mut post_pipelines = Vec::new();
        for (i, post_path) in viewport.post.iter().enumerate() {
            let post_src = std::fs::read_to_string(Path::new(post_path))?;
            let post_module = self.device.create_shader_module(wgpu::ShaderModuleDescriptor {
                label: Some(&format!("{}_{}", viewport.name, i)),
                source: wgpu::ShaderSource::Wgsl(post_src.into()),
            });
            let post_layout = self.device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some(&format!("{}_post_{}_layout", viewport.name, i)),
                bind_group_layouts: &[&self.bind_group_layout],
                push_constant_ranges: &[],
            });
            let post_pipeline = self.device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some(&format!("{}_post_{}", viewport.name, i)),
                layout: Some(&post_layout),
                vertex: wgpu::VertexState {
                    module: &post_module,
                    entry_point: Some("vs_main"),
                    buffers: &[],
                    compilation_options: Default::default(),
                },
                fragment: Some(wgpu::FragmentState {
                    module: &post_module,
                    entry_point: Some("fs_main"),
                    targets: &[Some(wgpu::ColorTargetState {
                        format: target_format,
                        blend: Some(wgpu::BlendState::REPLACE),
                        write_mask: wgpu::ColorWrites::ALL,
                    })],
                    compilation_options: Default::default(),
                }),
                primitive: wgpu::PrimitiveState {
                    topology: wgpu::PrimitiveTopology::TriangleList,
                    cull_mode: None,
                    ..Default::default()
                },
                depth_stencil: None,
                multisample: wgpu::MultisampleState::default(),
                multiview: None,
                cache: None,
            });
            log::info!("  post[{}]: {}", i, post_path);
            post_pipelines.push(post_pipeline);
        }

        // Per-pipeline state buffer
        let state_data = vec![0.0f32; scripting::STATE_BUFFER_SIZE];
        let state_buffer = self.device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some(&format!("{}_state", viewport.name)),
            contents: bytemuck::cast_slice(&state_data),
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST,
        });

        // Create feedback textures if needed
        let feedback = if uses_feedback {
            log::info!("enabling feedback for '{}'", viewport.name);
            let (tex_a, view_a) = self.create_feedback_texture(&format!("{}_fb_a", viewport.name));
            let (tex_b, view_b) = self.create_feedback_texture(&format!("{}_fb_b", viewport.name));
            Some(FeedbackState {
                textures: [tex_a, tex_b],
                views: [view_a, view_b],
                result_idx: 0,
            })
        } else {
            None
        };

        // Create two bind groups (for ping-pong: each reads a different texture)
        let bind_groups = if let Some(ref fb) = feedback {
            [
                self.create_bind_group(&state_buffer, &fb.views[0]),
                self.create_bind_group(&state_buffer, &fb.views[1]),
            ]
        } else {
            [
                self.create_bind_group(&state_buffer, &self.dummy_texture_view),
                self.create_bind_group(&state_buffer, &self.dummy_texture_view),
            ]
        };

        // Try to load paired Lua script
        let mut script = match scripting::ShaderScript::load_for_shader(&viewport.shader_path) {
            Ok(s) => s,
            Err(e) => {
                log::error!("failed to load lua script for {}: {}", viewport.shader_path, e);
                None
            }
        };

        // Load video sources for video_player
        let video_sequence = if !viewport.video_sources.is_empty() {
            let mut videos = Vec::new();
            for src in &viewport.video_sources {
                match VideoOverlay::load(src, 512) {
                    Ok(v) => {
                        log::info!("  video source: {} ({} frames)", src, v.frames.len());
                        videos.push(v);
                    }
                    Err(e) => log::error!("  failed to load video source '{}': {}", src, e),
                }
            }
            if !videos.is_empty() {
                // Tell the Lua script how many clips we have (state[3] = num_clips, 0-indexed = [4] in Lua)
                if let Some(ref mut s) = script {
                    s.state[3] = videos.len() as f32;
                }
                Some(VideoSequenceState { videos, speed: viewport.video_speed })
            } else {
                None
            }
        } else {
            None
        };

        // Load overlay image if specified
        let overlay = if let Some(ref overlay_path) = viewport.overlay {
            match self.load_overlay(overlay_path) {
                Ok(ovl) => {
                    log::info!("  overlay: {}", overlay_path);
                    Some(ovl)
                }
                Err(e) => {
                    log::error!("failed to load overlay '{}': {}", overlay_path, e);
                    None
                }
            }
        } else {
            None
        };

        // Load video overlay if specified
        let video = if let Some(ref video_path) = viewport.video_overlay {
            match VideoOverlay::load(video_path, 512) {
                Ok(mut vid_data) => {
                    // Create GPU texture for the video frames
                    let texture = self.device.create_texture(&wgpu::TextureDescriptor {
                        label: Some("video_overlay"),
                        size: wgpu::Extent3d {
                            width: vid_data.width,
                            height: vid_data.height,
                            depth_or_array_layers: 1,
                        },
                        mip_level_count: 1,
                        sample_count: 1,
                        dimension: wgpu::TextureDimension::D2,
                        format: wgpu::TextureFormat::Rgba8UnormSrgb,
                        usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
                        view_formats: &[],
                    });
                    let view = texture.create_view(&Default::default());
                    let bind_group = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                        label: Some("video_overlay_bg"),
                        layout: &self.blit_bind_group_layout,
                        entries: &[
                            wgpu::BindGroupEntry {
                                binding: 0,
                                resource: wgpu::BindingResource::TextureView(&view),
                            },
                            wgpu::BindGroupEntry {
                                binding: 1,
                                resource: wgpu::BindingResource::Sampler(&self.sampler),
                            },
                        ],
                    });
                    vid_data.visible = true; // start visible by default
                    let toggle_key = viewport.video_overlay_key.clone();
                    let cv_channel = viewport.video_overlay_cv;
                    Some(VideoOverlayState {
                        data: vid_data,
                        texture,
                        view,
                        bind_group,
                        toggle_key,
                        cv_channel,
                    })
                }
                Err(e) => {
                    log::error!("failed to load video overlay '{}': {}", video_path, e);
                    None
                }
            }
        } else {
            None
        };

        self.pipelines.push(ShaderPipeline {
            viewport,
            render_pipeline,
            post_pipelines,
            state_buffer,
            bind_groups,
            feedback,
            overlay,
            video,
            video_sequence,
            script,
        });

        Ok(())
    }

    fn load_overlay(&self, path: &str) -> Result<OverlayState> {
        let img = image::open(path)?.to_rgba8();
        let (w, h) = img.dimensions();

        let texture = self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some(path),
            size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8UnormSrgb,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });

        self.queue.write_texture(
            texture.as_image_copy(),
            &img,
            wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(4 * w),
                rows_per_image: Some(h),
            },
            wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
        );

        let view = texture.create_view(&Default::default());
        let bind_group = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("overlay_bg"),
            layout: &self.blit_bind_group_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&view),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::Sampler(&self.sampler),
                },
            ],
        });

        Ok(OverlayState { bind_group })
    }

    pub fn update_uniforms(&self, uniforms: &Uniforms) {
        self.queue.write_buffer(&self.uniform_buffer, 0, bytemuck::bytes_of(uniforms));
    }

    pub fn update_audio_buffer(&self, spectrum: &[f32], waveform_l: &[f32], waveform_r: &[f32]) {
        let mut buf = vec![0.0f32; AUDIO_BUFFER_SIZE];
        let spec_len = spectrum.len().min(SPECTRUM_SIZE);
        buf[..spec_len].copy_from_slice(&spectrum[..spec_len]);
        let wl_len = waveform_l.len().min(WAVEFORM_SIZE);
        buf[SPECTRUM_SIZE..SPECTRUM_SIZE + wl_len].copy_from_slice(&waveform_l[..wl_len]);
        let wr_len = waveform_r.len().min(WAVEFORM_SIZE);
        buf[SPECTRUM_SIZE + WAVEFORM_SIZE..SPECTRUM_SIZE + WAVEFORM_SIZE + wr_len]
            .copy_from_slice(&waveform_r[..wr_len]);
        self.queue.write_buffer(&self.spectrum_buffer, 0, bytemuck::cast_slice(&buf));
    }

    /// Signal all video sequence Lua scripts to advance to the next clip.
    pub fn advance_video_sequences(&mut self) {
        for pipeline in &mut self.pipelines {
            if pipeline.video_sequence.is_some() {
                if let Some(ref mut script) = pipeline.script {
                    // Call advance_video() on the shader's Lua
                    let globals = script.lua.globals();
                    if let Ok(f) = globals.get::<mlua::Function>("advance_video") {
                        let _ = f.call::<()>(());
                    }
                }
            }
        }
    }

    /// Upload video sequence frames to feedback textures (blended from Lua state).
    pub fn update_video_sequences(&self, time: f32) {
        for pipeline in &self.pipelines {
            let seq = match &pipeline.video_sequence {
                Some(s) if !s.videos.is_empty() => s,
                _ => continue,
            };
            let fb = match &pipeline.feedback {
                Some(f) => f,
                None => continue,
            };

            // Read crossfade state from Lua state buffer
            let (current_idx, next_idx, crossfade) = if let Some(ref script) = pipeline.script {
                let c = script.state[0] as usize;
                let n = script.state[1] as usize;
                let f = script.state[2];
                (c.min(seq.videos.len() - 1), n.min(seq.videos.len() - 1), f)
            } else {
                (0, 0, 0.0)
            };

            let current_video = &seq.videos[current_idx];
            let frame_a_idx = current_video.frame_at(time * seq.speed);
            if frame_a_idx >= current_video.frames.len() { continue; }
            let frame_a = &current_video.frames[frame_a_idx];

            // Build the output frame (crossfaded if transitioning)
            let pixels = if crossfade > 0.01 && current_idx != next_idx {
                let next_video = &seq.videos[next_idx];
                let frame_b_idx = next_video.frame_at(time * seq.speed);
                if frame_b_idx < next_video.frames.len() {
                    let frame_b = &next_video.frames[frame_b_idx];
                    blend_frames(&frame_a.rgba, &frame_b.rgba, crossfade)
                } else {
                    frame_a.rgba.clone()
                }
            } else {
                frame_a.rgba.clone()
            };

            // Upload to the feedback texture that will be read as prev_frame
            let target_idx = fb.result_idx;
            let w = current_video.width;
            let h = current_video.height;
            self.queue.write_texture(
                wgpu::TexelCopyTextureInfo {
                    texture: &fb.textures[target_idx],
                    mip_level: 0,
                    origin: wgpu::Origin3d::ZERO,
                    aspect: wgpu::TextureAspect::All,
                },
                &pixels,
                wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(4 * w),
                    rows_per_image: Some(h),
                },
                wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
            );
        }
    }

    /// Upload the current video frame for all video overlays.
    pub fn update_video_frames(&self, time: f32) {
        for pipeline in &self.pipelines {
            if let Some(ref vid) = pipeline.video {
                if !vid.data.visible || vid.data.frames.is_empty() {
                    continue;
                }
                let frame_idx = vid.data.frame_at(time);
                let frame = &vid.data.frames[frame_idx];
                self.queue.write_texture(
                    vid.texture.as_image_copy(),
                    &frame.rgba,
                    wgpu::TexelCopyBufferLayout {
                        offset: 0,
                        bytes_per_row: Some(4 * vid.data.width),
                        rows_per_image: Some(vid.data.height),
                    },
                    wgpu::Extent3d {
                        width: vid.data.width,
                        height: vid.data.height,
                        depth_or_array_layers: 1,
                    },
                );
            }
        }
    }

    /// Toggle video overlay by key.
    pub fn toggle_video_by_key(&mut self, key: &str) {
        for pipeline in &mut self.pipelines {
            if let Some(ref mut vid) = pipeline.video {
                if vid.toggle_key.as_deref() == Some(key) {
                    vid.data.toggle();
                }
            }
        }
    }

    /// Gate video overlay by CV (high = visible).
    pub fn gate_video_by_cv(&mut self, cv_data: &[f32; 8]) {
        for pipeline in &mut self.pipelines {
            if let Some(ref mut vid) = pipeline.video {
                if let Some(ch) = vid.cv_channel {
                    if ch < 8 {
                        vid.data.visible = cv_data[ch] > 0.5;
                    }
                }
            }
        }
    }

    pub fn update_scripts(&mut self, uniforms: &scripting::ScriptUniforms) {
        for pipeline in &mut self.pipelines {
            if let Some(ref mut script) = pipeline.script {
                if let Err(e) = script.update(uniforms) {
                    log::error!("lua script error for {}: {}", pipeline.viewport.name, e);
                }
                self.queue.write_buffer(
                    &pipeline.state_buffer,
                    0,
                    bytemuck::cast_slice(&script.state),
                );
            }
        }
    }

    /// Render all pipelines to the surface.
    pub fn render_with_overlay(&mut self, now_playing_bg: Option<&wgpu::BindGroup>) -> Result<()> {
        let output = self.surface.get_current_texture()?;
        let surface_view = output.texture.create_view(&Default::default());

        let fb_w = self.surface_config.width as f32;
        let fb_h = self.surface_config.height as f32;

        // First: submit feedback pipeline offscreen renders (main + post chain)
        // Each pass needs a separate submission so the texture is ready for the next pass.
        for pipeline in &mut self.pipelines {
            if let Some(ref mut fb) = pipeline.feedback {
                // Main shader: reads texture[result_idx], writes to texture[1-result_idx]
                let read_idx = fb.result_idx;
                let write_idx = 1 - read_idx;

                {
                    let mut encoder = self.device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
                        label: Some("feedback_main"),
                    });
                    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                        label: Some("feedback_main_pass"),
                        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                            view: &fb.views[write_idx],
                            resolve_target: None,
                            ops: wgpu::Operations {
                                load: wgpu::LoadOp::Load,
                                store: wgpu::StoreOp::Store,
                            },
                        })],
                        depth_stencil_attachment: None,
                        timestamp_writes: None,
                        occlusion_query_set: None,
                    });
                    pass.set_pipeline(&pipeline.render_pipeline);
                    pass.set_bind_group(0, &pipeline.bind_groups[read_idx], &[]);
                    pass.draw(0..3, 0..1);
                    drop(pass);
                    self.queue.submit(std::iter::once(encoder.finish()));
                }

                // Post-processing chain: ping-pong between textures
                let mut current_result = write_idx;
                for post_pipeline in &pipeline.post_pipelines {
                    let post_read = current_result;
                    let post_write = 1 - post_read;

                    // Create a bind group reading the current result (inline to avoid borrow issue)
                    let post_bg = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                        label: None,
                        layout: &self.bind_group_layout,
                        entries: &[
                            wgpu::BindGroupEntry { binding: 0, resource: self.uniform_buffer.as_entire_binding() },
                            wgpu::BindGroupEntry { binding: 1, resource: self.spectrum_buffer.as_entire_binding() },
                            wgpu::BindGroupEntry { binding: 2, resource: pipeline.state_buffer.as_entire_binding() },
                            wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::Sampler(&self.sampler) },
                            wgpu::BindGroupEntry { binding: 4, resource: wgpu::BindingResource::TextureView(&fb.views[post_read]) },
                        ],
                    });

                    let mut encoder = self.device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
                        label: Some("post_pass"),
                    });
                    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                        label: Some("post_pass"),
                        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                            view: &fb.views[post_write],
                            resolve_target: None,
                            ops: wgpu::Operations {
                                load: wgpu::LoadOp::Load,
                                store: wgpu::StoreOp::Store,
                            },
                        })],
                        depth_stencil_attachment: None,
                        timestamp_writes: None,
                        occlusion_query_set: None,
                    });
                    pass.set_pipeline(post_pipeline);
                    pass.set_bind_group(0, &post_bg, &[]);
                    pass.draw(0..3, 0..1);
                    drop(pass);
                    self.queue.submit(std::iter::once(encoder.finish()));

                    current_result = post_write;
                }

                // Update result index so next frame reads the final output
                fb.result_idx = current_result;
            }
        }

        // Second: one encoder for all surface rendering (clear + all viewports + blits)
        let mut encoder = self.device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("surface_render"),
        });

        // Clear the surface to black
        {
            encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("clear"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &surface_view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
            });
        }

        // Render each pipeline to its viewport
        for pipeline in &mut self.pipelines {
            let vp = &pipeline.viewport;
            let x = (vp.rect[0] * fb_w) as u32;
            let y = (vp.rect[1] * fb_h) as u32;
            let w = (vp.rect[2] * fb_w) as u32;
            let h = (vp.rect[3] * fb_h) as u32;

            if let Some(ref fb) = pipeline.feedback {
                // Blit the final chain result to surface viewport
                let blit_bg = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: Some("blit_bg"),
                    layout: &self.blit_bind_group_layout,
                    entries: &[
                        wgpu::BindGroupEntry {
                            binding: 0,
                            resource: wgpu::BindingResource::TextureView(&fb.views[fb.result_idx]),
                        },
                        wgpu::BindGroupEntry {
                            binding: 1,
                            resource: wgpu::BindingResource::Sampler(&self.sampler),
                        },
                    ],
                });

                {
                    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                        label: Some("blit_pass"),
                        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                            view: &surface_view,
                            resolve_target: None,
                            ops: wgpu::Operations {
                                load: wgpu::LoadOp::Load,
                                store: wgpu::StoreOp::Store,
                            },
                        })],
                        depth_stencil_attachment: None,
                        timestamp_writes: None,
                        occlusion_query_set: None,
                    });

                    pass.set_viewport(x as f32, y as f32, w as f32, h as f32, 0.0, 1.0);
                    pass.set_scissor_rect(x, y, w, h);
                    pass.set_pipeline(&self.blit_pipeline);
                    pass.set_bind_group(0, &blit_bg, &[]);
                    pass.draw(0..3, 0..1);
                }

            } else {
                // Direct render to surface viewport
                let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                    label: Some(&vp.name),
                    color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                        view: &surface_view,
                        resolve_target: None,
                        ops: wgpu::Operations {
                            load: wgpu::LoadOp::Load,
                            store: wgpu::StoreOp::Store,
                        },
                    })],
                    depth_stencil_attachment: None,
                    timestamp_writes: None,
                    occlusion_query_set: None,
                });

                pass.set_viewport(x as f32, y as f32, w as f32, h as f32, 0.0, 1.0);
                pass.set_scissor_rect(x, y, w, h);
                pass.set_pipeline(&pipeline.render_pipeline);
                pass.set_bind_group(0, &pipeline.bind_groups[0], &[]);
                pass.draw(0..3, 0..1);
            }

            // Static overlay compositing (alpha-blended on top)
            if let Some(ref ovl) = pipeline.overlay {
                let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                    label: Some("overlay_pass"),
                    color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                        view: &surface_view,
                        resolve_target: None,
                        ops: wgpu::Operations {
                            load: wgpu::LoadOp::Load,
                            store: wgpu::StoreOp::Store,
                        },
                    })],
                    depth_stencil_attachment: None,
                    timestamp_writes: None,
                    occlusion_query_set: None,
                });
                pass.set_viewport(x as f32, y as f32, w as f32, h as f32, 0.0, 1.0);
                pass.set_scissor_rect(x, y, w, h);
                pass.set_pipeline(&self.overlay_pipeline);
                pass.set_bind_group(0, &ovl.bind_group, &[]);
                pass.draw(0..3, 0..1);
            }

            // Video overlay compositing (alpha-blended, only when visible)
            if let Some(ref vid) = pipeline.video {
                if vid.data.visible {
                    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                        label: Some("video_overlay_pass"),
                        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                            view: &surface_view,
                            resolve_target: None,
                            ops: wgpu::Operations {
                                load: wgpu::LoadOp::Load,
                                store: wgpu::StoreOp::Store,
                            },
                        })],
                        depth_stencil_attachment: None,
                        timestamp_writes: None,
                        occlusion_query_set: None,
                    });
                    pass.set_viewport(x as f32, y as f32, w as f32, h as f32, 0.0, 1.0);
                    pass.set_scissor_rect(x, y, w, h);
                    pass.set_pipeline(&self.overlay_pipeline);
                    pass.set_bind_group(0, &vid.bind_group, &[]);
                    pass.draw(0..3, 0..1);
                }
            }
        }

        // Now playing text overlay (full-screen, alpha-blended)
        if let Some(np_bg) = now_playing_bg {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("now_playing"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &surface_view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Load,
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
            });
            pass.set_pipeline(&self.overlay_pipeline);
            pass.set_bind_group(0, np_bg, &[]);
            pass.draw(0..3, 0..1);
        }

        self.queue.submit(std::iter::once(encoder.finish()));
        output.present();
        Ok(())
    }

    pub fn resize(&mut self, width: u32, height: u32) {
        if width > 0 && height > 0 {
            self.surface_config.width = width;
            self.surface_config.height = height;
            self.surface.configure(&self.device, &self.surface_config);
        }
    }
}

/// Blend two RGBA frames by crossfade amount (0.0 = a, 1.0 = b).
fn blend_frames(a: &[u8], b: &[u8], t: f32) -> Vec<u8> {
    let len = a.len().min(b.len());
    let t_fixed = (t * 256.0) as u16;
    let inv_t = 256 - t_fixed;
    (0..len)
        .map(|i| ((a[i] as u16 * inv_t + b[i] as u16 * t_fixed) >> 8) as u8)
        .collect()
}
