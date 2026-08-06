# software/tools/

Operational scripts for the bring-up machine. These exist because a data-collection
session has a lot of state — camera indices, resolutions, calibration ids, ports, grid
geometry — and every one of them is a way to silently ruin two hours of recording.

They live in `$HOME` during use (`bash ~/tactilevla-record.sh ...`); this directory is
the tracked copy.

## Configuration: two files, one source of truth each

**`tactilevla-cams.json`** — camera role → index + resolution. Every script reads it, so
a macOS renumbering is a one-line fix instead of six.

macOS renumbers UVC cameras when they are replugged. It happened mid-project: a
`camcheck` run with hardcoded indices measured the *wrist* camera while labelling it
"top", and a resolution decision was made on that bad data. To settle which index is
which, do not reason about it — read the recorded video:

```bash
ffmpeg -i videos/observation.images.top/chunk-000/file-000.mp4 \
  -vf "select=eq(n\,30)" -vframes 1 out.png
```

Focus scores are a poor discriminator: Laplacian variance depends on scene content and
resolution, so the same camera reads 11 at 1080p and 29 at 800x600 while equally sharp.

**`tactilevla-grid.json`** — the placement grid: four table corners in pixel space,
rows/cols, and which cells are held out. Corners auto-save on every rotate/nudge, which
is convenient while aligning and dangerous afterwards, so the file carries a `locked`
flag. Set it once aligned.

## Session flow

```bash
python3 ~/tactilevla-verify.py                      # arms, voltages, temps, cameras
bash    ~/tactilevla-cams-up.sh                     # grid + both previews
bash    ~/tactilevla-record.sh <name> 40 "<task>"   # assigns a timestamped session id
bash    ~/tactilevla-record.sh resume <id> 40       # add a round
python3 ~/tactilevla-checkdata.py                   # after EVERY round
EPOCHS=5 bash ~/tactilevla-train-act.sh             # trains the active session
bash    ~/tactilevla-eval.sh <ckpt> 60 none         # autonomous rollout
```

`record.sh` registers the session in `~/tactilevla-session.json` — dataset id, task
string, and a snapshot of the camera and grid config it was recorded under.
`checkdata`, `train-act` and `eval` all default to that session rather than "most
recent", because most-recent happily picks up a three-episode rate test recorded
afterwards and then reports PASS on the wrong data.

## The scripts

| Script | Purpose |
|---|---|
| `tactilevla-verify.py` | Read-only link check: positions, load, current, voltage, temperature, cameras. Torque stays disabled. |
| `tactilevla-camview.py` | Live preview with brightness and focus meters. Windows are titled with the camera's *role*. |
| `tactilevla-camcheck.py` | Sustained capture measurement: each camera alone, then both together. |
| `tactilevla-grid.py` | Perspective-correct placement grid on the overhead camera. |
| `tactilevla-cams-up.sh` | Opens grid + both previews in separate Terminal windows. |
| `tactilevla-record.sh` | Teleoperated recording with session ids and resume. |
| `tactilevla-checkdata.py` | Dataset gate: achieved loop rate, video/parquet agreement, frame-index integrity, episode-length outliers. |
| `tactilevla-train-act.sh` | ACT training with a scaled step budget, scaled `save_freq`, `caffeinate`, and a persisted log. |
| `tactilevla-eval.sh` | Autonomous rollout. Reads camera resolution from the checkpoint. |
| `tactilevla-loadtest.py` | Streams `Present_Load` while you push on the arm — the servo-load tactile feasibility test. |
| `tactilevla-keytest.py` | Confirms macOS delivers keystrokes to pynput. |
| `tactilevla-calibrate-*.sh`, `tactilevla-teleop*.sh` | Thin wrappers over the LeRobot CLI. |

## Things these scripts encode the hard way

- **`lerobot-train` defaults to `--steps=100000`.** On a 4k-frame dataset that is ~130
  epochs against LeRobot's own guidance of 5-10. `train-act.sh` computes the budget from
  the frame count.
- **LeRobot never prunes checkpoints** — there is no keep-last-N, only `save_freq`, and
  each ACT checkpoint is ~591 MB. A 39,000-step run at `save_freq=1000` writes 23 GB.
  `save_freq` is scaled to target ~8 checkpoints.
- **Dataset timestamps are nominal** (`frame_index / fps`), so they read as a flawless
  33.3 ms even when the loop really ran at 18 Hz. The only report of the true rate is
  `lerobot-record`'s console warning, which is why `record.sh` tees its output and
  `checkdata.py` parses it. Slow steps at *episode start* are encoder warm-up and
  harmless; only mid-episode stalls distort the recording.
- **`max_relative_target` clamps the policy's intent every step**, so any value makes the
  arm lag its own plan. Recording uses no clamp, so `eval.sh` accepts `none` to match.
- **Policy speed is learned from demonstration speed.** No inference setting recovers a
  slow demo.
- **A grid drawn uniformly in image space is not uniform on the table.** With an angled
  camera the far cells cover ~2.4x more table than the near ones. `grid.py` maps a
  clicked table rectangle through a homography instead.
- **No camera control is settable on macOS.** Autofocus, exposure, white balance, gain —
  all read-only under AVFoundation, as is `fourcc` (so MJPEG is unavailable). Exposure
  drift can only be managed physically: blinds closed, steady artificial light.
- **Multiple processes can share a camera at no cost.** Two and three simultaneous
  readers on the overhead camera all held 30.0 fps, so the previews can stay open during
  recording. When timing a camera, discard ~10 warm-up frames first — without that,
  `VideoCapture` open latency lands inside the window and looks like a frame-rate drop.

Licensed Apache-2.0.
