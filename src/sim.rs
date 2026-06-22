//! Shared multi-buffer simulation pipeline — the `sim` feature.
//!
//! ONE implementation, used by both the live renderer (`renderer.rs`) and the
//! headless `offscreen.rs`, so the on-stage path and the offline-render path
//! behave identically.
//!
//! A viewport may declare ordered, persistent simulation buffers
//! (`[[<viewport>.buffer]]`). Each frame, before the display shader runs, every
//! buffer's sim shader is executed `steps` times (ping-ponged), reading the
//! other buffers + audio + uniforms. The display/post shaders then sample the
//! buffers at bind slots 5..8. Buffers are float (rgba16f by default) so they
//! can hold real simulation state (wave height, velocity, dye, …).
//!
//! Bind-group layout (canonical, shared by all pipelines):
//!   0 uniforms · 1 audio · 2 lua state · 3 sampler · 4 prev_frame
//!   5..8 simulation buffers (only in `sim` builds; dummy-bound when unused)

/// Canonical bind-group layout for every render/sim/post pipeline. In `sim`
/// builds it additionally exposes the four simulation-buffer texture slots.
pub fn bind_group_layout(device: &wgpu::Device) -> wgpu::BindGroupLayout {
    let tex = |binding: u32| wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Texture {
            sample_type: wgpu::TextureSampleType::Float { filterable: true },
            view_dimension: wgpu::TextureViewDimension::D2,
            multisampled: false,
        },
        count: None,
    };
    let mut entries = vec![
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
        tex(4),
    ];
    #[cfg(feature = "sim")]
    {
        entries.push(tex(5));
        entries.push(tex(6));
        entries.push(tex(7));
        entries.push(tex(8));
    }
    device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("render_bgl"),
        entries: &entries,
    })
}

/// Number of simulation-buffer slots (bindings 5..8).
pub const MAX_BUFFERS: usize = 4;

#[cfg(feature = "sim")]
pub use chain::SimChain;

#[cfg(feature = "sim")]
mod chain {
    use crate::scene::BufferConfig;
    use std::path::Path;

    fn parse_format(s: &str) -> wgpu::TextureFormat {
        match s {
            "rgba32f" => wgpu::TextureFormat::Rgba32Float,
            "r32f" => wgpu::TextureFormat::R32Float,
            _ => wgpu::TextureFormat::Rgba16Float, // default, filterable everywhere
        }
    }
    fn parse_wrap(s: &str) -> wgpu::AddressMode {
        match s {
            "repeat" => wgpu::AddressMode::Repeat,
            "mirror" => wgpu::AddressMode::MirrorRepeat,
            _ => wgpu::AddressMode::ClampToEdge,
        }
    }

    struct SimBuffer {
        pipeline: wgpu::RenderPipeline,
        view: [wgpu::TextureView; 2],
        _tex: [wgpu::Texture; 2],
        sampler: wgpu::Sampler,
        steps: u32,
    }

    /// All simulation buffers for one viewport. Empty chains are valid (they
    /// just hand back dummy views so the 5..8 slots can always be bound).
    pub struct SimChain {
        buffers: Vec<SimBuffer>,
        reads: Vec<usize>,
        dummy: wgpu::TextureView,
    }

    impl SimChain {
        /// Build the chain for `specs` (may be empty). `bgl` is the canonical
        /// layout from [`super::bind_group_layout`]; shaders are resolved
        /// relative to `assets_dir`.
        pub fn new(
            device: &wgpu::Device,
            bgl: &wgpu::BindGroupLayout,
            specs: &[BufferConfig],
            base_w: u32,
            base_h: u32,
            assets_dir: &Path,
        ) -> anyhow::Result<Self> {
            let dummy_tex = device.create_texture(&wgpu::TextureDescriptor {
                label: Some("sim_dummy"),
                size: wgpu::Extent3d { width: 1, height: 1, depth_or_array_layers: 1 },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Rgba16Float,
                usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::RENDER_ATTACHMENT,
                view_formats: &[],
            });
            let dummy = dummy_tex.create_view(&Default::default());

            let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("sim_pipeline_layout"),
                bind_group_layouts: &[bgl],
                push_constant_ranges: &[],
            });

