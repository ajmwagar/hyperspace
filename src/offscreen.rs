//! Reusable offscreen oscilloscope/scene renderer with an **injected** wgpu
//! device.
//!
//! This is the headless render core extracted from `examples/render.rs`. Unlike
//! the live engine (`src/renderer.rs`) and the example, `ScopeRenderer` does
//! **not** own a `Device`/`Queue`. The caller creates the device and passes it
//! (plus a target `TextureView`) into [`ScopeRenderer::render`]. This lets a
//! host compositor drive hyperspace as one layer among many on a single shared
//! GPU device.
//!
//! Audio buffer convention (matches `src/audio.rs` and the live engine):
//!   [0..512)     = FFT spectrum (log-scaled)
//!   [512..1024)  = waveform L
//!   [1024..1536) = waveform R

use crate::scene::{LayoutMode, SceneConfig, Viewport};
use crate::uniforms::Uniforms;
use std::path::Path;
use wgpu::util::DeviceExt;

const SPECTRUM_SIZE: usize = 512;
const WAVEFORM_SIZE: usize = 512;
/// Size of the audio buffer the shaders read (spectrum + waveform L + R).
pub const AUDIO_BUFFER_SIZE: usize = SPECTRUM_SIZE + WAVEFORM_SIZE * 2; // 1536
const STATE_BUFFER_SIZE: usize = 16384; // matches scripting::STATE_BUFFER_SIZE upper bound

/// One compiled pipeline (main shader + post chain) with its feedback textures.
struct Pipeline {
    main: wgpu::RenderPipeline,
    post: Vec<wgpu::RenderPipeline>,
    state_buffer: wgpu::Buffer,
    fb_textures: [wgpu::Texture; 2],
    fb_views: [wgpu::TextureView; 2],
    result_idx: usize,
}

/// Headless hyperspace scene renderer driven by a caller-owned device.
///
/// Construct once with [`ScopeRenderer::new`], then call
/// [`ScopeRenderer::render`] per frame with the audio buffer and a target view
/// to draw into. The renderer keeps internal ping-pong feedback textures (so
/// post-processing feedback chains look identical to the live engine) and blits
/// the final result into the caller's target on each frame.
pub struct ScopeRenderer {
    bgl: wgpu::BindGroupLayout,
    uniform_buf: wgpu::Buffer,
    audio_buf_gpu: wgpu::Buffer,
    sampler: wgpu::Sampler,
    pipeline: Pipeline,
    /// Blit pipeline: copies the result feedback texture into the caller target.
    blit: wgpu::RenderPipeline,
    blit_bgl: wgpu::BindGroupLayout,
    width: u32,
    height: u32,
}

