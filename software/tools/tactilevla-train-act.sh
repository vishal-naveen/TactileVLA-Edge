#!/bin/bash
# Train an ACT policy on a recorded dataset.
#
#   bash ~/tactilevla-train-act.sh                 # active session, 5 epochs, auto device
#   bash ~/tactilevla-train-act.sh <dataset>       # a specific dataset
#   EPOCHS=10 bash ~/tactilevla-train-act.sh       # train longer
#   RESUME=1  bash ~/tactilevla-train-act.sh       # continue an interrupted run
#   YES=1     bash ~/tactilevla-train-act.sh       # skip the confirmation prompt
#
# Args: [dataset_name] [device: mps|cuda|cpu] [steps]
#
# Watch a run in progress from another terminal:
#   bash ~/tactilevla-trainwatch.sh
#
# All output is teed to $OUT/train.log. lerobot-train sends metrics only to
# stdout and wandb, so with wandb disabled nothing is persisted and the loss
# curve is unrecoverable once the terminal scrolls. The log file is the fix.
set -e
set -o pipefail

LEROBOT_CACHE="$HOME/.cache/huggingface/lerobot/local"
SESSION_FILE="$HOME/tactilevla-session.json"

# Steady-state step time measured on this Mac: 1.41 s/step for ACT at batch 8
# with 800x600 + 640x480 cameras on MPS. The 3060 figure is scaled from the
# published ~4.6 h for a 45k-step run. Used only for honest up-front estimates.
MPS_SEC_PER_STEP=1.41
CUDA_SEC_PER_STEP=0.37

rule() { printf '%s\n' "────────────────────────────────────────────────────────────────"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ── Dataset ──────────────────────────────────────────────────────────────────
DATASET_NAME="${1:-}"
DATASET_SRC="named on the command line"
if [ -z "$DATASET_NAME" ] && [ -f "$SESSION_FILE" ]; then
  # The ACTIVE SESSION, not "most recent" - most-recent will happily train on a
  # 3-episode rate-test dataset if one was recorded after the real session.
  DATASET_NAME="$(python3 -c "
import json
print(json.load(open('$SESSION_FILE'))['dataset'])
" 2>/dev/null || true)"
  DATASET_SRC="the active session"
fi
if [ -z "$DATASET_NAME" ]; then
  DATASET_NAME="$(ls -t "$LEROBOT_CACHE" 2>/dev/null | head -1)"
  [ -n "$DATASET_NAME" ] || die "No datasets in $LEROBOT_CACHE - record one first."
  DATASET_SRC="MOST RECENT on disk (no active session - check this is right)"
fi

DATASET_DIR="$LEROBOT_CACHE/$DATASET_NAME"
if [ ! -d "$DATASET_DIR" ]; then
  echo "Not found: $DATASET_DIR"
  echo "Available:"
  ls -1 "$LEROBOT_CACHE" 2>/dev/null | sed 's/^/  /'
  exit 1
fi

# ── Device ───────────────────────────────────────────────────────────────────
DEVICE="${2:-}"
if [ -z "$DEVICE" ]; then
  if python3 -c "import torch,sys; sys.exit(0 if torch.cuda.is_available() else 1)" 2>/dev/null; then
    DEVICE="cuda"
  else
    DEVICE="mps"
  fi
fi

# ── Step budget ──────────────────────────────────────────────────────────────
# EPOCHS defaults to 5, matching SESSION-GUIDE and the recording protocol.
# LeRobot's own guidance is 5-10 epochs; its CLI default is 100,000 STEPS, which
# on a 4k-frame dataset is ~130 epochs. The safe number has to be the one you
# get by typing nothing.
BATCH_SIZE=8
EPOCHS="${EPOCHS:-5}"
FRAMES="$(python3 -c "
import json
try:
    print(json.load(open('$DATASET_DIR/meta/info.json'))['total_frames'])
except Exception:
    print(0)
" 2>/dev/null)"
EPISODES="$(python3 -c "
import json
try:
    print(json.load(open('$DATASET_DIR/meta/info.json'))['total_episodes'])
except Exception:
    print(0)
" 2>/dev/null)"

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

# save_freq must SCALE with the run: LeRobot never prunes checkpoints (there is
# no keep-last-N, only save_freq) and each ACT checkpoint is ~591 MB. A 40,000-
# step run at save_freq=1000 would write 40 of them: 23 GB. Target ~8 instead.
#
# Raising this does NOT make the model better - checkpoints are snapshots, they
# do not affect training. It buys (a) more candidates to pick from at eval time,
# though robot time caps that at ~3-5 anyway (~15 rollouts each for a success
# rate that means anything), and (b) less redone work after a crash.
#   TARGET_CHECKPOINTS=16 bash ~/tactilevla-train-act.sh
TARGET_CHECKPOINTS="${TARGET_CHECKPOINTS:-8}"
SAVE_FREQ=$(( STEPS / TARGET_CHECKPOINTS ))
[ "$SAVE_FREQ" -lt 1000 ] && SAVE_FREQ=1000
NUM_CKPT=$(( STEPS / SAVE_FREQ + 1 ))
CKPT_GB=$(( (NUM_CKPT * 591 + 1023) / 1024 ))   # round UP
FREE_GB="$(df -g "$HOME" | awk 'NR==2 {print $4}')"

case "$DEVICE" in
  mps)  SEC_PER_STEP=$MPS_SEC_PER_STEP ;;
  cuda) SEC_PER_STEP=$CUDA_SEC_PER_STEP ;;
  *)    SEC_PER_STEP=0 ;;
esac