            let mut buffers = Vec::new();
            let mut reads = Vec::new();
            for spec in specs.iter().take(super::MAX_BUFFERS) {
                let format = parse_format(&spec.format);
                let w = ((base_w as f32 * spec.scale) as u32).max(2);
                let h = ((base_h as f32 * spec.scale) as u32).max(2);

                let src_path = assets_dir.join(&spec.shader);
                let src = std::fs::read_to_string(&src_path)
                    .map_err(|e| anyhow::anyhow!("read sim shader {}: {}", src_path.display(), e))?;
                let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
                    label: Some(&spec.name),
                    source: wgpu::ShaderSource::Wgsl(src.into()),
                });
                let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                    label: Some(&spec.name),
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

                let make_tex = || {
                    device.create_texture(&wgpu::TextureDescriptor {
                        label: Some(&spec.name),
                        size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
                        mip_level_count: 1,
                        sample_count: 1,
                        dimension: wgpu::TextureDimension::D2,
                        format,
                        usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                            | wgpu::TextureUsages::TEXTURE_BINDING,
                        view_formats: &[],
                    })
                };
                let t0 = make_tex();
                let t1 = make_tex();
                let v0 = t0.create_view(&Default::default());
                let v1 = t1.create_view(&Default::default());
                let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
                    label: Some(&spec.name),
                    mag_filter: wgpu::FilterMode::Linear,
                    min_filter: wgpu::FilterMode::Linear,
                    address_mode_u: parse_wrap(&spec.wrap),
                    address_mode_v: parse_wrap(&spec.wrap),
                    ..Default::default()
                });

                buffers.push(SimBuffer {
                    pipeline,
                    view: [v0, v1],
                    _tex: [t0, t1],
                    sampler,
                    steps: spec.steps.max(1),
                });
                reads.push(0);
            }

            Ok(Self { buffers, reads, dummy })
        }

        pub fn is_empty(&self) -> bool {
            self.buffers.is_empty()
        }

        /// Current read view of each slot 5..8 (dummy where unused), for the
        /// caller to bind into the display/post bind groups.
        pub fn read_views(&self) -> [&wgpu::TextureView; super::MAX_BUFFERS] {
            let mut v: [&wgpu::TextureView; super::MAX_BUFFERS] = [&self.dummy; super::MAX_BUFFERS];
            for (k, b) in self.buffers.iter().enumerate() {
                v[k] = &b.view[self.reads[k]];
            }
            v
        }

        /// Run every buffer's sim passes for this frame. Shared bind resources
        /// (uniforms/audio/state) are supplied by the caller; slot 4
        /// (prev_frame) is bound to an internal dummy since sims don't use it.
        #[allow(clippy::too_many_arguments)]
        pub fn step(
            &mut self,
            device: &wgpu::Device,
            queue: &wgpu::Queue,
            bgl: &wgpu::BindGroupLayout,
            uniform: &wgpu::Buffer,
            audio: &wgpu::Buffer,
            state: &wgpu::Buffer,
        ) {
            for i in 0..self.buffers.len() {
                for _ in 0..self.buffers[i].steps {
                    let target_idx = 1 - self.reads[i];

                    // Read views for slots 5..8 (this buffer reads its own
                    // previous = its current read view).
                    let mut bv: [&wgpu::TextureView; super::MAX_BUFFERS] =
                        [&self.dummy; super::MAX_BUFFERS];
                    for (k, b) in self.buffers.iter().enumerate() {
                        bv[k] = &b.view[self.reads[k]];
                    }

                    let bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
                        label: Some("sim_bg"),
                        layout: bgl,
                        entries: &[
                            wgpu::BindGroupEntry { binding: 0, resource: uniform.as_entire_binding() },
                            wgpu::BindGroupEntry { binding: 1, resource: audio.as_entire_binding() },
                            wgpu::BindGroupEntry { binding: 2, resource: state.as_entire_binding() },
                            wgpu::BindGroupEntry {
                                binding: 3,
                                resource: wgpu::BindingResource::Sampler(&self.buffers[i].sampler),
                            },
                            wgpu::BindGroupEntry { binding: 4, resource: wgpu::BindingResource::TextureView(&self.dummy) },
                            wgpu::BindGroupEntry { binding: 5, resource: wgpu::BindingResource::TextureView(bv[0]) },
                            wgpu::BindGroupEntry { binding: 6, resource: wgpu::BindingResource::TextureView(bv[1]) },
                            wgpu::BindGroupEntry { binding: 7, resource: wgpu::BindingResource::TextureView(bv[2]) },
                            wgpu::BindGroupEntry { binding: 8, resource: wgpu::BindingResource::TextureView(bv[3]) },
                        ],
                    });

                    let mut enc = device.create_command_encoder(&Default::default());
                    {
                        let mut pass = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
                            label: Some("sim_pass"),
                            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                                view: &self.buffers[i].view[target_idx],
                                resolve_target: None,
                                ops: wgpu::Operations {
                                    load: wgpu::LoadOp::Load,
                                    store: wgpu::StoreOp::Store,
                                },
                            })],
                            ..Default::default()
                        });
                        pass.set_pipeline(&self.buffers[i].pipeline);
                        pass.set_bind_group(0, &bg, &[]);
                        pass.draw(0..3, 0..1);
                    }
                    queue.submit(std::iter::once(enc.finish()));
                    self.reads[i] = target_idx;
                }
            }
        }

        /// Clear all buffer textures to black. Call once after `new` (the
        /// caller owns the queue).
        pub fn clear(&self, device: &wgpu::Device, queue: &wgpu::Queue) {
            let mut enc = device.create_command_encoder(&Default::default());
            for b in &self.buffers {
                for v in &b.view {
                    enc.begin_render_pass(&wgpu::RenderPassDescriptor {
                        label: Some("sim_clear"),
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
            }
            queue.submit(std::iter::once(enc.finish()));
        }
    }
}
