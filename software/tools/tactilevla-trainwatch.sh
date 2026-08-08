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

text = log.read_text(errors="replace")

# lerobot-train logs one metric line every log_freq steps:
#   INFO <ts> ot_train.py:548 step:1200 smpl:9600 ep:2 epch:0.15 loss:0.412 ...
rows = re.findall(r"step:(\d+)\s+smpl:(\d+).*?epch:([\d.]+)\s+loss:([\d.]+)", text)
total = None
m = re.search(r"cfg\.steps=(\d+)", text)
if m:
    total = int(m.group(1))

if not rows:
    print("  waiting for the first metric line (startup takes ~30s)")
    print(rule)
    raise SystemExit(0)

step = int(rows[-1][0])
epoch = float(rows[-1][2])
loss = float(rows[-1][3])
first_loss = float(rows[0][3])

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

line("epoch", f"{epoch:.2f}")
trend = "down ✓" if loss < first_loss else "NOT falling - check this"
line("loss", f"{loss:.4f}   (started {first_loss:.3f}, {trend})")
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
