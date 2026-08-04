# TactileVLA-Edge

An open-source tactile vision-language-action (VLA) stack for contact-rich robot manipulation
on sub-$1,000 hardware, with on-device inference.

> **Status: pre-alpha.** Hardware bring-up in progress. Nothing here is usable yet.

## What this is

Tactile VLA models exist, but the published work runs on ~$30k research arms. This project aims
to be a **complete, reproducible, open-source tactile-VLA reference stack that runs on hardware
costing under $1,000** — the arm, the skin, the dataset format, the fusion method, and the
measured results, all in one place.

To be precise about the claim: this is *not* the first tactile-VLA. Tactile-VLA, TacVLA, and
TacFiLM came first. The contribution here is the integration at the low-cost end, plus a
tactile fusion recipe inside a 450M-parameter backbone that has not been shown before.

## Hardware

| Layer | Component |
|---|---|
| Arm | SO-101 leader + follower, Feetech STS3215 servos |
| Touch | AnySkin magnetic tactile sensor (5x MLX90393, 15 channels) |
| Policy | SmolVLA-450M, fine-tuned via LeRobot |
| Compute | RTX 3060 for training; Jetson Orin Nano target for on-device inference |
| Fusion | FiLM conditioning, with token-concat as the plumbing-proving first step |

## Repository layout

```
software/    Host-side code: tactile sync layer, dataset tooling, fusion, eval harness
firmware/    Microcontroller code: AnySkin readout (QT Py), later custom STM32
hardware/    CAD, STLs, PCB sources, BOMs
docs/        ADRs, engineering log, guides
tests/       Test suite (CI gates every PR)
```

## Where the actual work is

Roughly 80% of the parts are pre-made: SO-101 STLs and assembly docs, AnySkin's PCB and
firmware, pretrained SmolVLA, the LeRobot pipeline. Assembling that feels productive and fast.

The remaining 20% is the project:

- **Time-synchronized tactile streaming** into the LeRobot dataset format. Cameras run ~30 fps,
  servos ~30-50 Hz, AnySkin ~100 Hz. An 80 ms misalignment trains a correlation that isn't real
  and fails in ways that are very hard to debug.
- **FiLM-style tactile fusion** inside SmolVLA's backbone.
- **Honest measurement** of whether touch beats vision on cheap hardware, with enough trials to
  distinguish signal from noise.

That 20% is slower and harder than the 80%, and it is where both the value and the risk live.

## Flagship demo

"Plug the USB into the laptop" — a task that should succeed with touch and fail without it,
because the gripper occludes the camera at exactly the moment contact matters.

## Getting started

Hardware bring-up (ports → motors → calibration → teleoperation) is documented in
[`docs/bringup.md`](docs/bringup.md).

## Roadmap

| Phase | Goal |
|---|---|
| 0 | Repo, environment, pipeline validated on a public dataset |
| 1 | Arm bring-up — leader mirrors follower |
| 2 | Vision-only baseline — ACT, then SmolVLA, autonomous pick-and-place |
| 3 | Tactile integration — sync layer, fusion, peg-in-hole |
| 4+ | Force/compliance control, on-device inference at >=5 Hz, dataset release, paper |

Phase 3 carries an explicit go/no-go: if touch does not beat vision-only by a meaningful margin
on at least one task with enough demonstrations, the scope narrows rather than drifting.

## License

- Code (`software/`, `firmware/`): **Apache-2.0** — see [LICENSE](LICENSE). Chosen to match
  LeRobot, which this project derives from.
- Hardware (`hardware/`): **CERN-OHL-P v2** — see [LICENSE-hardware](LICENSE-hardware).

## Author

Vishal Naveen
