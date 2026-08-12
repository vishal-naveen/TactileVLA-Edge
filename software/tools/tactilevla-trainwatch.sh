#!/bin/bash
# Show the state of an ACT training run at a glance.
#
#   bash ~/tactilevla-trainwatch.sh            # active session's run, once
#   bash ~/tactilevla-trainwatch.sh -f         # refresh every 30s until you Ctrl-C
#   bash ~/tactilevla-trainwatch.sh <dataset>  # a specific run
#
# Reads $OUT/train.log, which ~/tactilevla-train-act.sh tees. Safe to run while
# training is in progress - it only reads.
set -e

FOLLOW=""
DATASET_NAME=""
JOB=""
PREFIX="act"
while [ $# -gt 0 ]; do
  case "$1" in
    -f|--follow)  FOLLOW=1 ;;
    --job)        JOB="$2"; shift ;;      # exact job dir, e.g. smolvla_noodlegrid_...
    --smolvla)    PREFIX="smolvla" ;;
    -l|--list)    ls -td "$HOME"/lerobot-outputs/train/*/ 2>/dev/null | sed 's|.*/train/|  |'; exit 0 ;;
    *)            DATASET_NAME="$1" ;;
  esac
  shift
done

SESSION_FILE="$HOME/tactilevla-session.json"
if [ -z "$JOB" ] && [ -z "$DATASET_NAME" ] && [ -f "$SESSION_FILE" ]; then
  DATASET_NAME="$(python3 -c "
import json
print(json.load(open('$SESSION_FILE'))['dataset'])
" 2>/dev/null || true)"
fi

if [ -n "$JOB" ]; then
  OUT="$HOME/lerobot-outputs/train/$JOB"
elif [ -n "$DATASET_NAME" ]; then
  OUT="$HOME/lerobot-outputs/train/${PREFIX}_${DATASET_NAME}"
else
  # Newest run of any kind, so this works without arguments for either model.
  OUT="$(ls -td "$HOME"/lerobot-outputs/train/*/ 2>/dev/null | head -1)"
fi
OUT="${OUT%/}"
if [ -z "$OUT" ] || [ ! -d "$OUT" ]; then
  echo "No training run at ${OUT:-~/lerobot-outputs/train/}"
  echo "Runs available:"
  ls -td "$HOME"/lerobot-outputs/train/*/ 2>/dev/null | sed 's|.*/train/|  |' || echo "  (none)"
  exit 1
fi

