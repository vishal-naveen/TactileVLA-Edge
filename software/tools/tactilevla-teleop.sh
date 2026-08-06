#!/bin/bash
set -e

FOLLOWER_PORT="/dev/tty.usbmodem5B7B0154811"
LEADER_PORT="/dev/tty.usbmodem5B7B0137031"
FOLLOWER_ID="follower_01"
LEADER_ID="leader_01"

lerobot-teleoperate \
  --robot.type=so101_follower \
  --robot.port="$FOLLOWER_PORT" \
  --robot.id="$FOLLOWER_ID" \
  --teleop.type=so101_leader \
  --teleop.port="$LEADER_PORT" \
  --teleop.id="$LEADER_ID"
