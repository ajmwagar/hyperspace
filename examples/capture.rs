//! Headless GIF capture of each shader.
//! Usage: cargo run --example capture --features capture
//!
//! Renders 60 frames of each shader at 768x768 and saves as GIF in assets/.

use gif::{Encoder, Frame, Repeat};
use std::fs;
use wgpu::util::DeviceExt;

const SIZE: u32 = 768;
const FRAMES: u32 = 60;
const FRAME_DELAY: u16 = 3; // centiseconds (3 = ~33fps)

// Minimal uniforms matching the WGSL struct (128 bytes)
#[repr(C)]
#[derive(Copy, Clone, bytemuck::Pod, bytemuck::Zeroable)]
struct Uniforms {
    time: f32,
    delta_time: f32,
    resolution: [f32; 2],
    amplitude: f32,
    beat: f32,
    bass: f32,
    mid: f32,
    high: f32,
    _pad0: [f32; 3],
    cv: [f32; 8],
    scene_id: u32,
    amplitude_l: f32,
    amplitude_r: f32,
    bass_l: f32,
    bass_r: f32,
    mid_l: f32,
    mid_r: f32,
    high_l: f32,
    high_r: f32,
    _pad1: [f32; 3],
}

fn main() {
    env_logger::init();
    pollster::block_on(run());
}

