#!/usr/bin/env python3
"""Identify which serial port is the follower and which is the leader.

    python3 ~/tactilevla-findports.py            # detect and report (read-only)
    python3 ~/tactilevla-findports.py --write     # save to ~/tactilevla-ports.json

macOS assigns /dev/tty.usbmodem* names from the USB topology, so they CHANGE when
you replug, use a different hub port, or reboot. Six scripts used to hardcode
them, which meant a replug was a six-file edit - the same problem the camera
indices had before tactilevla-cams.json existed.

The arms are told apart by VOLTAGE, not by port name, because they run on
different power bricks:

    follower  12 V white brick  ->  Present_Voltage ~119-120  (units of 0.1 V)
    leader     5 V black brick  ->  Present_Voltage ~49

That is a physical property of the rig, so it stays correct across any amount of
renumbering. Guessing by port name, order, or which one enumerated first does
not - and recording a session with the two arms swapped is unrecoverable.

Read-only by default: it never writes the config unless you pass --write. The
grid config got silently overwritten twice by tools that saved on their own
initiative, so this one asks.
"""

from __future__ import annotations

import argparse
import glob
import json
import sys
from pathlib import Path

from lerobot.motors import Motor, MotorNormMode
from lerobot.motors.feetech import FeetechMotorsBus

PORTS_JSON = Path.home() / "tactilevla-ports.json"
JOINTS = ("shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper")

# Present_Voltage is in units of 0.1 V. Bands are wide enough for brick sag and
# narrow enough that 12 V and 5 V can never be confused.
FOLLOWER_BAND = (100, 140)  # 10.0 - 14.0 V
LEADER_BAND = (40, 60)  # 4.0 - 6.0 V


def build_bus(port: str) -> FeetechMotorsBus:
    motors = {name: Motor(i + 1, "sts3215", MotorNormMode.DEGREES) for i, name in enumerate(JOINTS)}
    motors["gripper"] = Motor(6, "sts3215", MotorNormMode.RANGE_0_100)
    return FeetechMotorsBus(port=port, motors=motors)


def probe(port: str) -> dict | None:
    """Read voltage from one port. Torque stays disabled; nothing moves."""
    bus = build_bus(port)
    try:
        bus.connect(handshake=False)
    except Exception as exc:
        return {"port": port, "error": f"{type(exc).__name__}: {exc}"}
    try:
        bus.disable_torque()
        volts = bus.sync_read("Present_Voltage", normalize=False)
        temps = bus.sync_read("Present_Temperature", normalize=False)
        v = max(volts.values())
        role = None
        if FOLLOWER_BAND[0] <= v <= FOLLOWER_BAND[1]:
            role = "follower"
        elif LEADER_BAND[0] <= v <= LEADER_BAND[1]:
            role = "leader"
        return {
            "port": port,
            "volts": int(v),
            "role": role,
            "motors": len(volts),
            "max_temp": int(max(temps.values())),
        }
    except Exception as exc:
        return {"port": port, "error": f"{type(exc).__name__}: {exc}"}
    finally:
        try:
            bus.disconnect()
        except Exception:
            pass


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true", help="save the result to ~/tactilevla-ports.json")
    args = ap.parse_args()

    candidates = sorted(set(glob.glob("/dev/tty.usbmodem*")))
    print("=" * 62)
    print("TactileVLA-Edge port finder (read-only, torque stays disabled)")
    print("=" * 62)
    if not candidates:
        print("\nNo /dev/tty.usbmodem* ports found.")
        print("  Power bricks first (12 V white -> follower, 5 V black -> leader),")
        print("  then both USB cables. Then re-run this.")
        return 1

    print(f"\nprobing {len(candidates)} port(s)...\n")
    found: dict[str, dict] = {}
    for port in candidates:
        r = probe(port)
        if r.get("error"):
            print(f"  {port}\n      not an arm ({r['error'][:60]})")
            continue
        label = r["role"] or "UNKNOWN"
        print(f"  {port}\n      {r['volts'] / 10:.1f} V, {r['motors']} motors, {r['max_temp']} C  ->  {label}")
        if r["role"]:
            if r["role"] in found:
                print(f"\nTWO ports both look like the {r['role']}. Cannot choose between them.")
                print("  Unplug one arm, re-run, then plug it back and re-run.")
                return 1
            found[r["role"]] = r

    print()
    missing = [role for role in ("follower", "leader") if role not in found]
    if missing:
        print(f"MISSING: {', '.join(missing)}")
        print("  Check the power brick is on and the USB cable is seated.")
        print("  An arm with no power enumerates as a serial port but answers nothing.")
        return 1

    old = json.loads(PORTS_JSON.read_text()) if PORTS_JSON.exists() else {}
    changed = any(old.get(role, {}).get("port") != found[role]["port"] for role in found)

    print("RESULT")
    for role in ("follower", "leader"):
        was = old.get(role, {}).get("port")
        now = found[role]["port"]
        mark = "  (unchanged)" if was == now else (f"  (was {was})" if was else "  (new)")
        print(f"  {role:<9} {now}{mark}")

    if not args.write:
        print()
        if changed or not PORTS_JSON.exists():
            print("Ports differ from the saved config. To save:")
            print("  python3 ~/tactilevla-findports.py --write")
        else:
            print(f"{PORTS_JSON.name} is already correct - nothing to do.")
        return 0

    payload = {
        "_comment": (
            "SINGLE SOURCE OF TRUTH for serial port -> arm role. Regenerate with "
            "`python3 ~/tactilevla-findports.py --write` after any replug. Roles are "
            "identified by VOLTAGE (follower 12 V ~119, leader 5 V ~49), not by port "
            "name, because macOS renumbers usbmodem names on replug."
        ),
        "follower": {"port": found["follower"]["port"], "volts": found["follower"]["volts"]},
        "leader": {"port": found["leader"]["port"], "volts": found["leader"]["volts"]},
    }
    if PORTS_JSON.exists():
        (PORTS_JSON.parent / (PORTS_JSON.name + ".bak")).write_text(PORTS_JSON.read_text())
    PORTS_JSON.write_text(json.dumps(payload, indent=2) + "\n")
    print(f"\nwrote {PORTS_JSON}")
    print("Every script reads this file, so nothing else needs editing.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
