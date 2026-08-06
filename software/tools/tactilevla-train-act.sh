#!/bin/bash
# Train an ACT policy on a recorded dataset.
#
#   bash ~/tactilevla-train-act.sh                    # newest dataset, auto device
#   bash ~/tactilevla-train-act.sh trial_20260805_173721
#   bash ~/tactilevla-train-act.sh trial_20260805_173721 cuda 8000
#
# Args: [dataset_name] [device: mps|cuda|cpu] [steps]
# Env:  EPOCHS=5   override the default 10 epochs used to compute the step budget
#       RESUME=1   continue an interrupted run from its newest checkpoint
#
# All output is teed to $OUT/train.log. lerobot-train only sends metrics to stdout
# and to wandb, so with wandb disabled nothing is persisted and the loss curve is
# unrecoverable after the terminal scrolls. The log file is the fix.
set -e
set -o pipefail

LEROBOT_CACHE="$HOME/.cache/huggingface/lerobot/local"

SESSION_FILE="$HOME/tactilevla-session.json"

DATASET_NAME="${1:-}"
if [ -z "$DATASET_NAME" ] && [ -f "$SESSION_FILE" ]; then
  # The ACTIVE SESSION, not "most recent" - most-recent will happily train on a
  # 3-episode rate-test dataset if one was recorded after the real session.
  DATASET_NAME="$(python3 -c "
import json
print(json.load(open('$SESSION_FILE'))['dataset'])
" 2>/dev/null || true)"
  [ -n "$DATASET_NAME" ] && echo "active session: $DATASET_NAME"
fi
if [ -z "$DATASET_NAME" ]; then
  DATASET_NAME="$(ls -t "$LEROBOT_CACHE" 2>/dev/null | head -1)"
  if [ -z "$DATASET_NAME" ]; then
    echo "No datasets found in $LEROBOT_CACHE - record one first."
    exit 1
  fi
  echo "No active session; using most recent: $DATASET_NAME"
fi

DATASET_DIR="$LEROBOT_CACHE/$DATASET_NAME"
if [ ! -d "$DATASET_DIR" ]; then
  echo "Not found: $DATASET_DIR"
  echo "Available:"
  ls -1 "$LEROBOT_CACHE" 2>/dev/null | sed 's/^/  /'
  exit 1
fi

# Device: default to cuda if an NVIDIA GPU is visible, else mps on Apple Silicon.
DEVICE="${2:-}"
if [ -z "$DEVICE" ]; then
  if python3 -c "import torch,sys; sys.exit(0 if torch.cuda.is_available() else 1)" 2>/dev/null; then
    DEVICE="cuda"
  else
    DEVICE="mps"
  fi
fi

# Frame count drives a sensible step budget: ~10 epochs at batch 8.
# LeRobot's own guidance is 5-10 epochs, NOT the 100k-step default.
BATCH_SIZE=8
FRAMES="$(python3 -c "
import json, sys
try:
    print(json.load(open('$DATASET_DIR/meta/info.json'))['total_frames'])
except Exception:
    print(0)
" 2>/dev/null)"

EPOCHS="${EPOCHS:-10}"
STEPS="${3:-}"
if [ -z "$STEPS" ]; then
  if [ "$FRAMES" -gt 0 ]; then
    STEPS=$(( FRAMES * EPOCHS / BATCH_SIZE ))
    [ "$STEPS" -lt 2000 ] && STEPS=2000
  else
    STEPS=8000
  fi
fi

JOB="act_${DATASET_NAME}"
OUT="$HOME/lerobot-outputs/train/$JOB"

# save_freq must SCALE with the run, because LeRobot never prunes checkpoints -
# there is no keep-last-N option, only save_freq (configs/train.py:106-108) - and
# each ACT checkpoint is ~591 MB. A 39,000-step run at save_freq=1000 would write
# 39 of them: 23 GB. Target ~8 checkpoints instead, which is plenty to fall back
# on, and never denser than every 1000 steps on short runs.
TARGET_CHECKPOINTS=8
SAVE_FREQ=$(( STEPS / TARGET_CHECKPOINTS ))
[ "$SAVE_FREQ" -lt 1000 ] && SAVE_FREQ=1000
# Round UP - understating how much disk a run needs is the dangerous direction.
CKPT_GB=$(( ((STEPS / SAVE_FREQ + 1) * 591 + 1023) / 1024 ))
FREE_GB="$(df -g "$HOME" | awk 'NR==2 {print $4}')"

# Steady-state step time measured on this Mac: 1.41 s/step for ACT at batch 8 with
# 800x600 + 640x480 cameras on MPS. Only used to print an honest up-front estimate.
MPS_SEC_PER_STEP=1.41
if [ "$DEVICE" = "mps" ]; then
  EST_HOURS="$(python3 -c "print(f'{$STEPS * $MPS_SEC_PER_STEP / 3600:.1f}')")"
else
  EST_HOURS="?"
fi

RESUME_ARG=""
if [ "${RESUME:-}" = "1" ]; then
  if [ ! -d "$OUT/checkpoints" ]; then
    echo "Cannot resume: no checkpoints in $OUT"
    exit 1
  fi
  RESUME_ARG="--resume=true"
  echo "RESUMING from the newest checkpoint in $OUT"
  echo "(LeRobot reuses the checkpoint's config, so flags below are ignored on resume)"
  echo
fi

echo "dataset : local/$DATASET_NAME  ($FRAMES frames)"
echo "device  : $DEVICE"
echo "steps   : $STEPS  (batch $BATCH_SIZE ~= $EPOCHS epochs)"
echo "save    : every $SAVE_FREQ steps  (~$((STEPS / SAVE_FREQ + 1)) checkpoints, ~${CKPT_GB} GB)"
echo "disk    : ${FREE_GB} GB free"
echo "est.    : ~${EST_HOURS} h on $DEVICE"
echo "output  : $OUT"
echo "log     : $OUT/train.log"
echo

if [ "$FREE_GB" != "" ] && [ "$CKPT_GB" -gt 0 ] && [ "$FREE_GB" -lt $(( CKPT_GB * 2 )) ]; then
  echo "WARNING: only ${FREE_GB} GB free for ~${CKPT_GB} GB of checkpoints."
  echo "Free space or raise TARGET_CHECKPOINTS' divisor before starting a long run."
  echo
fi

mkdir -p "$OUT"

# caffeinate keeps the Mac awake for the whole run. A display sleep is harmless but
# a system sleep suspends training, and a multi-hour run left unattended will hit
# it. -i blocks idle sleep, -s blocks system sleep on AC.
CAFFEINATE=""
command -v caffeinate >/dev/null 2>&1 && CAFFEINATE="caffeinate -is"

# shellcheck disable=SC2086  # CAFFEINATE and RESUME_ARG are intentionally unquoted
$CAFFEINATE lerobot-train \
  $RESUME_ARG \
  --dataset.repo_id="local/$DATASET_NAME" \
  --dataset.root="$DATASET_DIR" \
  --policy.type=act \
  --policy.device="$DEVICE" \
  --output_dir="$OUT" \
  --job_name="$JOB" \
  --batch_size="$BATCH_SIZE" \
  --steps="$STEPS" \
  --save_freq="$SAVE_FREQ" \
  --log_freq=100 \
  --wandb.enable=false \
  --policy.push_to_hub=false 2>&1 | tee -a "$OUT/train.log"
