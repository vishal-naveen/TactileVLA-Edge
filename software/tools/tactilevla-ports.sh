#!/bin/bash
# Resolve the two serial ports. Prints "<follower_port> <leader_port>".
#
# Every script that talks to an arm calls this instead of hardcoding, so a replug
# is a one-command fix (`python3 ~/tactilevla-findports.py --write`) rather than
# a six-file edit:
#
#   read -r FOLLOWER_PORT LEADER_PORT <<<"$(bash ~/tactilevla-ports.sh)" || exit 1
#
# Exits non-zero with an explanation on stderr if the ports are missing from the
# config or absent from /dev - failing here is much cheaper than failing 40
# episodes into a session.
set -e

PORTS_JSON="$HOME/tactilevla-ports.json"

if [ ! -f "$PORTS_JSON" ]; then
  {
    echo "Missing $PORTS_JSON - cannot know which arm is which."
    echo "  Plug in both arms (power bricks first), then:"
    echo "    python3 ~/tactilevla-findports.py --write"
  } >&2
  exit 1
fi

LINE="$(python3 - "$PORTS_JSON" <<'PY'
import json
import sys

cfg = json.load(open(sys.argv[1]))
try:
    print(cfg["follower"]["port"], cfg["leader"]["port"])
except KeyError as exc:
    sys.exit(f"missing key {exc} in ports config")
PY
)" || { echo "Could not parse $PORTS_JSON" >&2; exit 1; }

read -r F L <<<"$LINE"
if [ -z "$L" ]; then
  echo "Could not read both ports from $PORTS_JSON" >&2
  exit 1
fi

# A stale port name is the whole failure mode this file exists to prevent, so
# check the devices actually exist before handing them back.
MISSING=""
[ -e "$F" ] || MISSING="follower ($F)"
[ -e "$L" ] || MISSING="${MISSING:+$MISSING and }leader ($L)"
if [ -n "$MISSING" ]; then
  {
    echo "Port not present: $MISSING"
    echo "  macOS renumbers usbmodem names on replug. Re-detect and save:"
    echo "    python3 ~/tactilevla-findports.py --write"
    echo "  (identifies the arms by voltage, so it is correct even after a swap)"
  } >&2
  exit 1
fi

echo "$F $L"