impl ScopeRenderer {
    /// Build a scope renderer for the first usable viewport of `scene_path`.
    ///
    /// `assets_dir` is prepended to the (relative) shader paths in the scene
    /// toml; pass `Path::new(".")` for cwd-relative behavior. `format` is the
    /// format of the target view that [`render`](Self::render) will draw into.
    pub fn new(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        format: wgpu::TextureFormat,
        scene_path: &Path,
        assets_dir: &Path,
        width: u32,
        height: u32,
    ) -> anyhow::Result<Self> {
        let config = SceneConfig::load(scene_path)?;
        let vp = config
            .resolve_viewports(LayoutMode::ThreeOutput)
            .into_iter()
            .find(|v| v.name == "center")
            .or_else(|| {
                config
                    .resolve_viewports(LayoutMode::ThreeOutput)
                    .into_iter()
                    .next()
            })
            .ok_or_else(|| {
                anyhow::anyhow!("scene {} has no usable viewport", scene_path.display())
            })?;

        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            ..Default::default()
        });

        let bgl = bind_group_layout(device);

        let uniform_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("uniforms"),
            contents: bytemuck::bytes_of(&Uniforms {
                resolution: [width as f32, height as f32],
                ..Uniforms::default()
            }),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });

        let audio_buf_gpu = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("audio"),
            size: (AUDIO_BUFFER_SIZE * 4) as u64,
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        // The feedback textures always render in non-srgb RGBA; the blit pass
        // converts to whatever `format` the caller's target uses.
        let fb_format = wgpu::TextureFormat::Rgba8Unorm;
        let pipeline =
            build_pipeline(device, queue, fb_format, &bgl, &vp, assets_dir, width, height)?;

        let (blit_bgl, blit) = build_blit_pipeline(device, format);

        Ok(Self {
            bgl,
            uniform_buf,
            audio_buf_gpu,
            sampler,
            pipeline,
            blit,
            blit_bgl,
            width,
            height,
        })
    }

    /// Render one frame into `target`.
    ///
    /// `audio_buf` is the 1536-float spectrum+waveform buffer (see module docs);
    /// `time` is the scene time in seconds. The caller owns `target`'s viewport
    /// state — the scene fills the whole target. `uniforms_override` lets the
    /// caller supply the secondary band uniforms (amplitude/bass/mid/high); the
    /// resolution and time fields are set internally.
    pub fn render(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        target: &wgpu::TextureView,
        audio_buf: &[f32; AUDIO_BUFFER_SIZE],
        time: f32,
        bands: ScopeBands,
    ) {
        queue.write_buffer(&self.audio_buf_gpu, 0, bytemuck::cast_slice(audio_buf));

        let u = Uniforms {
            time,
            delta_time: 1.0 / 30.0,
            resolution: [self.width as f32, self.height as f32],
            amplitude: bands.amplitude,
            bass: bands.bass,
            mid: bands.mid,
            high: bands.high,
            amplitude_l: bands.amplitude,
            amplitude_r: bands.amplitude,
            ..Uniforms::default()
        };
        queue.write_buffer(&self.uniform_buf, 0, bytemuck::bytes_of(&u));

        render_frame(
            device,
            queue,
            &self.bgl,
            &self.uniform_buf,
            &self.audio_buf_gpu,
            &self.sampler,
            &mut self.pipeline,
        );

        // Blit the result feedback texture into the caller's target.
        let result_view = &self.pipeline.fb_views[self.pipeline.result_idx];
        let bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("blit_bg"),
            layout: &self.blit_bgl,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::Sampler(&self.sampler),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::TextureView(result_view),
                },
            ],
        });
        let mut enc = device.create_command_encoder(&Default::default());
        {
            let mut pass = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("blit"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: target,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Load,
                        store: wgpu::StoreOp::Store,
                    },
                })],
                ..Default::default()
            });
            pass.set_pipeline(&self.blit);
            pass.set_bind_group(0, &bg, &[]);
            pass.draw(0..3, 0..1);
        }
        queue.submit(std::iter::once(enc.finish()));
    }
}

/// Secondary band-energy uniforms (amplitude/bass/mid/high). These are derived
/// from the audio buffer by the caller; the scene look is driven mainly by the
/// audio buffer the shaders read directly.
#[derive(Clone, Copy, Default)]
pub struct ScopeBands {
    pub amplitude: f32,
    pub bass: f32,
    pub mid: f32,
    pub high: f32,
}

/// Render the main shader then the post chain into the feedback textures,
/// ping-ponging exactly like src/renderer.rs::render_with_overlay.
fn render_frame(
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    bgl: &wgpu::BindGroupLayout,
    uniform_buf: &wgpu::Buffer,
    audio_buf: &wgpu::Buffer,
    sampler: &wgpu::Sampler,
    pipeline: &mut Pipeline,
) {
    let make_bg = |read_view: &wgpu::TextureView| {
        device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: bgl,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: uniform_buf.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: audio_buf.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: pipeline.state_buffer.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 3,
                    resource: wgpu::BindingResource::Sampler(sampler),
                },
                wgpu::BindGroupEntry {
                    binding: 4,
                    resource: wgpu::BindingResource::TextureView(read_view),
                },
            ],
        })
    };

    // Main shader: reads fb[result_idx], writes fb[1-result_idx].
    let read_idx = pipeline.result_idx;
    let write_idx = 1 - read_idx;
    {
        let bg = make_bg(&pipeline.fb_views[read_idx]);
        let mut enc = device.create_command_encoder(&Default::default());
        let mut pass = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("main"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &pipeline.fb_views[write_idx],
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Load,
                    store: wgpu::StoreOp::Store,
                },
            })],
            ..Default::default()
        });
        pass.set_pipeline(&pipeline.main);
        pass.set_bind_group(0, &bg, &[]);
        pass.draw(0..3, 0..1);
        drop(pass);
        queue.submit(std::iter::once(enc.finish()));
    }

    // Post chain: ping-pong.
    let mut current = write_idx;
    for post in &pipeline.post {
        let post_read = current;
        let post_write = 1 - post_read;
        let bg = make_bg(&pipeline.fb_views[post_read]);
        let mut enc = device.create_command_encoder(&Default::default());
        let mut pass = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("post"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &pipeline.fb_views[post_write],
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Load,
                    store: wgpu::StoreOp::Store,
                },
            })],
            ..Default::default()
        });
        pass.set_pipeline(post);
        pass.set_bind_group(0, &bg, &[]);
        pass.draw(0..3, 0..1);
        drop(pass);
        queue.submit(std::iter::once(enc.finish()));
        current = post_write;
    }
    pipeline.result_idx = current;
}