async fn run() {
    fs::create_dir_all("assets").unwrap();

    let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor::default());
    let adapter = instance
        .request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            ..Default::default()
        })
        .await
        .expect("no GPU adapter");

    let (device, queue) = adapter
        .request_device(&wgpu::DeviceDescriptor::default())
        .await
        .unwrap();

    let format = wgpu::TextureFormat::Rgba8UnormSrgb;

    // Find all non-post shaders
    let mut shaders: Vec<_> = fs::read_dir("shaders")
        .unwrap()
        .filter_map(|e| e.ok())
        .filter(|e| {
            e.path().extension().is_some_and(|ext| ext == "wgsl")
                && !e.path().to_string_lossy().contains("post/")
        })
        .map(|e| e.path())
        .collect();
    shaders.sort();

    let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
        mag_filter: wgpu::FilterMode::Linear,
        min_filter: wgpu::FilterMode::Linear,
        ..Default::default()
    });

    let dummy_tex = device.create_texture(&wgpu::TextureDescriptor {
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
        dummy_tex.as_image_copy(),
        &[0u8, 0, 0, 255],
        wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(4), rows_per_image: None },
        wgpu::Extent3d { width: 1, height: 1, depth_or_array_layers: 1 },
    );
    let dummy_view = dummy_tex.create_view(&Default::default());

    let bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: None,
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

    for shader_path in &shaders {
        let name = shader_path.file_stem().unwrap().to_string_lossy();
        println!("capturing {}...", name);

        let src = fs::read_to_string(shader_path).unwrap();
        let uses_feedback = src.contains("prev_frame");
        let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some(&name),
            source: wgpu::ShaderSource::Wgsl(src.into()),
        });

        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: None,
            bind_group_layouts: &[&bgl],
            push_constant_ranges: &[],
        });

        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some(&name),
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
            primitive: wgpu::PrimitiveState { topology: wgpu::PrimitiveTopology::TriangleList, ..Default::default() },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview: None,
            cache: None,
        });

        // Feedback textures for shaders that need prev_frame
        let fb_textures: Option<[wgpu::Texture; 2]> = if uses_feedback {
            Some([
                create_render_texture(&device, format),
                create_render_texture(&device, format),
            ])
        } else {
            None
        };

        // Render target (non-feedback shaders render directly here)
        let render_target = create_render_texture(&device, format);
        let render_view = render_target.create_view(&Default::default());

        // Readback buffer
        let bytes_per_row = align_to(SIZE * 4, 256);
        let readback = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("readback"),
            size: (bytes_per_row * SIZE) as u64,
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });

        // Simulated audio buffer with a sine waveform
        let mut audio_data = vec![0.0f32; 1536];
        for i in 0..512 {
            audio_data[i] = ((i as f32 / 512.0) * 0.5).min(1.0); // fake spectrum ramp
            audio_data[512 + i] = (i as f32 * 0.05).sin() * 0.5; // fake waveform L
            audio_data[1024 + i] = (i as f32 * 0.05 + 0.5).sin() * 0.5; // fake waveform R
        }
        let audio_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("audio"),
            contents: bytemuck::cast_slice(&audio_data),
            usage: wgpu::BufferUsages::STORAGE,
        });
        let state_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("state"),
            contents: bytemuck::cast_slice(&vec![0.0f32; 16384]),
            usage: wgpu::BufferUsages::STORAGE,
        });

        let uniform_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("uniforms"),
            contents: bytemuck::bytes_of(&Uniforms {
                resolution: [SIZE as f32, SIZE as f32],
                ..bytemuck::Zeroable::zeroed()
            }),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });

        let gif_path = format!("assets/{}.gif", name);
        let mut gif_file = fs::File::create(&gif_path).unwrap();
        let mut encoder = Encoder::new(&mut gif_file, SIZE as u16, SIZE as u16, &[]).unwrap();
        encoder.set_repeat(Repeat::Infinite).unwrap();

        let mut fb_idx = 0usize;

        for frame_idx in 0..FRAMES {
            let time = frame_idx as f32 / 30.0;
            let beat = if frame_idx % 30 < 3 { 1.0 } else { 0.0 };
            let uniforms = Uniforms {
                time,
                delta_time: 1.0 / 30.0,
                resolution: [SIZE as f32, SIZE as f32],
                amplitude: 0.4 + 0.3 * (time * 2.0).sin(),
                beat,
                bass: 0.3 + 0.2 * (time * 1.5).sin(),
                mid: 0.2 + 0.15 * (time * 2.5).sin(),
                high: 0.1 + 0.1 * (time * 4.0).sin(),
                amplitude_l: 0.35 + 0.25 * (time * 2.0).sin(),
                amplitude_r: 0.35 + 0.25 * (time * 2.0 + 0.5).sin(),
                bass_l: 0.3 + 0.2 * (time * 1.5).sin(),
                bass_r: 0.3 + 0.2 * (time * 1.5 + 0.3).sin(),
                ..bytemuck::Zeroable::zeroed()
            };
            queue.write_buffer(&uniform_buf, 0, bytemuck::bytes_of(&uniforms));

            let target_view;
            let prev_view;

            if let Some(ref fb) = fb_textures {
                let write_idx = fb_idx;
                let read_idx = 1 - fb_idx;
                target_view = fb[write_idx].create_view(&Default::default());
                prev_view = fb[read_idx].create_view(&Default::default());
                fb_idx = read_idx;
            } else {
                target_view = render_target.create_view(&Default::default());
                prev_view = dummy_tex.create_view(&Default::default());
            };

            let bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: None,
                layout: &bgl,
                entries: &[
                    wgpu::BindGroupEntry { binding: 0, resource: uniform_buf.as_entire_binding() },
                    wgpu::BindGroupEntry { binding: 1, resource: audio_buf.as_entire_binding() },
                    wgpu::BindGroupEntry { binding: 2, resource: state_buf.as_entire_binding() },
                    wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::Sampler(&sampler) },
                    wgpu::BindGroupEntry { binding: 4, resource: wgpu::BindingResource::TextureView(&prev_view) },
                ],
            });

            let mut encoder_gpu = device.create_command_encoder(&Default::default());
            {
                let mut pass = encoder_gpu.begin_render_pass(&wgpu::RenderPassDescriptor {
                    label: None,
                    color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                        view: &target_view,
                        resolve_target: None,
                        ops: wgpu::Operations {
                            load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                            store: wgpu::StoreOp::Store,
                        },
                    })],
                    ..Default::default()
                });
                pass.set_pipeline(&pipeline);
                pass.set_bind_group(0, &bg, &[]);
                pass.draw(0..3, 0..1);
            }

            // Copy to readback
            let copy_src = if fb_textures.is_some() {
                &fb_textures.as_ref().unwrap()[1 - fb_idx] // the one we just wrote to
            } else {
                &render_target
            };
            encoder_gpu.copy_texture_to_buffer(
                copy_src.as_image_copy(),
                wgpu::TexelCopyBufferInfo {
                    buffer: &readback,
                    layout: wgpu::TexelCopyBufferLayout {
                        offset: 0,
                        bytes_per_row: Some(bytes_per_row),
                        rows_per_image: Some(SIZE),
                    },
                },
                wgpu::Extent3d { width: SIZE, height: SIZE, depth_or_array_layers: 1 },
            );

            queue.submit(std::iter::once(encoder_gpu.finish()));

            // Map and read pixels
            let slice = readback.slice(..);
            let (tx, rx) = std::sync::mpsc::channel();
            slice.map_async(wgpu::MapMode::Read, move |result| { tx.send(result).unwrap(); });
            device.poll(wgpu::PollType::Wait).unwrap();
            rx.recv().unwrap().unwrap();

            let data = slice.get_mapped_range();
            let mut pixels = vec![0u8; (SIZE * SIZE * 4) as usize];
            for row in 0..SIZE {
                let src_start = (row * bytes_per_row) as usize;
                let dst_start = (row * SIZE * 4) as usize;
                let row_bytes = (SIZE * 4) as usize;
                pixels[dst_start..dst_start + row_bytes]
                    .copy_from_slice(&data[src_start..src_start + row_bytes]);
            }
            drop(data);
            readback.unmap();

            // Quantize to a 256-colour palette with NeuQuant. This handles
            // smooth gradients and colourful frames far better than a naive
            // first-256-colours scan (which collapsed extra colours into one).
            let nq = color_quant::NeuQuant::new(10, 256, &pixels);
            let palette = nq.color_map_rgb();
            let mut indexed = vec![0u8; (SIZE * SIZE) as usize];
            for i in 0..(SIZE * SIZE) as usize {
                indexed[i] = nq.index_of(&pixels[i * 4..i * 4 + 4]) as u8;
            }

            let mut frame = Frame::default();
            frame.width = SIZE as u16;
            frame.height = SIZE as u16;
            frame.delay = FRAME_DELAY;
            frame.buffer = std::borrow::Cow::Borrowed(&indexed);
            frame.palette = Some(palette);
            encoder.write_frame(&frame).unwrap();
        }

        println!("  saved {}", gif_path);
    }

    // Generate GALLERY.md
    println!("generating assets/GALLERY.md...");
    let mut md = String::from("<!-- Auto-generated by: cargo run --example capture --features capture -->\n\n");
    md.push_str("<table>\n");

    let cols = 3;
    for (i, shader_path) in shaders.iter().enumerate() {
        let name = shader_path.file_stem().unwrap().to_string_lossy();
        let src = fs::read_to_string(shader_path).unwrap_or_default();
        // Extract description from first comment line
        let desc = src.lines()
            .find(|l| l.starts_with("//"))
            .map(|l| l.trim_start_matches('/').trim())
            .unwrap_or("");
        let short_desc = desc.split('—').nth(1).unwrap_or(desc).trim();
        let short_desc = if short_desc.len() > 40 { &short_desc[..40] } else { short_desc };

        if i % cols == 0 { md.push_str("<tr>\n"); }
        md.push_str(&format!(
            "<td><img src=\"{}.gif\" width=\"200\"><br><b>{}</b><br>{}</td>\n",
            name, name, short_desc
        ));
        if i % cols == cols - 1 || i == shaders.len() - 1 { md.push_str("</tr>\n"); }
    }

    md.push_str("</table>\n");
    fs::write("assets/GALLERY.md", &md).unwrap();
    println!("done! GIFs saved to assets/, gallery at assets/GALLERY.md");
}

fn create_render_texture(device: &wgpu::Device, format: wgpu::TextureFormat) -> wgpu::Texture {
    device.create_texture(&wgpu::TextureDescriptor {
        label: Some("render_target"),
        size: wgpu::Extent3d { width: SIZE, height: SIZE, depth_or_array_layers: 1 },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT
            | wgpu::TextureUsages::TEXTURE_BINDING
            | wgpu::TextureUsages::COPY_SRC,
        view_formats: &[],
    })
}

fn align_to(value: u32, alignment: u32) -> u32 {
    (value + alignment - 1) / alignment * alignment
}