show() {
python3 - "$OUT" <<'PY'
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

out = Path(sys.argv[1])
log = out / "train.log"
W = 64
rule = "─" * W


def line(label, value):
    print(f"  {label:<13}{value}")


print()
print(rule)
print(f"  {out.name}")
print(rule)

if not log.exists():
    print("  no train.log yet - the run has not started")
    print(rule)
    raise SystemExit(0)

# tqdm draws its progress bar with carriage returns, so translate them to newlines or
# every bar update collapses into one unsplittable line.
text = log.read_text(errors="replace").replace("\r", "\n")

# STEP COUNT comes from tqdm, which is EXACT.
#   Training:  25%|██▌       | 10788/42308 [1:08:35<3:20:12,  2.62step/s]
# The metric line's step: is NOT usable for this: lerobot formats it through
# format_big_number at precision 0, so 10,576 and 11,499 both render as "11K" and
# consecutive lines repeat the same value. An earlier regex here matched only plain
# digits, so past step 999 it stopped matching entirely and froze the display at 900
# while reporting a nonsense multi-day ETA.
prog = re.findall(r"\|\s*(\d+)/(\d+)\s*\[", text)

# LOSS and EPOCH come from the metric line, which lerobot logs every log_freq steps:
#   INFO <ts> ot_train.py:548 step:11K smpl:86K ep:2 epch:1.28 loss:0.251 ...
# \S+ for the abbreviated fields since they may carry a K/M/B suffix.
rows = re.findall(r"step:\S+\s+smpl:\S+.*?epch:([\d.]+)\s+loss:([\d.]+)", text)

if not prog:
    print("  waiting for the first progress line (startup takes ~30s)")
    print(rule)
    raise SystemExit(0)

step, total = int(prog[-1][0]), int(prog[-1][1])

# cfg.steps is the configured total and is authoritative if present; tqdm's total
# should agree, but prefer the config.
m = re.search(r"cfg\.steps=(\d+)", text)
if m:
    total = int(m.group(1))

# Loss and epoch lag the step count: lerobot logs them every log_freq steps, so for
# the first ~100 steps there is a progress bar but no metrics yet.
epoch = float(rows[-1][0]) if rows else None
loss = float(rows[-1][1]) if rows else None
first_loss = float(rows[0][1]) if rows else None

# Wall-clock progress from the log's own timestamps.
stamps = re.findall(r"\b(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\b", text)
elapsed = eta = None
if len(stamps) >= 2:
    fmt = "%Y-%m-%d %H:%M:%S"
    t0 = datetime.strptime(stamps[0], fmt)
    t1 = datetime.strptime(stamps[-1], fmt)
    elapsed = t1 - t0
    if total and step > 0 and elapsed.total_seconds() > 0:
        per = elapsed.total_seconds() / step
        eta = timedelta(seconds=int(per * (total - step)))

# Is it still running? Match the output dir, not just the binary name.
alive = False
try:
    ps = subprocess.run(["pgrep", "-fl", "lerobot-train"], capture_output=True, text=True, timeout=5)
    alive = out.name in ps.stdout or "lerobot-train" in ps.stdout
except Exception:
    pass

if total:
    pct = 100.0 * step / total
    filled = int(W * step / total) - 4
    bar = "█" * max(0, filled) + "░" * max(0, (W - 4) - max(0, filled))
    line("progress", f"step {step:,} / {total:,}   {pct:.1f}%")
    print(f"  {bar}")
else:
    line("progress", f"step {step:,}")

if epoch is not None:
    line("epoch", f"{epoch:.2f}")
if loss is not None:
    trend = "down ✓" if loss < first_loss else "NOT falling - check this"
    line("loss", f"{loss:.4f}   (started {first_loss:.3f}, {trend})")
else:
    line("loss", "not logged yet (lerobot logs metrics every log_freq steps)")
if elapsed:
    line("elapsed", str(elapsed).split(".")[0])
if eta:
    done_at = (datetime.now() + eta).strftime("%H:%M")
    line("remaining", f"{str(eta).split('.')[0]}   (done ~{done_at})")

ckpt_dir = out / "checkpoints"
if ckpt_dir.is_dir():
    saved = sorted(p.name for p in ckpt_dir.iterdir() if p.name.isdigit())
    size = sum(f.stat().st_size for f in ckpt_dir.rglob("*") if f.is_file()) / 1024**3
    line("checkpoints", f"{len(saved)} saved, {size:.1f} GB" + (f"   latest {saved[-1]}" if saved else ""))

errs = [l for l in text.splitlines() if re.search(r"\b(Error|Traceback|CUDA out of memory|RuntimeError)\b", l)]
if errs:
    print()
    print(f"  {len(errs)} error line(s) in the log - last one:")
    print(f"    {errs[-1][:W + 8]}")

print()
line("status", "RUNNING" if alive else "NOT RUNNING (finished, or stopped)")
if not alive and total and step < total:
    print()
    print("  Interrupted before the end. Resume with:")
    print(f"    RESUME=1 bash ~/tactilevla-train-act.sh '' '' {total}")
print(rule)
PY
}

if [ -n "$FOLLOW" ]; then
  while true; do
    clear
    show
    echo "  refreshing every 30s - Ctrl-C to stop"
    sleep 30
  done
else
  show
fi
