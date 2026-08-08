#!/usr/bin/env python3
"""Go/no-go test: does Present_Load actually respond to force?

The whole servo-load tactile plan depends on this. With torque disabled the
registers read 0 (a limp motor exerts no force), so this script enables torque
so each joint HOLDS its current position, then streams load while you push.

It never commands the arm to move - it only asks it to hold where it already is.

    python3 ~/tactilevla-loadtest.py

While it runs: squeeze the gripper jaws closed with your fingers, and gently
push against the wrist and elbow. Watch whether the numbers move off zero.
Ctrl-C to stop (torque is released on exit).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
import time

from lerobot.motors import Motor, MotorNormMode
from lerobot.motors.feetech import FeetechMotorsBus

# Port from ~/tactilevla-ports.json; see ~/tactilevla-findports.py.
_PORTS = Path.home() / "tactilevla-ports.json"
FOLLOWER_PORT = json.loads(_PORTS.read_text())["follower"]["port"]
JOINTS = ("shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper")

DURATION_S = 60


def main() -> int:
    motors = {name: Motor(i + 1, "sts3215", MotorNormMode.DEGREES) for i, name in enumerate(JOINTS)}
    motors["gripper"] = Motor(6, "sts3215", MotorNormMode.RANGE_0_100)
    bus = FeetechMotorsBus(port=FOLLOWER_PORT, motors=motors)

    print("Connecting to follower...")
    bus.connect(handshake=False)

    peak: dict[str, int] = dict.fromkeys(JOINTS, 0)
    try:
        # Hold current position: torque on, target = where each joint already is.
        held = bus.sync_read("Present_Position", normalize=False)
        bus.enable_torque()
        for name, pos in held.items():
            bus.write("Goal_Position", name, int(pos), normalize=False)

        print("\nTorque ENABLED - the arm is now holding position (it will feel stiff).")
        print("SQUEEZE THE GRIPPER JAWS and push gently on the wrist/elbow.\n")
        print("If these numbers stay at 0 no matter what you do, servo-load")
        print("sensing will not work and we need real force sensors instead.\n")
        print(f"{'time':>5s}  " + "  ".join(f"{n[:9]:>9s}" for n in JOINTS))

        start = time.perf_counter()
        while time.perf_counter() - start < DURATION_S:
            loads = bus.sync_read("Present_Load", normalize=False)
            for name, value in loads.items():
                peak[name] = max(peak[name], abs(int(value)))
            elapsed = time.perf_counter() - start
            row = "  ".join(f"{int(loads[n]):>9d}" for n in JOINTS)
            print(f"{elapsed:5.1f}  {row}")
            time.sleep(0.25)
    except KeyboardInterrupt:
        print("\nstopped by user")
    finally:
        print("\nReleasing torque...")
        try:
            bus.disable_torque()
        except Exception:
            pass
        try:
            bus.disconnect()
        except Exception:
            pass

    print("\n" + "=" * 58)
    print("PEAK |load| observed per joint:")
    for name in JOINTS:
        print(f"  {name:15s} {peak[name]}")
    print("=" * 58)
    if max(peak.values()) == 0:
        print("\nRESULT: NO SIGNAL. Present_Load never moved off zero.")
        print("Servo-load tactile sensing is NOT viable - plan on FSRs instead.")
        return 1
    if peak["gripper"] == 0:
        print("\nRESULT: PARTIAL. Some joints respond but the GRIPPER never did.")
        print("Gripper load is the most useful channel for grasping - investigate.")
        return 1
    print("\nRESULT: SIGNAL PRESENT. Servo-load tactile sensing is viable.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
