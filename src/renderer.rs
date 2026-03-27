use anyhow::Result;
use std::path::Path;
use wgpu::util::DeviceExt;

use crate::scene::Viewport;
use crate::uniforms::Uniforms;

const SPECTRUM_SIZE: usize = 512; // half of 1024-point FFT
const WAVEFORM_SIZE: usize = 512; // raw samples per channel
// Buffer layout: [0..512) spectrum, [512..1024) waveform L, [1024..1536) waveform R
const AUDIO_BUFFER_SIZE: usize = SPECTRUM_SIZE + WAVEFORM_SIZE * 2;

/// A compiled shader pipeline for one viewport.
pub struct ShaderPipeline {
    pub viewport: Viewport,
    pub render_pipeline: wgpu::RenderPipeline,
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
    pub bind_group: wgpu::BindGroup,
    pub pipelines: Vec<ShaderPipeline>,
}

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

        // Create uniform buffer
        let uniform_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("uniforms"),
            contents: bytemuck::bytes_of(&Uniforms::default()),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });

        // Create FFT spectrum storage buffer
        let spectrum_data = vec![0.0f32; AUDIO_BUFFER_SIZE];
        let spectrum_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("spectrum"),
            contents: bytemuck::cast_slice(&spectrum_data),
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST,
        });

        // Bind group layout: uniforms + spectrum
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
            ],
        });

        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("hyperspace_bg"),
            layout: &bind_group_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: uniform_buffer.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: spectrum_buffer.as_entire_binding(),
                },
            ],
        });

        Ok(Self {
            device,
            queue,
            surface,
            surface_config,
            uniform_buffer,
            spectrum_buffer,
            bind_group_layout,
            bind_group,
            pipelines: Vec::new(),
        })
    }

    /// Load a shader and create a render pipeline for a viewport.
    pub fn load_shader(&mut self, viewport: Viewport) -> Result<()> {
        let shader_src = std::fs::read_to_string(Path::new(&viewport.shader_path))?;
        let shader_module = self
            .device
            .create_shader_module(wgpu::ShaderModuleDescriptor {
                label: Some(&viewport.name),
                source: wgpu::ShaderSource::Wgsl(shader_src.into()),
            });

        let pipeline_layout =
            self.device
                .create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                    label: Some(&format!("{}_layout", viewport.name)),
                    bind_group_layouts: &[&self.bind_group_layout],
                    push_constant_ranges: &[],
                });

        let render_pipeline =
            self.device
                .create_render_pipeline(&wgpu::RenderPipelineDescriptor {
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
                            format: self.surface_config.format,
                            blend: Some(wgpu::BlendState::REPLACE),
                            write_mask: wgpu::ColorWrites::ALL,
                        })],
                        compilation_options: Default::default(),
                    }),
                    primitive: wgpu::PrimitiveState {
                        topology: wgpu::PrimitiveTopology::TriangleList,
                        strip_index_format: None,
                        front_face: wgpu::FrontFace::Ccw,
                        cull_mode: None,
                        polygon_mode: wgpu::PolygonMode::Fill,
                        unclipped_depth: false,
                        conservative: false,
                    },
                    depth_stencil: None,
                    multisample: wgpu::MultisampleState::default(),
                    multiview: None,
                    cache: None,
                });

        self.pipelines.push(ShaderPipeline {
            viewport,
            render_pipeline,
        });

        Ok(())
    }

    /// Update uniform buffer with new data.
    pub fn update_uniforms(&self, uniforms: &Uniforms) {
        self.queue
            .write_buffer(&self.uniform_buffer, 0, bytemuck::bytes_of(uniforms));
    }

    /// Update audio storage buffer: spectrum + stereo waveform.
    pub fn update_audio_buffer(&self, spectrum: &[f32], waveform_l: &[f32], waveform_r: &[f32]) {
        let mut buf = vec![0.0f32; AUDIO_BUFFER_SIZE];
        // [0..512): spectrum
        let spec_len = spectrum.len().min(SPECTRUM_SIZE);
        buf[..spec_len].copy_from_slice(&spectrum[..spec_len]);
        // [512..1024): waveform L
        let wl_len = waveform_l.len().min(WAVEFORM_SIZE);
        buf[SPECTRUM_SIZE..SPECTRUM_SIZE + wl_len].copy_from_slice(&waveform_l[..wl_len]);
        // [1024..1536): waveform R
        let wr_len = waveform_r.len().min(WAVEFORM_SIZE);
        buf[SPECTRUM_SIZE + WAVEFORM_SIZE..SPECTRUM_SIZE + WAVEFORM_SIZE + wr_len]
            .copy_from_slice(&waveform_r[..wr_len]);
        self.queue
            .write_buffer(&self.spectrum_buffer, 0, bytemuck::cast_slice(&buf));
    }

    /// Render all pipelines to the surface.
    pub fn render(&self) -> Result<()> {
        let output = self.surface.get_current_texture()?;
        let view = output
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());

        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("render"),
            });

        let fb_w = self.surface_config.width as f32;
        let fb_h = self.surface_config.height as f32;

        for pipeline in &self.pipelines {
            let vp = &pipeline.viewport;
            let x = (vp.rect[0] * fb_w) as u32;
            let y = (vp.rect[1] * fb_h) as u32;
            let w = (vp.rect[2] * fb_w) as u32;
            let h = (vp.rect[3] * fb_h) as u32;

            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some(&vp.name),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
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
            pass.set_bind_group(0, &self.bind_group, &[]);
            pass.draw(0..3, 0..1); // fullscreen triangle
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
