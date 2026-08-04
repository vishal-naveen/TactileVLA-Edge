# ADR-0002: Pin LeRobot and treat API churn as a first-class risk

- **Status:** Accepted
- **Date:** 2026-08-04

## Context

LeRobot is moving fast (0.5.x heading toward 0.6) and its API, CLI surface, and dataset schema
all change between minor versions. Three concrete instances already observed:

1. The robot implementation directories were renamed to `so_follower` / `so_leader`, while the
   registered config names stayed `so101_follower` / `so101_leader`. Code that keys off the
   directory layout breaks; code that keys off the registered name does not.
2. A dataset's `codebase_version` in `meta/info.json` must match the LeRobot version reading it.
   Datasets recorded against one version are not guaranteed readable by another.
3. Third-party setup guides pin dependency versions that are *below* the floors LeRobot 0.5.2
   actually requires — e.g. `pynput==1.6.8` against a `>=1.7.8,<1.9.0` requirement, and
   `rerun-sdk==0.23` against `>=0.24.0,<0.27.0`. Following such a guide produces the dependency
   conflict it claims to fix.

Datasets are the expensive artifact here — tens of hours of teleoperation. Losing the ability to
read them because the framework moved is the single most costly failure mode available to us.

## Decision

1. Work against a **fork** of LeRobot, pinned to a specific commit, recorded here and updated by
   amending this ADR.
2. Resolve dependency versions from LeRobot's own `pyproject.toml` constraints, never from
   third-party guides.
3. Record the exact environment alongside every released dataset, so `codebase_version` mismatches
   are diagnosable rather than mysterious.
4. Upgrading LeRobot is a deliberate act with its own PR: re-run bring-up, replay one recorded
   episode, and confirm dataset readability before merging.

### Current pinned environment

| Item | Value |
|---|---|
| LeRobot | 0.5.2 (editable install from fork) |
| Python | 3.13.5 |
| PyTorch | 2.10.0 |
| ffmpeg | 8.0.1 with libsvtav1 |
| Platform | macOS arm64 (bring-up), Ubuntu 22.04 + RTX 3060 (training) |

Bring-up and calibration run on macOS. Training runs on the Linux/3060 machine. RealSense depth
cameras are unstable on macOS and are avoided there.

## Consequences

- Upgrades are slower and intentional, which is the trade we want.
- We may sit on a known-good older version while upstream moves; acceptable, since reproducibility
  of the published dataset outranks having the newest features.
- Divergence from upstream accumulates and periodically has to be paid down.
- Any contributor environment that drifts from the table above is expected to reproduce a failure
  before it is treated as a real bug.
