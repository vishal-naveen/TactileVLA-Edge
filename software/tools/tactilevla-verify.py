#!/usr/bin/env python3
"""End-to-end link check: arms, servos, servo-load sensing, and cameras.

Read-only. Keeps motor torque DISABLED throughout, so the arms stay limp and
nothing moves. Run it with both arms powered and both cameras connected:

    python3 ~/tactilevla-verify.py
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import cv2

from lerobot.motors import Motor, MotorNormMode
from lerobot.motors.feetech import FeetechMotorsBus

FOLLOWER_PORT = "/dev/tty.usbmodem5B7B0154811"
LEADER_PORT = "/dev/tty.usbmodem5B7B0137031"

# Camera roles, indices and resolutions come from one shared file so a macOS
# renumbering is a one-line fix instead of six. See ~/tactilevla-cams.json.
CAMS_JSON = Path.home() / "tactilevla-cams.json"
_cams = json.loads(CAMS_JSON.read_text())
TOP_CAM = _cams["top"]["index"]
WRIST_CAM = _cams["wrist"]["index"]
RECORD_RES = {
    role: (
        tuple(int(v) for v in os.environ[f"{role.upper()}_RES"].split("x"))
        if f"{role.upper()}_RES" in os.environ
        else (_cams[role]["width"], _cams[role]["height"])
    )
    for role in ("top", "wrist")
}

JOINTS = ("shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper")

# STS3215 Max_Temperature_Limit defaults to 70 C. Stay well under it.
TEMP_WARN_C = 50
TEMP_STOP_C = 60


def build_bus(port: str) -> FeetechMotorsBus:
    motors = {name: Motor(i + 1, "sts3215", MotorNormMode.DEGREES) for i, name in enumerate(JOINTS)}
    motors["gripper"] = Motor(6, "sts3215", MotorNormMode.RANGE_0_100)
    return FeetechMotorsBus(port=port, motors=motors)


def check_arm(label: str, port: str) -> bool:
    print(f"\n--- {label} @ {port} ---")
    bus = build_bus(port)
    try:
        bus.connect(handshake=False)
    except Exception as exc:
        print(f"  FAIL connect: {type(exc).__name__}: {exc}")
        return False

    ok = True
    try:
        bus.disable_torque()  # keep the arm limp for a pure read

        try:
            positions = bus.sync_read("Present_Position", normalize=False)
            print(f"  positions : {[f'{k}={v}' for k, v in positions.items()]}")
        except Exception as exc:
            print(f"  FAIL reading Present_Position: {type(exc).__name__}: {exc}")
            ok = False

        # Temperature matters for long recording sessions: STS3215s throttle and
        # eventually fault when hot, and a 140-episode session is long enough to
        # get there. Feetech's own Max_Temperature_Limit default is 70 C.
        try:
            temps = bus.sync_read("Present_Temperature", normalize=False)
            hottest = max(temps.values())
            if hottest >= TEMP_STOP_C:
                note = f"  <- TOO HOT (>={TEMP_STOP_C} C), stop and let it cool"
            elif hottest >= TEMP_WARN_C:
                note = f"  <- warm (>={TEMP_WARN_C} C), take a break soon"
            else:
                note = ""
            print(f"  Present_Temp (C) : {dict(temps)}  max={hottest}{note}")
            if hottest >= TEMP_STOP_C:
                ok = False
        except Exception as exc:
            print(f"  WARN reading Present_Temperature: {type(exc).__name__}: {exc}")

        # This is the signal the tactile plan depends on.
        for register in ("Present_Load", "Present_Current", "Present_Voltage"):
            try:
                values = bus.sync_read(register, normalize=False)
                print(f"  {register:16s}: {dict(values)}")
            except Exception as exc:
                print(f"  FAIL reading {register}: {type(exc).__name__}: {exc}")
                if register == "Present_Load":
                    ok = False
    finally:
        try:
            bus.disconnect()
        except Exception:
            pass
    return ok


def check_camera(label: str, index: int) -> bool:
    cap = cv2.VideoCapture(index)
    if not cap.isOpened():
        print(f"  FAIL {label} (index {index}): could not open")
        return False
    # Open at the resolution that will actually be RECORDED (see
    # ~/tactilevla-record.sh), not 1080p. Checking a camera at a resolution you
    # never record with tells you nothing about the recording.
    width_req, height_req = RECORD_RES[label]
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width_req)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height_req)
    for _ in range(5):
        cap.read()
    good, frame = cap.read()
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    cap.release()
    if not good:
        print(f"  FAIL {label} (index {index}): opened but no frame")
        return False
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    brightest = int(gray.max())
    focus = float(cv2.Laplacian(gray, cv2.CV_64F).var())
    size_note = "" if (width, height) == (width_req, height_req) else "  <- NOT the requested size"
    verdict = "OK" if brightest >= 20 else "DARK - lens blocked?"
    print(
        f"  {label:6s} idx={index}  {width}x{height}  bright_max={brightest:3d}  "
        f"focus={focus:6.0f}  {verdict}{size_note}"
    )
    # focus is Laplacian variance, which measures how much EDGE DETAIL is in view.
    # It is not comparable between cameras: an overhead camera aimed at a blank
    # white table scores low no matter how sharp it is, while a wrist camera
    # filled with the textured gripper scores high. So it is reported, never
    # asserted on. Compare a camera only against ITSELF on the same scene - that
    # is what makes it useful for confirming a refocus actually helped.
    return brightest >= 20 and (width, height) == (width_req, height_req)


def main() -> int:
    print("=" * 62)
    print("TactileVLA-Edge link check (read-only, torque stays disabled)")
    print("=" * 62)

    follower_ok = check_arm("FOLLOWER", FOLLOWER_PORT)
    leader_ok = check_arm("LEADER", LEADER_PORT)

    print("\n--- CAMERAS ---")
    top_ok = check_camera("top", TOP_CAM)
    wrist_ok = check_camera("wrist", WRIST_CAM)

    print("\n" + "=" * 62)
    results = {
        "follower arm": follower_ok,
        "leader arm": leader_ok,
        "top camera": top_ok,
        "wrist camera": wrist_ok,
    }
    for name, passed in results.items():
        print(f"  {'PASS' if passed else 'FAIL'}  {name}")
    print("=" * 62)

    if all(results.values()):
        print("\nEverything linked. Ready to record.")
        return 0
    print("\nSomething is not linked - see failures above.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
