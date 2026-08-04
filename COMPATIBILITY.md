# Compatibility matrix

Which versions of each layer are known to work together. Update this in the same PR that changes
any pinned version.

## Software

| Component | Version | Notes |
|---|---|---|
| LeRobot | 0.5.2 | Editable install from fork; see ADR-0002 |
| Python | 3.13.5 | |
| PyTorch | 2.10.0 | |
| ffmpeg | 8.0.1 | Needs `libsvtav1` for dataset video encoding |
| feetech-servo-sdk | 1.0.0 | Provides `scservo_sdk`; required for any servo communication |
| pynput | 1.8.2 | LeRobot 0.5.2 requires `>=1.7.8,<1.9.0` |
| rerun-sdk | 0.26.2 | LeRobot 0.5.2 requires `>=0.24.0,<0.27.0` |
| torchcodec | not yet installed | Needed to read datasets back; version constrained by PyTorch |

## Hardware

| Item | Revision | Firmware | Notes |
|---|---|---|---|
| SO-101 follower | stock | Feetech STS3215 | 12V supply. Motors C001 / C018 / C047, 1:345 |
| SO-101 leader | stock | Feetech STS3215 | 5V supply. Motors C044 (1:191) / C001 (1:345) / C046 (1:147) |
| AnySkin | not yet built | - | 5x MLX90393 over I2C, read by Adafruit QT Py |

Board revision is encoded into firmware so a mismatch is detectable at runtime rather than
inferred from symptoms.

## Dataset schema

`meta/info.json` carries a `codebase_version` that must match the LeRobot version reading the
dataset. Datasets are published with their environment recorded alongside.
