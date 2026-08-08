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

# Ports come from ~/tactilevla-ports.json, same single-source-of-truth pattern as
# the cameras. macOS renumbers /dev/tty.usbmodem* on replug; after any replug run
#   python3 ~/tactilevla-findports.py --write
# which tells the arms apart by voltage (12 V follower / 5 V leader) rather than
# by port name, so it is right even when the names have swapped.
PORTS_LINE="$(bash "$HOME/tactilevla-ports.sh")" || exit 1
read -r FOLLOWER_PORT LEADER_PORT <<<"$PORTS_LINE"

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

# On RESUME, check today's camera config against the one snapshotted when the
# session was created. Rounds 2-4 rebuild CAMERAS from whatever cams.json says at
# that moment, and macOS has already renumbered these cameras once mid-project.
# Appending 40 episodes with top/wrist reversed is unrecoverable and invisible:
# the dataset keys are still called "top" and "wrist", they just contain the
# wrong views for part of the run. Nothing else compares these, so this is the
# only place it can be caught.
if [ "$RESUME" = "resume" ]; then
  if ! python3 - "$SESSION_FILE" "$CAMS_JSON" <<'PY'
import json
import sys

session, cams_path = sys.argv[1], sys.argv[2]
was = (json.load(open(session)) or {}).get("cameras")
now = json.load(open(cams_path))
if was is None:
    print("  WARNING: session has no camera snapshot (recorded before this check existed).")
    print("           Confirm roles with `python3 ~/tactilevla-camview.py` before continuing.")
    sys.exit(0)

fields = ("index", "width", "height")
diffs = [
    f"    {role}.{f}: was {was[role][f]} -> now {now[role][f]}"
    for role in ("top", "wrist")
    for f in fields
    if was.get(role, {}).get(f) != now.get(role, {}).get(f)
]
if diffs:
    print("REFUSING TO RESUME - the camera config changed since this session started:")
    print("\n".join(diffs))
    print()
    print("  If macOS renumbered the cameras, fix ~/tactilevla-cams.json so the ROLES")
    print("  match reality again (verify with `python3 ~/tactilevla-camview.py`), then")
    print("  resume. The indices only need to match the ROLE, not the old number.")
    print("  If the change is deliberate, re-snapshot with: FORCE_CAMS=1 <same command>")
    sys.exit(1)
print("cameras : match the session snapshot")
PY
  then
    [ "${FORCE_CAMS:-}" = "1" ] || exit 1
    echo "FORCE_CAMS=1 - continuing despite the camera mismatch."
  fi
fi

CAMERAS="{ top: {type: opencv, index_or_path: $TOP_CAM, width: $TOP_W, height: $TOP_H, fps: 30}, wrist: {type: opencv, index_or_path: $WRIST_CAM, width: $WRIST_W, height: $WRIST_H, fps: 30}}"

# Console output is teed to a log because it is the ONLY place the achieved loop
# rate is reported. The dataset's `timestamp` column is nominal (frame_index/fps),
# so it reads as a perfect 33.3 ms even when the loop was actually running at
# 18 Hz - the drop is invisible in the data and visible only in this log, as
# "Record loop is running slower (X Hz)". ~/tactilevla-checkdata.py reads it.
# Time LIMITS, not fixed durations - the right arrow ends either phase early, so a
# generous limit costs nothing when you are quick and rescues you when you are not.
#
# RESET_TIME is the window to drive the arm back to home, reposition the noodle at a
# new spot in the cell, and set its yaw - then get your hands clear. At 12 s that is
# tight, and running out does not pause: it drops straight into the next RECORDING
# episode, so your hands, a half-placed noodle, and an arm not at home all land in
# the dataset. 25 s is the same session length in practice and removes that cliff.
#
# EPISODE_TIME is a safety net; real episodes run ~13 s and you end them with the
# right arrow. Note that hitting the limit does NOT discard - the episode is saved
# exactly as truncated, so end episodes deliberately rather than letting them expire.
EPISODE_TIME="${EPISODE_TIME:-30}"
RESET_TIME="${RESET_TIME:-25}"
# One-off staging pause before the FIRST episode of a run. lerobot-record otherwise
# starts capturing the moment the leader connects, so episode 1 of every round caught
# the object being placed and the arm being driven to home. Teleop is live and nothing
# is recorded; [->] ends it early, so a generous limit costs nothing.
START_SETUP="${START_SETUP:-45}"

