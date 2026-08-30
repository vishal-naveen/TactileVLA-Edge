# Changelog

All notable changes to this project are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Phase 2 complete — vision-only baseline.** 160-episode dataset, ACT and SmolVLA-450M
  trained and evaluated on the physical arm. Results, protocol, and limits in
  [`docs/results.md`](docs/results.md).
- `tactilevla-gridfig.py`: renders the workspace grid figure from the recording session's own
  geometry and cell log, so published figures cannot drift from what was recorded.
- `docs/media/`: demonstration footage, observation streams, and the workspace figure.
- Repository skeleton: `software/`, `firmware/`, `hardware/`, `docs/`, `tests/`.
- ADR-0001 (record architecture decisions) and ADR-0002 (pin LeRobot).
- SO-101 bring-up guide covering the 12V/5V hazard, motor IDs, calibration, teleoperation.
- CI gate: lint and test on every push and pull request.
- License split: Apache-2.0 for code, CERN-OHL-P v2 for hardware.

### Changed
- README now leads with measured results instead of a pre-alpha notice, and states explicitly
  that the tactile layer is not built.
- Touch sensing plan moved from an AnySkin magnetic sensor (never built) to servo load
  (`Present_Load`, STS3215 register 60), which requires no additional hardware.
- `COMPATIBILITY.md`: torchcodec and PyAV pinned to installed versions.
