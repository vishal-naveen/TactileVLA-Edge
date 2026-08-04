# software/

Host-side Python. Runs on the bring-up machine (macOS) and the training machine (Linux + RTX 3060).

Planned modules:

- `tactile/` — AnySkin readout wrapper, timestamping, and the synchronization layer that lands a
  100 Hz tactile stream into 30 fps dataset frames.
- `dataset/` — the `observation.tactile` column, `meta/info.json` schema extension, and alignment
  verification tooling.
- `fusion/` — tactile conditioning inside SmolVLA: token-concat first to prove the plumbing, then
  FiLM.
- `eval/` — the touch-versus-vision comparison harness, with trial counts and confidence
  intervals rather than anecdotes.

## Ground rules

Time synchronization is the subsystem most likely to fail silently. Cameras run ~30 fps, servos
~30-50 Hz, AnySkin ~100 Hz. An 80 ms misalignment trains a correlation that does not exist and
produces a policy that fails for reasons no log will explain. Alignment gets verified in the
dataset visualizer before any training run, and that verification is itself tested.

Licensed Apache-2.0.