LOG_DIR="$HOME/tactilevla-logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/${DATASET_NAME}-record.log"

# Cell staging plan. lerobot-record prints the cell to stage in the SETUP banner
# (look-ahead, which is when you actually place the object) and confirms it in the
# RECORDING banner, then appends episode -> cell to CELL_LOG.
#
# The order is the perimeter of the 3x3 grid, counter-clockwise from A1, with the
# centre cell B2 left out as the hold-out:
#
#         A       B       C
#  far  [A1] <- [B1] <-  [C1]        A1 -> A2 -> A3 -> B3 -> C3 -> C2 -> C1 -> B1
#       [A2]    [B2]*    [C2]  ^     * B2 = hold-out, record NOTHING here
#  near [A3] -> [B3] ->  [C3]  |
#
# Indexing is off the dataset episode count, so it keeps its place across resume,
# and every second round of 40 is walked in the opposite direction automatically.
CELL_PLAN="${CELL_PLAN:-A1,A2,A3,B3,C3,C2,C1,B1}"
EPISODES_PER_CELL="${EPISODES_PER_CELL:-5}"
CELL_LOG="$LOG_DIR/${DATASET_NAME}-cells.csv"

# Object rotation per episode, spanning -90..+90 deg. That full 180 deg is the whole
# space that matters for an elongated object: the graspable long axis has a 180 deg
# period, so +100 presents the same axis as -80. A narrower sweep leaves orientations
# the policy has never seen, and ACT does not extrapolate them.
#
# Indexed by how many episodes the CELL has had (round * per_cell + take), NOT by take,
# so all 20 values get used across 4 rounds -> 20 distinct orientations per cell at
# 10 deg spacing, instead of 5 angles repeated four times.
#
# ORDER IS DELIBERATELY INTERLEAVED, not monotonic. Read five at a time:
#   round 1: -90 -50 -10 +30 +70      round 3: -70 -30 +10 +50 +90
#   round 2: -80 -40   0 +40 +80      round 4: -60 -20 +20 +60   0
# Every round spans the full range. Sorted order would give round 1 only steep
# negative angles, aliasing orientation with the round - and would leave a dataset
# that is useless if you had to stop after one round.
CELL_ROTATIONS="${CELL_ROTATIONS:--90,-50,-10,+30,+70,-80,-40,0,+40,+80,-70,-30,+10,+50,+90,-60,-20,+20,+60,0}"

# Register the session on creation, snapshotting the camera and grid config it was
# recorded under. Later mismatches (a camera renumbering, a re-clicked grid) then
# show up as a diff against this record instead of being invisible.
if [ "$RESUME" != "resume" ]; then
  # Starting fresh OVERWRITES the session registry, which is the single pointer
  # that checkdata / train-act / eval all follow. Typing the round-1 command
  # again instead of `resume` would mint a new timestamped dataset AND orphan the
  # episodes already recorded - they stay on disk but nothing points at them
  # again. The timestamp means there is no filename collision to catch it, so
  # guard it here.
  if [ -f "$SESSION_FILE" ]; then
    PRIOR="$(python3 - "$SESSION_FILE" <<'PY' || true
import json
import sys
from pathlib import Path

s = json.load(open(sys.argv[1]))
root = Path(s["root"])
info = root / "meta" / "info.json"
n = json.loads(info.read_text())["total_episodes"] if info.exists() else 0
if n:
    print(f"{s['dataset']}|{n}|{s['created']}")
