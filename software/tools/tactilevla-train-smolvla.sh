#!/bin/bash
# Fine-tune SmolVLA-450M on a recorded dataset. This is the THESIS model - ACT is
# the vision-only baseline it gets compared against.
#
#   bash ~/tactilevla-train-smolvla.sh <hf_user>/<dataset>     # from the Hub (the PC)
#   bash ~/tactilevla-train-smolvla.sh --local <dataset>       # from ~/.cache (the Mac)
#   BATCH=24 bash ~/tactilevla-train-smolvla.sh <repo>         # if VRAM allows
#   STEPS=30000 bash ~/tactilevla-train-smolvla.sh <repo>      # train longer
#   UNFREEZE=1 bash ~/tactilevla-train-smolvla.sh <repo>       # also train the vision encoder
#   RESUME=1 STEPS=40000 bash ~/tactilevla-train-smolvla.sh <repo>
#
# Watch it:  bash ~/tactilevla-trainwatch.sh --job smolvla_<dataset>
#
# ── NOT YET RUN AGAINST A GPU ────────────────────────────────────────────────
# Written 2026-08-08 from LeRobot 0.5.2's own source and docs, but never executed
# on the 3060. Do a 5-step smoke test before trusting a multi-hour run:
#   STEPS=5 BATCH=2 bash ~/tactilevla-train-smolvla.sh <repo>
# ─────────────────────────────────────────────────────────────────────────────
set -e
set -o pipefail

rule() { printf '%s\n' "────────────────────────────────────────────────────────────────"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

LOCAL=""
if [ "$1" = "--local" ]; then LOCAL=1; shift; fi
REPO="${1:-}"
[ -n "$REPO" ] || die "Name the dataset.
       from the Hub:  bash ~/tactilevla-train-smolvla.sh <hf_user>/<dataset>
       local copy  :  bash ~/tactilevla-train-smolvla.sh --local <dataset>"

NAME="${REPO##*/}"
# Overridable so a smoke/timing run can use a throwaway output dir - lerobot-train
# refuses to start when output_dir already exists and resume is false. See train-act.sh.
JOB="${JOB:-smolvla_${NAME}}"
OUT="$HOME/lerobot-outputs/train/$JOB"

DATASET_ARGS=(--dataset.repo_id="$REPO")
if [ -n "$LOCAL" ]; then
  ROOT="$HOME/.cache/huggingface/lerobot/local/$NAME"
  [ -d "$ROOT" ] || die "No local dataset at $ROOT"
  DATASET_ARGS=(--dataset.repo_id="local/$NAME" --dataset.root="$ROOT")
  FRAMES="$(python3 -c "import json;print(json.load(open('$ROOT/meta/info.json'))['total_frames'])" 2>/dev/null || echo 0)"
else
  FRAMES=0   # unknown until LeRobot pulls it from the Hub
fi

# Device. SmolVLA on MPS is possible but impractically slow - the whole point of
# this model is that it fits a 12 GB CUDA card.
DEVICE="${DEVICE:-}"
if [ -z "$DEVICE" ]; then
  if python3 -c "import torch,sys; sys.exit(0 if torch.cuda.is_available() else 1)" 2>/dev/null; then
    DEVICE="cuda"
  else
    DEVICE="mps"
    echo "WARNING: no CUDA device found, falling back to mps."
    echo "         SmolVLA-450M on MPS is very slow - this is for smoke tests only."
    echo
  fi
fi

# Batch size. Reference numbers: the LeRobot docs use 64 on an A100; a 3080 Ti
# (12 GB) has been reported at ~11.5 GB with batch 44 at DEFAULT (frozen-backbone)
# settings. 16 is a conservative start for a 3060 12 GB that also drives a display.
# Unfreezing the vision encoder raises memory a lot - halve the batch if you do.
BATCH="${BATCH:-16}"
[ "${UNFREEZE:-}" = "1" ] && BATCH="${BATCH_UNFROZEN:-8}"

# Steps. The docs' reference is 20,000. At batch 16 on a 64k-frame dataset that
# is ~5 epochs, which lines up with the ACT budget - so the two models see
# comparable exposure to the data, which matters if you are reporting them
# side by side.
STEPS="${STEPS:-20000}"

# SmolVLA HAS a scheduler (cosine decay with warmup) - unlike ACT, which has none.
# scheduler_decay_steps defaults to 30000; leaving it there while training for a
# different number of steps means the LR schedule does not match the run.
DECAY="${DECAY:-$STEPS}"

FREEZE_ARGS=()
if [ "${UNFREEZE:-}" = "1" ]; then
  FREEZE_ARGS=(--policy.freeze_vision_encoder=false --policy.train_expert_only=false)
fi

# Resume: same trap as ACT. --steps is a TOTAL, and resuming needs the
# checkpoint's own train_config.json rather than --policy.path.
POLICY_ARGS=(--policy.path=lerobot/smolvla_base)
if [ "${RESUME:-}" = "1" ]; then
  CKPT_CFG="$OUT/checkpoints/last/pretrained_model/train_config.json"
  [ -f "$CKPT_CFG" ] || die "Cannot resume: no checkpoint config at $CKPT_CFG"
  DONE_STEPS="$(basename "$(readlink "$OUT/checkpoints/last" || echo 0)" | sed 's/^0*//')"
  DONE_STEPS="${DONE_STEPS:-0}"
  [ "$STEPS" -gt "$DONE_STEPS" ] || die "Resume would do nothing: already at step $DONE_STEPS, --steps=$STEPS.
       --steps is a TOTAL. Try: RESUME=1 STEPS=$(( DONE_STEPS + 10000 )) bash ~/tactilevla-train-smolvla.sh $REPO"
  POLICY_ARGS=(--resume=true --config_path="$CKPT_CFG")
  FREEZE_ARGS=()
fi

# SmolVLA checkpoints are BIG and LeRobot never prunes them. The full 450M model
# is written every time (~1.7 GB) plus optimizer state (~0.8 GB frozen, ~3.4 GB
# unfrozen), so ~2.5 GB or ~5 GB per checkpoint. ACT's are 591 MB, which is why
# that script can afford 8 of them and this one cannot: 8 here would be 20-40 GB.
TARGET_CHECKPOINTS="${TARGET_CHECKPOINTS:-4}"
SAVE_FREQ=$(( STEPS / TARGET_CHECKPOINTS ))
[ "$SAVE_FREQ" -lt 1000 ] && SAVE_FREQ=1000
NUM_CKPT=$(( STEPS / SAVE_FREQ + 1 ))
PER_CKPT_GB=$([ "${UNFREEZE:-}" = "1" ] && echo 5 || echo 3)   # rounded UP
CKPT_GB=$(( NUM_CKPT * PER_CKPT_GB ))
FREE_GB="$(df -g "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')"

echo
rule
echo "  SMOLVLA-450M FINE-TUNE${RESUME:+  (RESUMING)}"
rule
printf "  dataset    %s%s\n" "$REPO" "${LOCAL:+   (local copy)}"
[ "$FRAMES" -gt 0 ] 2>/dev/null && printf "             %s frames  ->  %s steps is ~%s epochs\n" \
  "$FRAMES" "$STEPS" "$(python3 -c "print(f'{$STEPS*$BATCH/$FRAMES:.1f}')")"
printf "  base       lerobot/smolvla_base  (450M)\n"
printf "  device     %s\n" "$DEVICE"
printf "  batch      %s\n" "$BATCH"
printf "  steps      %s   (lr decay over %s, warmup 1000)\n" "$STEPS" "$DECAY"
printf "  backbone   %s\n" "$([ "${UNFREEZE:-}" = 1 ] && echo 'TRAINED (unfrozen) - more VRAM, usually better' || echo 'frozen (default) - only the action expert trains')"
printf "  checkpoints every %s steps  ->  ~%s files, ~%s GB\n" "$SAVE_FREQ" "$NUM_CKPT" "$CKPT_GB"
printf "  disk       %s GB free\n" "${FREE_GB:-?}"
printf "  output     %s\n" "${OUT/#$HOME/~}"
rule
if [ -n "$FREE_GB" ] && [ "$FREE_GB" -lt $(( CKPT_GB * 2 )) ]; then
  echo "  WARNING: only ${FREE_GB} GB free for ~${CKPT_GB} GB of checkpoints, and"
  echo "  LeRobot never deletes old ones. Lower TARGET_CHECKPOINTS or free space."
  rule
fi
echo "  Images are letterboxed to 512x512 internally, so recording above that"
echo "  buys this model nothing. Action chunk is 50 (ACT uses 100)."
rule

if [ "${YES:-}" != "1" ]; then
  printf "  Start? [y/N] "
  read -r REPLY </dev/tty 2>/dev/null || read -r REPLY || REPLY=""
  case "$REPLY" in [yY]*) ;; *) echo "  Cancelled."; exit 1 ;; esac
  echo
