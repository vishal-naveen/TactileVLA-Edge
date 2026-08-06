#!/bin/bash
# Record a teleoperated dataset with both cameras.
#
#   START a session (auto-assigns a timestamped session ID):
#     bash ~/tactilevla-record.sh noodlegrid 40 "Grab the pool noodle and put it in the yellow cup"
#
#   ADD to a session - name the ID explicitly so you always see what you are
#   appending to. It is checked against the registered session, so a typo or the
#   wrong ID is refused instead of quietly starting a second dataset:
#     bash ~/tactilevla-record.sh resume noodlegrid_20260806_1830 40
#
#   The ID can be omitted to use the active session, but typing it is safer:
#     bash ~/tactilevla-record.sh resume 40
#
# The active session ID is stored in ~/tactilevla-session.json, and
# checkdata / train / eval all default to it. That is the point: the session ID is
# recorded once, and every later step references the same dataset instead of you
# retyping a name (a typo silently starts a SECOND dataset) or a tool guessing
# "most recent" (which picks up throwaway test datasets).
#
# During recording (LeRobot 0.5.2 binds ONLY these three - not n/r/q):
#   Right arrow  finish this episode early, move on to the reset phase
#   Left arrow   discard and re-record this episode
#   Esc          stop the session and encode video
#
# Saves locally to ~/.cache/huggingface/lerobot/local/<SESSION_ID>. Nothing is uploaded.
set -e

SESSION_FILE="$HOME/tactilevla-session.json"
LEROBOT_LOCAL="$HOME/.cache/huggingface/lerobot/local"

if [ "$1" = "resume" ]; then
  # Name and task come from the session file, never retyped.
  if [ ! -f "$SESSION_FILE" ]; then
    echo "No active session at $SESSION_FILE - start one by naming it:"
    echo "  bash ~/tactilevla-record.sh noodlegrid 40 \"<task>\""
    exit 1
  fi
  # "resume <id> <n>" or "resume <n>". An explicit ID is checked against the
  # registered session, so appending to the wrong dataset is impossible rather
  # than merely unlikely.
  if [[ "$2" =~ ^[0-9]+$ ]] || [ -z "$2" ]; then
    WANT_ID=""
    NUM_EPISODES="${2:-40}"
  else
    WANT_ID="$2"
    NUM_EPISODES="${3:-40}"
  fi

  # Resolve into a variable first. Redirections cannot go after $(...) inside a
  # heredoc body - they become literal text and end up in the parsed value.
  SESSION_LINE="$(python3 - "$SESSION_FILE" "$WANT_ID" 2>/dev/null <<'PY'
import json
import sys

session_file, want = sys.argv[1], sys.argv[2]
s = json.load(open(session_file))
if want and want != s["dataset"]:
    sys.exit(1)
print(s["dataset"], s["task"])
PY
)" || true   # set -e would kill the script on a mismatch before we can explain it

  if [ -z "$SESSION_LINE" ]; then
    echo "REFUSING TO RESUME - that ID does not match the registered session."
    python3 - "$SESSION_FILE" "$WANT_ID" <<'PY' || true
import json
import sys

s = json.load(open(sys.argv[1]))
want = sys.argv[2]
print(f"  you asked for : {want or '(active session)'}")
print(f"  registered    : {s['dataset']}")
print(f"  created       : {s['created']}")
print()
print("Copy the registered ID above, or to append to some OTHER dataset on")
print("purpose, name it the long way:")
print(f"  bash ~/tactilevla-record.sh <id> <n> \"{s['task']}\" resume")
PY
    exit 1
  fi

  read -r DATASET_NAME TASK_DESC <<<"$SESSION_LINE"
  RESUME="resume"
else
  BASE_NAME="${1:-grab_cube}"
  NUM_EPISODES="${2:-50}"
  TASK_DESC="${3:-Grab the black cube}"
  RESUME="${4:-}"
  if [ "$RESUME" = "resume" ]; then
    DATASET_NAME="$BASE_NAME"   # explicit-name resume still works
  else
    # Timestamp makes the ID unique, so re-running the same command can never
    # silently append to yesterday's dataset.
    DATASET_NAME="${BASE_NAME}_$(date +%Y%m%d_%H%M)"
  fi
