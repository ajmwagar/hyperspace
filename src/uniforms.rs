use bytemuck::{Pod, Zeroable};

/// Matches the WGSL Uniforms struct exactly.
/// Must be kept in sync with shaders.
#[repr(C)]
#[derive(Debug, Copy, Clone, Pod, Zeroable)]
pub struct Uniforms {
    pub time: f32,
    pub delta_time: f32,
    pub resolution: [f32; 2],
    pub amplitude: f32,
    pub beat: f32,
    pub bass: f32,
    pub mid: f32,
    pub high: f32,
    pub _pad0: [f32; 3], // align cv to 16 bytes
    pub cv: [f32; 8],
    pub scene_id: u32,
    pub _pad1: [f32; 3], // pad to 16-byte alignment
}

impl Uniforms {
    pub const SIZE: usize = std::mem::size_of::<Self>();
}

impl Default for Uniforms {
    fn default() -> Self {
        Self {
            time: 0.0,
            delta_time: 0.0,
            resolution: [1920.0, 1080.0],
            amplitude: 0.0,
            beat: 0.0,
            bass: 0.0,
            mid: 0.0,
            high: 0.0,
            _pad0: [0.0; 3],
            cv: [0.0; 8],
            scene_id: 0,
            _pad1: [0.0; 3],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uniforms_size_is_16_byte_aligned() {
        assert_eq!(Uniforms::SIZE % 16, 0, "Uniforms must be 16-byte aligned for wgpu");
    }

    #[test]
    fn uniforms_field_offsets() {
        // Verify the layout matches what WGSL expects
        use std::mem::offset_of;
        assert_eq!(offset_of!(Uniforms, time), 0);
        assert_eq!(offset_of!(Uniforms, delta_time), 4);
        assert_eq!(offset_of!(Uniforms, resolution), 8);
        assert_eq!(offset_of!(Uniforms, amplitude), 16);
        assert_eq!(offset_of!(Uniforms, beat), 20);
        assert_eq!(offset_of!(Uniforms, bass), 24);
        assert_eq!(offset_of!(Uniforms, mid), 28);
        assert_eq!(offset_of!(Uniforms, high), 32);
        // _pad0 at 36..48
        assert_eq!(offset_of!(Uniforms, cv), 48);
        // cv is 8 * 4 = 32 bytes, so scene_id at 80
        assert_eq!(offset_of!(Uniforms, scene_id), 80);
    }

    #[test]
    fn uniforms_bytemuck_roundtrip() {
        let u = Uniforms {
            time: 1.5,
            delta_time: 0.016,
            resolution: [1920.0, 1080.0],
            amplitude: 0.7,
            beat: 1.0,
            bass: 0.3,
            mid: 0.5,
            high: 0.1,
            cv: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8],
            scene_id: 42,
            ..Default::default()
        };
        let bytes = bytemuck::bytes_of(&u);
        let u2: &Uniforms = bytemuck::from_bytes(bytes);
        assert_eq!(u2.time, 1.5);
        assert_eq!(u2.resolution, [1920.0, 1080.0]);
        assert_eq!(u2.cv[7], 0.8);
        assert_eq!(u2.scene_id, 42);
    }

    #[test]
    fn default_uniforms() {
        let u = Uniforms::default();
        assert_eq!(u.time, 0.0);
        assert_eq!(u.amplitude, 0.0);
        assert_eq!(u.resolution, [1920.0, 1080.0]);
        assert_eq!(u.cv, [0.0; 8]);
    }
}
