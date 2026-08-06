#!/bin/bash
# Open the three preview windows in their own Terminal windows, so each can be
# quit independently and none of them ties up the terminal you record from.
#
#   bash ~/tactilevla-cams-up.sh          # grid + top + wrist
#   bash ~/tactilevla-cams-up.sh grid     # just the grid overlay
#   bash ~/tactilevla-cams-up.sh cams     # just the two camera previews
#
# Safe to leave running during a recording session. Measured on this Mac: two and
# three simultaneous readers on the overhead camera all held 30.0 fps, so sharing
# a camera between the previews and the recorder costs no frames. They do use some
# CPU, so if checkdata reports MID-EPISODE stalls, close these first.
#
# Quit a window with 'q' in the preview, or just close the Terminal window.
set -e

CAMS_JSON="$HOME/tactilevla-cams.json"
if [ ! -f "$CAMS_JSON" ]; then
  echo "Missing $CAMS_JSON"
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

WHAT="${1:-all}"

# Each window runs in its own login shell so conda (and therefore python3 with cv2)
# is on PATH exactly as it is in an interactive terminal.
launch() {
  local title="$1" cmd="$2"
  osascript >/dev/null <<OSA
tell application "Terminal"
    do script "echo '=== $title ==='; $cmd"
    activate
end tell
OSA
  echo "  launched: $title"
}

echo "top camera   : index $TOP_CAM"
echo "wrist camera : index $WRIST_CAM"
echo

case "$WHAT" in
  grid)
    launch "GRID overlay (cam $TOP_CAM)" "python3 ~/tactilevla-grid.py"
    ;;
  cams)
    launch "TOP camera (cam $TOP_CAM)" "python3 ~/tactilevla-camview.py $TOP_CAM"
    launch "WRIST camera (cam $WRIST_CAM)" "python3 ~/tactilevla-camview.py $WRIST_CAM"
    ;;
  all)
    launch "GRID overlay (cam $TOP_CAM)" "python3 ~/tactilevla-grid.py"
    launch "TOP camera (cam $TOP_CAM)" "python3 ~/tactilevla-camview.py $TOP_CAM"
    launch "WRIST camera (cam $WRIST_CAM)" "python3 ~/tactilevla-camview.py $WRIST_CAM"
    ;;
  *)
    echo "Unknown argument '$WHAT' - use: all | grid | cams"
    exit 1
    ;;
esac

cat <<EOF

Windows may open stacked - drag them apart once and macOS remembers the layout.
Each preview window needs focus before its keys work ('q' quit, 's' snapshot).

To close everything at once:
  pkill -f tactilevla-grid.py; pkill -f tactilevla-camview.py
EOF