# ── Resume ───────────────────────────────────────────────────────────────────
# lerobot-train's --resume REQUIRES --config_path pointing at the checkpoint's
# train_config.json (configs/train.py: "A config_path is expected when resuming
# a run"), because this script passes --policy.type rather than --policy.path.
# Without it the command dies instantly - so the documented recovery path for a
# 16-hour run did not work at all.
#
# Second trap: --steps is a TOTAL, not an increment. The loop is
# `for _ in range(step, cfg.steps)`, so resuming with a --steps value the run has
# already passed executes ZERO iterations and prints "End of training" - a
# silent success that trained nothing.
RESUME_ARGS=()
if [ "${RESUME:-}" = "1" ]; then
  CKPT_CFG="$OUT/checkpoints/last/pretrained_model/train_config.json"
  [ -f "$CKPT_CFG" ] || die "Cannot resume: no checkpoint config at $CKPT_CFG"
  DONE_STEPS="$(basename "$(readlink "$OUT/checkpoints/last" || echo 0)" | sed 's/^0*//')"
  DONE_STEPS="${DONE_STEPS:-0}"
  if [ "$STEPS" -le "$DONE_STEPS" ]; then
    die "Resume would do nothing: checkpoint is already at step $DONE_STEPS but --steps=$STEPS.
       --steps is a TOTAL. Pass a bigger number, e.g.:
         RESUME=1 bash ~/tactilevla-train-act.sh $DATASET_NAME $DEVICE $(( DONE_STEPS + 10000 ))"
  fi
  RESUME_ARGS=(--resume=true --config_path="$CKPT_CFG")
  REMAINING=$(( STEPS - DONE_STEPS ))
fi

# ── Plan ─────────────────────────────────────────────────────────────────────
fmt_hours() { python3 -c "
h = $1 * $SEC_PER_STEP / 3600
print('unknown' if $SEC_PER_STEP == 0 else (f'{h*60:.0f} min' if h < 1 else f'{h:.1f} h'))"; }

echo
rule
if [ "${RESUME:-}" = "1" ]; then
  echo "  RESUMING ACT TRAINING"
else
  echo "  ACT TRAINING"
fi
rule
printf "  dataset    %s\n"      "$DATASET_NAME"
printf "             %s episodes, %s frames   (from %s)\n" "$EPISODES" "$FRAMES" "$DATASET_SRC"
printf "  device     %s\n"      "$DEVICE"
printf "  batch      %s\n"      "$BATCH_SIZE"
if [ "${RESUME:-}" = "1" ]; then
  printf "  progress   step %s of %s already done, %s remaining\n" "$DONE_STEPS" "$STEPS" "$REMAINING"
  printf "  time left  ~%s\n"   "$(fmt_hours "$REMAINING")"
  echo   "             (flags below are ignored - LeRobot reuses the checkpoint's config)"
else
  printf "  epochs     %s  ->  %s steps\n" "$EPOCHS" "$STEPS"
  printf "  time       ~%s   (at %ss/step)\n" "$(fmt_hours "$STEPS")" "$SEC_PER_STEP"
fi
printf "  checkpoints every %s steps  ->  ~%s files, ~%s GB\n" "$SAVE_FREQ" "$NUM_CKPT" "$CKPT_GB"
printf "  disk       %s GB free\n" "$FREE_GB"
printf "  output     %s\n" "${OUT/#$HOME/~}"
printf "  log        %s\n" "${OUT/#$HOME/~}/train.log"
rule

if [ "$FREE_GB" != "" ] && [ "$CKPT_GB" -gt 0 ] && [ "$FREE_GB" -lt $(( CKPT_GB * 2 )) ]; then
  echo "  WARNING: only ${FREE_GB} GB free for ~${CKPT_GB} GB of checkpoints."
  echo "  LeRobot never deletes old checkpoints. Free space or raise TARGET_CHECKPOINTS."
  rule
fi

# One confirmation before committing hours of compute. This is the last point at
# which a wrong dataset or a 10-epoch typo is free to fix.
if [ "${YES:-}" != "1" ]; then
  if [ ! -t 0 ] && [ ! -e /dev/tty ]; then
    # No terminal to ask on (nohup, cron, a pipe). Refuse rather than silently
    # committing hours of GPU time to whatever the defaults happened to be.
    die "No terminal for the confirmation prompt. Re-run with YES=1 to skip it:
       YES=1 bash ~/tactilevla-train-act.sh $*"
  fi
  printf "  Start? [y/N] "
  read -r REPLY </dev/tty 2>/dev/null || read -r REPLY || REPLY=""
  case "$REPLY" in
    [yY]*) ;;
    *) echo "  Cancelled."; exit 1 ;;
  esac
  echo
fi

mkdir -p "$OUT"

# caffeinate keeps the Mac awake for the whole run. A display sleep is harmless,
# but a system sleep suspends training and a multi-hour unattended run will hit
# it. -i blocks idle sleep, -s blocks system sleep on AC.
CAFFEINATE=""
command -v caffeinate >/dev/null 2>&1 && CAFFEINATE="caffeinate -is"

echo "  Started $(date '+%H:%M'). Watch progress with:  bash ~/tactilevla-trainwatch.sh"
echo "  Interrupted? Resume with:  RESUME=1 bash ~/tactilevla-train-act.sh $DATASET_NAME $DEVICE $STEPS"
rule
echo

# PYTHONUNBUFFERED so the progress bar and metric lines appear live through the
# tee pipe instead of arriving in 8 KB blocks.
# shellcheck disable=SC2086  # CAFFEINATE is intentionally unquoted
PYTHONUNBUFFERED=1 $CAFFEINATE lerobot-train \
  "${RESUME_ARGS[@]}" \
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

echo
rule
echo "  DONE $(date '+%H:%M').  Checkpoint: ${OUT/#$HOME/~}/checkpoints/last/pretrained_model"
echo "  Evaluate with:  bash ~/tactilevla-eval.sh"
rule
