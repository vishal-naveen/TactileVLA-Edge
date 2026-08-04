# firmware/

Microcontroller code.

- **AnySkin readout** — Adafruit QT Py (USB-C) reading 5x MLX90393 triaxial magnetometers over
  I2C via Qwiic, 15 channels total (Bx/By/Bz per sensor), streaming at 100 Hz or better.
- **Custom PCB** — a later STM32-based consolidation of the above.

Firmware encodes its target board revision so a firmware/board mismatch is detectable at runtime.
See [COMPATIBILITY.md](../COMPATIBILITY.md).

## Known weakness

Magnetic tactile sensing degrades near ferromagnetic objects — which is exactly the case in metal
connector insertion, one of the target tasks. Mitigation is baseline subtraction with frequent
re-zeroing. If that proves insufficient, the fallback is a visuotactile fingertip, which is an
optical rather than magnetic approach.

Licensed Apache-2.0.
