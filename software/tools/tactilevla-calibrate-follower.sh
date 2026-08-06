#!/bin/bash
set -e

lerobot-calibrate \
  --robot.type=so101_follower \
  --robot.port="/dev/tty.usbmodem5B7B0154811" \
  --robot.id="follower_01"
