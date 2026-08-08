#!/bin/bash
set -e

# Ports from ~/tactilevla-ports.json (macOS renumbers usbmodem names on replug;
# re-detect with `python3 ~/tactilevla-findports.py --write`).
PORTS_LINE="$(bash "$HOME/tactilevla-ports.sh")" || exit 1
read -r FOLLOWER_PORT LEADER_PORT <<<"$PORTS_LINE"

lerobot-calibrate \
  --robot.type=so101_follower \
  --robot.port="$FOLLOWER_PORT" \
  --robot.id="follower_01"
