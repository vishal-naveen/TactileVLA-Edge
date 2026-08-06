#!/bin/bash
# Teleoperate with both cameras + live rerun visualizer.
#
# Index 2 is the MacBook built-in webcam and must NOT be used.
# macOS renumbers cameras when they are replugged - verify with
#   python3 ~/tactilevla-camview.py 0 1
# and swap TOP_CAM / WRIST_CAM below if they are reversed.
set -e

FOLLOWER_PORT="/dev/tty.usbmodem5B7B0154811"
LEADER_PORT="/dev/tty.usbmodem5B7B0137031"

TOP_CAM=0      # overhead / workspace view  -> landscape 1920x1080
WRIST_CAM=1    # wrist-mounted view        -> portrait  1080x1920 (rotated)

# 640x480 to match the recording config - see tactilevla-record.sh for why.

lerobot-teleoperate \
  --robot.type=so101_follower \
  --robot.port="$FOLLOWER_PORT" \
  --robot.id=follower_01 \
  --robot.cameras="{ top: {type: opencv, index_or_path: $TOP_CAM, width: 640, height: 480, fps: 30}, wrist: {type: opencv, index_or_path: $WRIST_CAM, width: 640, height: 480, fps: 30}}" \
  --teleop.type=so101_leader \
  --teleop.port="$LEADER_PORT" \
  --teleop.id=leader_01 \
  --display_data=true
