#!/bin/bash
set -e

# Ports from ~/tactilevla-ports.json (macOS renumbers usbmodem names on replug;
# re-detect with `python3 ~/tactilevla-findports.py --write`).
PORTS_LINE="$(bash "$HOME/tactilevla-ports.sh")" || exit 1
read -r FOLLOWER_PORT LEADER_PORT <<<"$PORTS_LINE"
FOLLOWER_ID="follower_01"
LEADER_ID="leader_01"

lerobot-teleoperate \
  --robot.type=so101_follower \
  --robot.port="$FOLLOWER_PORT" \
  --robot.id="$FOLLOWER_ID" \
  --teleop.type=so101_leader \
  --teleop.port="$LEADER_PORT" \
  --teleop.id="$LEADER_ID"
