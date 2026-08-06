# software/

Host-side Python. Runs on the bring-up machine (macOS) and the training machine (Linux + RTX 3060).

- `tools/` — the operational scripts that actually run sessions. See `tools/README.md`.

Planned modules:

- `tactile/` — servo-load readout (`Present_Load`, addr 60 on the STS3215) and the layer that
  lands it into 30 fps dataset frames. This replaces the earlier AnySkin plan: the servos already
  report load, so touch sensing needs no additional hardware. Verified responsive to real force —
  peaks under hand pressure ran 48-152 depending on the joint — with three caveats: the values are
  quantized in steps of 4 and jump 0 → 20 (light contact reads exactly 0), they include
  pose-dependent static torque rather than contact alone, and they read 0 while torque is disabled.
- `dataset/` — the tactile column, `meta/info.json` schema extension, and alignment verification.
  Likely implemented by widening `observation.state` from 6 to 12 rather than adding a new feature
  type, which avoids LeRobot's feature-routing entirely.
- `fusion/` — tactile conditioning inside SmolVLA: token-concat first to prove the plumbing, then
  FiLM.
- `eval/` — the touch-versus-vision comparison harness, with trial counts and confidence
  intervals rather than anecdotes.

## Ground rules

Time synchronization is the subsystem most likely to fail silently. Cameras run ~30 fps and servos
~30-50 Hz. A misalignment of a couple of frames trains a correlation that does not exist and
produces a policy that fails for reasons no log will explain. Alignment gets verified before any
training run, and that verification is itself tested.

Reading load adds a second `sync_read` to every control step. LeRobot's `sync_read` uses
`num_retry=0`, so a single serial timeout aborts a whole session — the cost of that extra read
needs measuring before it goes near a long recording run.

The touch-versus-vision comparison belongs on a contact-rich insertion task, not on pick-and-place.
The literature puts vision-only imitation learning at 0% on sub-millimetre insertion while
tactile-augmented methods reach 67%; on foam pick-and-place the difference is negligible. One
insertion dataset recorded *with* load channels trains both arms of the ablation.

Licensed Apache-2.0.
