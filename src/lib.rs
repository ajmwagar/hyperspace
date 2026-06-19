//! Hyperspace: audio-reactive video synthesis engine for CRT displays.
//!
//! Most of this crate is the live engine driven by `src/main.rs`. The
//! [`offscreen`] module exposes a reusable, **device-injected** headless scope
//! renderer ([`offscreen::ScopeRenderer`]) so a host compositor can drive
//! hyperspace as one layer on a shared wgpu device.

pub mod audio;
pub mod clips;
pub mod control;
pub mod cv;
pub mod offscreen;
pub mod renderer;
pub mod scene;
pub mod scripting;
pub mod text;
pub mod uniforms;
pub mod video;

pub use offscreen::{ScopeBands, ScopeRenderer, AUDIO_BUFFER_SIZE};