fi

# On resume, NUM_EPISODES is the number of ADDITIONAL episodes to record, not the
# new total. This is LeRobot's behaviour and it is easy to get wrong: asking for
# 160 on a dataset that already has 40 gives you 200, not 160.
DATASET_ROOT="$LEROBOT_LOCAL/$DATASET_NAME"
RESUME_ARG=""
if [ "$RESUME" = "resume" ]; then
  if [ ! -d "$DATASET_ROOT" ]; then
    echo "Cannot resume: no dataset at $DATASET_ROOT"
    exit 1
  fi
  RESUME_ARG="--resume=true"
  EXISTING="$(python3 -c "
import json
print(json.load(open('$DATASET_ROOT/meta/info.json'))['total_episodes'])
" 2>/dev/null || echo '?')"
  echo "RESUMING session $DATASET_NAME"
  echo "  has $EXISTING episodes, adding $NUM_EPISODES more"
  echo
fi

# NOTE: leaving the preview/grid windows open during recording is fine. Measured on
# this Mac: two and three simultaneous readers on the overhead camera all held
# 30.0 fps. (An earlier "26 fps" figure was a bad measurement - the test script did
# not discard camera warm-up frames, so ~1 s of open latency sat inside a 6 s
# window.) If checkdata ever reports MID-EPISODE stalls, closing the extra windows
# is still the cheapest thing to try, since they do cost some CPU.

FOLLOWER_PORT="/dev/tty.usbmodem5B7B0154811"
LEADER_PORT="/dev/tty.usbmodem5B7B0137031"

# --- Cameras ------------------------------------------------------------------
# Roles, indices and resolutions all come from ~/tactilevla-cams.json so there is
# exactly ONE place to fix when macOS renumbers the cameras. It renumbered once
# already, between the noodle10 recording and 2026-08-06, and recording a session
# with the roles reversed is unrecoverable.
CAMS_JSON="$HOME/tactilevla-cams.json"
if [ ! -f "$CAMS_JSON" ]; then
  echo "Missing $CAMS_JSON - cannot know which camera is which."
  exit 1
fi
read -r TOP_CAM TOP_W TOP_H WRIST_CAM WRIST_W WRIST_H <<EOF
$(python3 - "$CAMS_JSON" <<'PY'
import json
import sys

cfg = json.load(open(sys.argv[1]))
print(" ".join(
    str(cfg[role][key]) for role in ("top", "wrist") for key in ("index", "width", "height")
))
PY
)
EOF
if [ -z "$WRIST_H" ]; then
  echo "Could not read camera config from $CAMS_JSON"
  exit 1
fi

# Resolution notes. Only the top camera carries the higher setting: the wrist view
# is close-up so extra pixels buy it little, and holding it down keeps encode load
# off the control loop. Raising resolution does NOT widen the field of view, and
# 800x600 -> 1280x720 changes aspect 4:3 -> 16:9, making the frame wider but
# shorter. To see more table, move the camera.
#
# Cameras offer only 640x480, 800x600, 1280x720, 1920x1080
# (1024x768 and 1280x960 snap upward and are unusable). 1080p was tried and
# reverted: the image-writer + AV1 encode path starved the record loop to
# 17-25 Hz. 1280x720 remains UNRESOLVED - one record attempt died a second in
# with "Failed to sync read 'Present_Position' on ids=[1..6] ... no status
# packet", but a later capture measurement showed 720p holding 29.8 Hz with zero
# contention, so resolution may not have been the cause at all. The competing
# explanation is a transient stall that was fatal only because LeRobot's
# sync_read uses num_retry=0 - one dropped packet ends a session. Settle it with
# a 5-episode record test, not by inference.
#
# Override for an A/B without editing anything:
#   TOP_RES=1280x720 bash ~/tactilevla-record.sh res720 5 "res test"
if [ -n "${TOP_RES:-}" ]; then
  TOP_W="${TOP_RES%%x*}"; TOP_H="${TOP_RES##*x}"
  case "$TOP_W$TOP_H" in *[!0-9]*|'') echo "TOP_RES must be WxH, got '$TOP_RES'"; exit 1;; esac
