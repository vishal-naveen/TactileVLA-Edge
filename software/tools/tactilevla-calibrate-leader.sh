#!/bin/bash
set -e

lerobot-calibrate \
  --teleop.type=so101_leader \
  --teleop.port="/dev/tty.usbmodem5B7B0137031" \
  --teleop.id="leader_01"
