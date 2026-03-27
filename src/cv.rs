use anyhow::Result;
use std::sync::{Arc, Mutex};

const NUM_CHANNELS: usize = 8;

/// Eurorack CV levels scaled to 0.0..1.0
pub type CvData = [f32; NUM_CHANNELS];
pub type SharedCvData = Arc<Mutex<CvData>>;

pub fn new_shared() -> SharedCvData {
    Arc::new(Mutex::new([0.0; NUM_CHANNELS]))
}

/// Start reading CV from MCP3008 ADC over SPI.
/// On non-Linux platforms, returns a no-op (all zeros).
#[cfg(target_os = "linux")]
pub fn start_cv_reader(shared: SharedCvData) -> Result<()> {
    use rppal::spi::{Bus, Mode, SlaveSelect, Spi};

    let spi = Spi::new(Bus::Spi0, SlaveSelect::Ss0, 1_000_000, Mode::Mode0)?;

    std::thread::Builder::new()
        .name("cv-reader".into())
        .spawn(move || {
            loop {
                let mut channels = [0.0f32; NUM_CHANNELS];
                for ch in 0..NUM_CHANNELS {
                    match read_mcp3008(&spi, ch as u8) {
                        Ok(raw) => {
                            // MCP3008 is 10-bit (0..1023)
                            // Eurorack is typically -5V to +5V or 0-10V
                            // We normalize to 0.0..1.0
                            channels[ch] = raw as f32 / 1023.0;
                        }
                        Err(e) => {
                            log::warn!("cv read error ch{}: {}", ch, e);
                        }
                    }
                }
                *shared.lock().unwrap() = channels;
                std::thread::sleep(std::time::Duration::from_millis(2)); // ~500Hz polling
            }
        })?;

    Ok(())
}

#[cfg(target_os = "linux")]
fn read_mcp3008(spi: &rppal::spi::Spi, channel: u8) -> Result<u16> {
    use rppal::spi::Spi;

    // MCP3008 protocol: send [0x01, (0x80 | channel<<4), 0x00]
    // Response: ignore first byte, bits 1-0 of second byte + full third byte = 10-bit value
    let tx = [0x01, 0x80 | ((channel & 0x07) << 4), 0x00];
    let mut rx = [0u8; 3];

    Spi::transfer(spi, &mut rx, &tx)?;

    let value = (((rx[1] & 0x03) as u16) << 8) | rx[2] as u16;
    Ok(value)
}

#[cfg(not(target_os = "linux"))]
pub fn start_cv_reader(_shared: SharedCvData) -> Result<()> {
    log::info!("CV input disabled (not running on Linux/Pi)");
    Ok(())
}
