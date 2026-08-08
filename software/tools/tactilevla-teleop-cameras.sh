#!/bin/bash
# Teleoperate with both cameras + live rerun visualizer. No recording.
#
#   bash ~/tactilevla-teleop-cameras.sh
#
# Everything comes from the two config files, nothing is hardcoded here:
#   ~/tactilevla-cams.json   camera role -> index + resolution
#   ~/tactilevla-ports.json  arm role    -> serial port
#
# This script previously hardcoded TOP_CAM=0 / WRIST_CAM=1 and 640x480, which
# had drifted to the exact REVERSE of cams.json (top is index 1 at 800x600). It
# was the only camera-touching script not reading the config, so it would have
# shown the wrist feed in a window labelled "top" - the same silent mislabelling
# that cams.json was created to make impossible.
set -e

CAMS_JSON="$HOME/tactilevla-cams.json"
[ -f "$CAMS_JSON" ] || { echo "Missing $CAMS_JSON - cannot know which camera is which."; exit 1; }

PORTS_LINE="$(bash "$HOME/tactilevla-ports.sh")" || exit 1
read -r FOLLOWER_PORT LEADER_PORT <<<"$PORTS_LINE"

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
[ -n "$WRIST_H" ] || { echo "Could not read camera config from $CAMS_JSON"; exit 1; }

echo "cameras : top ${TOP_W}x${TOP_H} (cam $TOP_CAM), wrist ${WRIST_W}x${WRIST_H} (cam $WRIST_CAM)"
echo "arms    : follower $FOLLOWER_PORT, leader $LEADER_PORT"
echo
echo "The window labelled 'top' must show the table from above."
echo "If it shows the gripper, the indices are swapped - fix ~/tactilevla-cams.json."
echo

lerobot-teleoperate \
  --robot.type=so101_follower \
  --robot.port="$FOLLOWER_PORT" \
  --robot.id=follower_01 \
  --robot.cameras="{ top: {type: opencv, index_or_path: $TOP_CAM, width: $TOP_W, height: $TOP_H, fps: 30}, wrist: {type: opencv, index_or_path: $WRIST_CAM, width: $WRIST_W, height: $WRIST_H, fps: 30}}" \
  --teleop.type=so101_leader \
  --teleop.port="$LEADER_PORT" \
  --teleop.id=leader_01 \
  --display_data=true