#[allow(clippy::too_many_arguments)]
fn build_pipeline(
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    format: wgpu::TextureFormat,
    bgl: &wgpu::BindGroupLayout,
    vp: &Viewport,
    assets_dir: &Path,
    width: u32,
    height: u32,
) -> anyhow::Result<Pipeline> {
    let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: None,
        bind_group_layouts: &[bgl],
        push_constant_ranges: &[],
    });

    let make = |path: &str| -> anyhow::Result<wgpu::RenderPipeline> {
        let full = assets_dir.join(path);
        let src = std::fs::read_to_string(&full)
            .map_err(|e| anyhow::anyhow!("read shader {}: {}", full.display(), e))?;
        let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some(path),
            source: wgpu::ShaderSource::Wgsl(src.into()),
        });
        Ok(device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some(path),
            layout: Some(&layout),
            vertex: wgpu::VertexState {
                module: &module,
                entry_point: Some("vs_main"),
                buffers: &[],
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &module,
                entry_point: Some("fs_main"),
                targets: &[Some(wgpu::ColorTargetState {
                    format,
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
        }))
    };

    let main = make(&vp.shader_path)?;
    let post: Vec<_> = vp.post.iter().map(|p| make(p)).collect::<Result<_, _>>()?;

    let tex = |label: &str| {
        device.create_texture(&wgpu::TextureDescriptor {
            label: Some(label),
            size: wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                | wgpu::TextureUsages::TEXTURE_BINDING
                | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        })
    };
    let fb_a = tex("fb_a");
    let fb_b = tex("fb_b");
    let view_a = fb_a.create_view(&Default::default());
    let view_b = fb_b.create_view(&Default::default());

    let state_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("state"),
        contents: bytemuck::cast_slice(&vec![0.0f32; STATE_BUFFER_SIZE]),
        usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST,
    });

    // Clear both feedback textures so the first frames (LoadOp::Load) start black.
    {
        let mut enc = device.create_command_encoder(&Default::default());
        for v in [&view_a, &view_b] {
            enc.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("clear_fb"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: v,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                ..Default::default()
            });
        }
        queue.submit(std::iter::once(enc.finish()));
    }

    Ok(Pipeline {
        main,
        post,
        state_buffer,
        fb_textures: [fb_a, fb_b],
        fb_views: [view_a, view_b],
        result_idx: 0,
    })
}

/// A trivial fullscreen-triangle blit pipeline: samples one texture and writes
/// it to the target. Used to copy the result feedback texture into a
/// caller-provided target view (which may have a different format).
fn build_blit_pipeline(
    device: &wgpu::Device,
    format: wgpu::TextureFormat,
) -> (wgpu::BindGroupLayout, wgpu::RenderPipeline) {
    const BLIT_WGSL: &str = r#"
@group(0) @binding(0) var samp: sampler;
@group(0) @binding(1) var tex: texture_2d<f32>;

struct VsOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) vi: u32) -> VsOut {
    // Fullscreen triangle.
    var p = array<vec2<f32>, 3>(
        vec2<f32>(-1.0, -1.0),
        vec2<f32>( 3.0, -1.0),
        vec2<f32>(-1.0,  3.0),
    );
    var out: VsOut;
    let xy = p[vi];
    out.pos = vec4<f32>(xy, 0.0, 1.0);
    out.uv = vec2<f32>((xy.x + 1.0) * 0.5, 1.0 - (xy.y + 1.0) * 0.5);
    return out;
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    return textureSample(tex, samp, in.uv);
}
"#;

    let bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("blit_bgl"),
        entries: &[
            wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                count: None,
            },
            wgpu::BindGroupLayoutEntry {
                binding: 1,
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

    let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
        label: Some("blit"),
        source: wgpu::ShaderSource::Wgsl(BLIT_WGSL.into()),
    });
    let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: Some("blit_layout"),
        bind_group_layouts: &[&bgl],
        push_constant_ranges: &[],
    });
    let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: Some("blit"),
        layout: Some(&layout),
        vertex: wgpu::VertexState {
            module: &module,
            entry_point: Some("vs_main"),
            buffers: &[],
            compilation_options: Default::default(),
        },
        fragment: Some(wgpu::FragmentState {
            module: &module,
            entry_point: Some("fs_main"),
            targets: &[Some(wgpu::ColorTargetState {
                format,
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

    (bgl, pipeline)
}

fn bind_group_layout(device: &wgpu::Device) -> wgpu::BindGroupLayout {
    device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("render_bgl"),
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
    })
}