fi

# DO NOT create $OUT - lerobot-train raises FileExistsError on an existing output_dir
# when resume is false (configs/train.py:192). See train-act.sh for the full story.
LOG_DIR="$HOME/tactilevla-logs"
mkdir -p "$LOG_DIR"
STAGING_LOG="$LOG_DIR/${JOB}-train.log"

if [ "${RESUME:-}" = "1" ]; then
  ln -sf "$STAGING_LOG" "$OUT/train.log" 2>/dev/null || true
else
  (
    for _ in $(seq 1 120); do
      [ -d "$OUT" ] && { ln -sf "$STAGING_LOG" "$OUT/train.log" 2>/dev/null; exit 0; }
      sleep 1
    done
  ) &
  LINK_WATCHER=$!
  # shellcheck disable=SC2064  # expand LINK_WATCHER now, not at trap time
  trap "kill $LINK_WATCHER 2>/dev/null || true" EXIT
fi

CAFFEINATE=""
command -v caffeinate >/dev/null 2>&1 && CAFFEINATE="caffeinate -is"

echo "  Started $(date '+%H:%M')."
rule
echo

# shellcheck disable=SC2086
PYTHONUNBUFFERED=1 $CAFFEINATE lerobot-train \
  "${POLICY_ARGS[@]}" \
  "${DATASET_ARGS[@]}" \
  "${FREEZE_ARGS[@]}" \
  --policy.device="$DEVICE" \
  --policy.scheduler_decay_steps="$DECAY" \
  --output_dir="$OUT" \
  --job_name="$JOB" \
  --batch_size="$BATCH" \
  --steps="$STEPS" \
  --save_freq="$SAVE_FREQ" \
  --log_freq=100 \
  --wandb.enable=false \
  --policy.push_to_hub=false 2>&1 | tee -a "$STAGING_LOG"

echo
rule
echo "  DONE $(date '+%H:%M').  Checkpoint: ${OUT/#$HOME/~}/checkpoints/last/pretrained_model"
rule