PY
)"
    if [ -n "$PRIOR" ]; then
      IFS='|' read -r P_NAME P_EPS P_WHEN <<<"$PRIOR"
      echo "REFUSING TO START A NEW SESSION - one is already active with real data:"
      echo "    session : $P_NAME"
      echo "    episodes: $P_EPS  (created $P_WHEN)"
      echo
      echo "  To ADD to it (this is almost always what you want):"
      echo "    bash ~/tactilevla-record.sh resume $P_NAME 40"
      echo
      echo "  To deliberately start a SEPARATE dataset (e.g. the B2 holdout set),"
      echo "  keeping the one above recoverable:"
      echo "    FORCE_NEW=1 bash ~/tactilevla-record.sh $BASE_NAME $NUM_EPISODES \"$TASK_DESC\""
      [ "${FORCE_NEW:-}" = "1" ] || exit 1
      echo
      echo "FORCE_NEW=1 - starting a new session. Previous session ID recorded above."
      cp "$SESSION_FILE" "${SESSION_FILE%.json}.prev-$(date +%Y%m%d_%H%M).json"
    fi
  fi
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
echo "cells   : $CELL_PLAN  ($EPISODES_PER_CELL each, reversed every $(( EPISODES_PER_CELL * $(echo "$CELL_PLAN" | tr ',' '\n' | grep -c .) )) episodes)"
echo "cell log: $CELL_LOG"
echo
echo "Reminder: watch ONLY the camera feeds while teleoperating, never the arm itself."
echo

set -o pipefail
# Keep the Mac awake. Teleop keystrokes usually prevent idle sleep, but the reset
# phases are idle and a display/system sleep mid-session would break the preview
# windows and the control loop.
CAFFEINATE=""
command -v caffeinate >/dev/null 2>&1 && CAFFEINATE="caffeinate -is"

# Video codec. The default (libsvtav1, software AV1) is CPU-heavy, and when the
# encoder queue fills LeRobot DROPS the frame instead of blocking - no exception,
# but the parquet row is still written, so video and actions desync for the rest
# of that episode and it only surfaces as a decode error hours into training.
# VCODEC=auto picks h264_videotoolbox (Apple Silicon hardware encoder), which
# removes that whole failure mode at the cost of larger files - irrelevant at
# ~1 GB total. Files stay mergeable: merge_datasets() excuses codec differences.
#   VCODEC=auto bash ~/tactilevla-record.sh ...   <- test this in the shakedown
VCODEC_ARG=""
[ -n "${VCODEC:-}" ] && VCODEC_ARG="--dataset.camera_encoder.vcodec=$VCODEC"
[ -n "${VCODEC:-}" ] && echo "codec   : $VCODEC (overriding the libsvtav1 default)"

# PYTHONUNBUFFERED is load-bearing, not cosmetic. Every phase banner and every
# arrow-key confirmation in the patched lerobot_record.py is a bare print() to
# stdout, and `| tee` below makes stdout block-buffered - so without this the
# operator sees NOTHING for the whole session and the output all arrives at
# once when the process exits. That includes the confirmation for the key that
# discards a take. logging (stderr) is unaffected either way.
# shellcheck disable=SC2086  # CAFFEINATE, RESUME_ARG and VCODEC_ARG are intentionally unquoted
PYTHONUNBUFFERED=1 \
TACTILEVLA_CELL_PLAN="$CELL_PLAN" \
TACTILEVLA_EPISODES_PER_CELL="$EPISODES_PER_CELL" \
TACTILEVLA_ROTATIONS="$CELL_ROTATIONS" \
TACTILEVLA_CELL_LOG="$CELL_LOG" \
TACTILEVLA_START_SETUP_S="$START_SETUP" \
$CAFFEINATE lerobot-record \
  $RESUME_ARG \
  $VCODEC_ARG \
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
  --dataset.episode_time_s="$EPISODE_TIME" \
  --dataset.reset_time_s="$RESET_TIME" \
  --dataset.push_to_hub=false \
  --dataset.streaming_encoding=true \
  --dataset.encoder_threads=2 2>&1 | tee -a "$LOG"