fi
if [ -n "${WRIST_RES:-}" ]; then
  WRIST_W="${WRIST_RES%%x*}"; WRIST_H="${WRIST_RES##*x}"
  case "$WRIST_W$WRIST_H" in *[!0-9]*|'') echo "WRIST_RES must be WxH, got '$WRIST_RES'"; exit 1;; esac
fi

# No rotation: the unrotated wrist preview was already correctly oriented.
# Set to 90 or -90 here (and swap CAM_W/CAM_H for the wrist entry) if that changes.
#
# NOTE: `fourcc: MJPG` is deliberately absent. macOS AVFoundation does not allow
# OpenCV to set the codec - it fails with "success=False" and only adds warnings.
# ------------------------------------------------------------------------------

CAMERAS="{ top: {type: opencv, index_or_path: $TOP_CAM, width: $TOP_W, height: $TOP_H, fps: 30}, wrist: {type: opencv, index_or_path: $WRIST_CAM, width: $WRIST_W, height: $WRIST_H, fps: 30}}"

# Console output is teed to a log because it is the ONLY place the achieved loop
# rate is reported. The dataset's `timestamp` column is nominal (frame_index/fps),
# so it reads as a perfect 33.3 ms even when the loop was actually running at
# 18 Hz - the drop is invisible in the data and visible only in this log, as
# "Record loop is running slower (X Hz)". ~/tactilevla-checkdata.py reads it.
LOG_DIR="$HOME/tactilevla-logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/${DATASET_NAME}-record.log"

# Register the session on creation, snapshotting the camera and grid config it was
# recorded under. Later mismatches (a camera renumbering, a re-clicked grid) then
# show up as a diff against this record instead of being invisible.
if [ "$RESUME" != "resume" ]; then
  python3 - "$SESSION_FILE" "$DATASET_NAME" "$TASK_DESC" "$DATASET_ROOT" <<'PY'
import json
import sys
from datetime import datetime
from pathlib import Path

session_file, dataset, task, root = sys.argv[1:5]
home = Path.home()


def load(name):
    path = home / name
    return json.loads(path.read_text()) if path.exists() else None


json.dump(
    {
        "dataset": dataset,
        "task": task,
        "root": root,
        "created": datetime.now().isoformat(timespec="seconds"),
        "cameras": load("tactilevla-cams.json"),
        "grid": load("tactilevla-grid.json"),
    },
    open(session_file, "w"),
    indent=2,
)
print(f"registered session -> {session_file}")
PY
fi

echo "SESSION : $DATASET_NAME"
echo "episodes: $NUM_EPISODES"
echo "task    : $TASK_DESC"
echo "cameras : top ${TOP_W}x${TOP_H} (cam $TOP_CAM), wrist ${WRIST_W}x${WRIST_H} (cam $WRIST_CAM)"
echo "log     : $LOG"
echo
echo "Reminder: watch ONLY the camera feeds while teleoperating, never the arm itself."
echo

set -o pipefail
# Keep the Mac awake. Teleop keystrokes usually prevent idle sleep, but the reset
# phases are idle and a display/system sleep mid-session would break the preview
# windows and the control loop.
CAFFEINATE=""
command -v caffeinate >/dev/null 2>&1 && CAFFEINATE="caffeinate -is"

# shellcheck disable=SC2086  # CAFFEINATE and RESUME_ARG are intentionally unquoted
$CAFFEINATE lerobot-record \
  $RESUME_ARG \
  --robot.type=so101_follower \
  --robot.port="$FOLLOWER_PORT" \
  --robot.id=follower_01 \
  --robot.cameras="$CAMERAS" \
  --teleop.type=so101_leader \
  --teleop.port="$LEADER_PORT" \
  --teleop.id=leader_01 \
  --display_data=true \
  --dataset.repo_id="local/$DATASET_NAME" \
  --dataset.root="$DATASET_ROOT" \
  --dataset.num_episodes="$NUM_EPISODES" \
  --dataset.single_task="$TASK_DESC" \
  --dataset.episode_time_s=30 \
  --dataset.reset_time_s=12 \
  --dataset.push_to_hub=false \
  --dataset.streaming_encoding=true \
  --dataset.encoder_threads=2 2>&1 | tee -a "$LOG"
