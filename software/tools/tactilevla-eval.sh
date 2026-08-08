#!/bin/bash
# Run a trained policy autonomously on the follower arm. The leader is NOT used.
#
#   bash ~/tactilevla-eval.sh                 # newest ACT checkpoint, 60s
#   bash ~/tactilevla-eval.sh <ckpt_dir> 30   # explicit checkpoint, 30s
#
# SAFETY: this drives the arm with no human in the loop.
#   - Clear the workspace and keep hands away from the arm.
#   - Keep one hand near the follower's power connector to cut power instantly.
#   - Ctrl-C stops it.
#
# max_relative_target caps how far the arm is commanded to move per step, which
# limits the damage from a wild prediction. Raise it only once the policy behaves.
set -e

# Port from ~/tactilevla-ports.json (see ~/tactilevla-findports.py). Hardcoding
# it meant a replug broke six scripts; the config makes it a one-command fix.
PORTS_LINE="$(bash "$HOME/tactilevla-ports.sh")" || exit 1
read -r FOLLOWER_PORT _LEADER_PORT <<<"$PORTS_LINE"
# Indices come from ~/tactilevla-cams.json. This matters for OLD checkpoints too:
# the policy learned "observation.images.top" = the overhead view, so top must be
# fed by whichever index is overhead TODAY, not by whichever index was overhead
# when it was recorded. Hardcoding 0/1 here would have silently swapped the two
# camera streams on the noodle10 checkpoint after macOS renumbered them.
CAMS_JSON="$HOME/tactilevla-cams.json"
if [ ! -f "$CAMS_JSON" ]; then
  echo "Missing $CAMS_JSON - cannot know which camera is which."
  exit 1
fi
read -r TOP_CAM WRIST_CAM <<EOF
$(python3 - "$CAMS_JSON" <<'PY'
import json
import sys

cfg = json.load(open(sys.argv[1]))
print(cfg["top"]["index"], cfg["wrist"]["index"])
PY
)
EOF
if [ -z "$WRIST_CAM" ]; then
  echo "Could not read camera indices from $CAMS_JSON"
  exit 1
fi

TASK="Grab the pool noodle and put it in the yellow cup"

SESSION_FILE="$HOME/tactilevla-session.json"

CKPT="${1:-}"
if [ -z "$CKPT" ] && [ -f "$SESSION_FILE" ]; then
  # Prefer the checkpoint trained on the ACTIVE SESSION over the newest one on
  # disk, so evaluating never silently runs a policy from a different dataset.
  SESSION_DATASET="$(python3 -c "
import json
print(json.load(open('$SESSION_FILE'))['dataset'])
" 2>/dev/null || true)"
  CANDIDATE="$HOME/lerobot-outputs/train/act_${SESSION_DATASET}/checkpoints/last/pretrained_model"
  if [ -n "$SESSION_DATASET" ] && [ -f "$CANDIDATE/model.safetensors" ]; then
    CKPT="$CANDIDATE"
    echo "active session: $SESSION_DATASET"
  fi
fi
if [ -z "$CKPT" ]; then
  CKPT="$(ls -td "$HOME"/lerobot-outputs/train/act_*/checkpoints/last/pretrained_model 2>/dev/null | head -1)"
  if [ -z "$CKPT" ]; then
    echo "No trained checkpoint found under ~/lerobot-outputs/train/"
    exit 1
  fi
  echo "No checkpoint for the active session; using newest: $CKPT"
fi
if [ ! -f "$CKPT/model.safetensors" ]; then
  echo "Not a valid checkpoint (no model.safetensors): $CKPT"
  exit 1
fi

# Camera resolution is READ FROM THE CHECKPOINT, not hardcoded.
#
# A policy's input_features record the exact (C, H, W) it was trained on. Feeding
# it a different resolution runs without error but silently degrades it, and the
# top camera's resolution has already changed once (800x600 -> 1280x720), so any
# hardcoded value here would be wrong for half the checkpoints on disk.
read -r TOP_W TOP_H WRIST_W WRIST_H <<EOF
$(python3 - "$CKPT/config.json" <<'PY'
import json
import sys

feats = json.load(open(sys.argv[1]))["input_features"]
out = []
for key in ("observation.images.top", "observation.images.wrist"):
    if key not in feats:
        sys.exit(f"checkpoint has no {key}")
    _, h, w = feats[key]["shape"]
    out += [str(w), str(h)]
print(" ".join(out))
PY
)
EOF
if [ -z "$WRIST_H" ]; then
  echo "Could not read camera resolution from $CKPT/config.json"
  exit 1
fi

# Camera KEY NAMES ("top"/"wrist") must match the recording config too - a
# mismatch produces confusing normalization errors rather than a clear one.
CAMERAS="{ top: {type: opencv, index_or_path: $TOP_CAM, width: $TOP_W, height: $TOP_H, fps: 30}, wrist: {type: opencv, index_or_path: $WRIST_CAM, width: $WRIST_W, height: $WRIST_H, fps: 30}}"

DURATION="${2:-60}"

# Degrees of movement allowed per control step.
#
# This CLAMPS the policy's intent: the commanded delta is truncated to this value
# every step, so a small number makes the arm permanently lag behind its own plan.
# The demos were recorded with NO clamp, so any value here makes the arm slower
# than it was trained to move.
#
#   5      very cautious - good for a first-ever rollout, visibly sluggish
#   15     moderate
#   none   no clamp - matches recording conditions, full trained speed
#
MAX_REL_TARGET="${3:-15}"

# Control-loop rate. The policy was trained at 30fps, so 30 replays motion at the
# demonstrated speed. Raising this replays the action chunk faster than trained -
# it does speed the arm up, but distorts timing relative to training.
FPS="${4:-30}"

if [ "$MAX_REL_TARGET" = "none" ]; then
  CLAMP_ARG=""
  CLAMP_DESC="none (full trained speed)"
else
  CLAMP_ARG="--robot.max_relative_target=$MAX_REL_TARGET"
  CLAMP_DESC="${MAX_REL_TARGET} deg/step"
fi

cat <<EOF
checkpoint : $CKPT
cameras    : top cam $TOP_CAM ${TOP_W}x${TOP_H}, wrist cam $WRIST_CAM ${WRIST_W}x${WRIST_H}
             (resolution from checkpoint, indices from tactilevla-cams.json)
duration   : ${DURATION}s
task       : $TASK
clamp      : $CLAMP_DESC
fps        : $FPS

The arm will move ON ITS OWN. Clear the area. Ctrl-C to stop.
Starting in 5 seconds...
EOF
sleep 5

# shellcheck disable=SC2086  # CLAMP_ARG is intentionally unquoted (may be empty)
lerobot-rollout \
  --strategy.type=base \
  --policy.path="$CKPT" \
  --robot.type=so101_follower \
  --robot.port="$FOLLOWER_PORT" \
  --robot.id=follower_01 \
  --robot.cameras="$CAMERAS" \
  $CLAMP_ARG \
  --task="$TASK" \
  --duration="$DURATION" \
  --fps="$FPS" \
  --display_data=true
