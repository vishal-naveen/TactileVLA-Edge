#!/usr/bin/env python3
"""Measure what the cameras actually deliver, at the resolution you will record at.

    python3 ~/tactilevla-camcheck.py                    # full check, ~60s
    python3 ~/tactilevla-camcheck.py --seconds 20       # shorter
    python3 ~/tactilevla-camcheck.py --top-res 1280x720 # test a different mode
    python3 ~/tactilevla-camcheck.py --modes            # just probe supported modes

Three phases, because a camera that is fine alone can fail alongside another:

  1. camera 0 alone
  2. camera 1 alone
  3. BOTH together  <- the only number that matters; recording runs both

This mirrors how LeRobot actually captures (camera_opencv.py:434-475): one
background read thread per camera plus cv2.setNumThreads(1), not a single
sequential loop. Measuring it any other way gives numbers that don't transfer.

Also reports two things that cannot be fixed in software on macOS, because
AVFoundation makes every camera control read-only:

  - brightness drift: auto-exposure wandering over the session. Cannot be locked,
    so the fix is physical - blinds closed, artificial light only.
  - focus jitter: autofocus hunting. Keep the scene STILL during the test, or a
    changing scene will look like hunting.
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
from pathlib import Path
from threading import Event, Thread

import cv2

# Roles, indices and resolutions come from ~/tactilevla-cams.json. Hardcoding the
# indices here once meant measuring the WRONG camera: a 1280x720 test aimed at
# "top" landed on the wrist camera after macOS renumbered them, and the resulting
# numbers were used to draw a conclusion about the overhead camera.
CAMS_JSON = Path.home() / "tactilevla-cams.json"
_cams = json.loads(CAMS_JSON.read_text())
TOP_CAM = _cams["top"]["index"]
WRIST_CAM = _cams["wrist"]["index"]
DEFAULT_TOP_RES = f"{_cams['top']['width']}x{_cams['top']['height']}"
DEFAULT_WRIST_RES = f"{_cams['wrist']['width']}x{_cams['wrist']['height']}"
TARGET_FPS = 30

# Achieved rate below this fraction of target is a problem.
FPS_TOLERANCE = 0.95
# A frame interval this much over nominal counts as a hitch.
HITCH_FACTOR = 1.5
# Mean-brightness change between the first and last quarter, as a fraction.
BRIGHTNESS_DRIFT_LIMIT = 0.05
# Modes worth probing when --modes is passed.
PROBE_MODES = [(640, 480), (800, 600), (1024, 768), (1280, 720), (1280, 960), (1920, 1080)]


class Capture:
    """One camera, read continuously on its own thread, like LeRobot does."""

    def __init__(self, index: int, width: int, height: int) -> None:
        self.index = index
        self.want = (width, height)
        self.cap: cv2.VideoCapture | None = None
        self.actual = (0, 0)
        self.open_seconds = 0.0
        self.stamps: list[float] = []
        self.brightness: list[float] = []
        self.focus: list[float] = []
        self.read_failures = 0
        self._stop = Event()
        self._thread: Thread | None = None

    def open(self) -> bool:
        started = time.perf_counter()
        cap = cv2.VideoCapture(self.index)
        if not cap.isOpened():
            cap.release()
            return False
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, self.want[0])
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, self.want[1])
        cap.set(cv2.CAP_PROP_FPS, TARGET_FPS)
        for _ in range(5):  # discard warm-up frames
            cap.read()
        self.open_seconds = time.perf_counter() - started
        self.actual = (
            int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)),
            int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)),
        )
        self.cap = cap
        return True

    def _loop(self) -> None:
        while not self._stop.is_set():
            assert self.cap is not None
            good, frame = self.cap.read()
            if not good:
                self.read_failures += 1
                continue
            self.stamps.append(time.perf_counter())
            # Sample the expensive metrics on every 5th frame; computing Laplacian
            # variance on every frame would itself become the bottleneck and skew
            # the very rate we are trying to measure.
            if len(self.stamps) % 5 == 0:
                gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
                self.brightness.append(float(gray.mean()))
                self.focus.append(float(cv2.Laplacian(gray, cv2.CV_64F).var()))

    def start(self) -> None:
        self.stamps.clear()
        self.brightness.clear()
        self.focus.clear()
        self.read_failures = 0
        self._stop.clear()
        self._thread = Thread(target=self._loop, name=f"cam{self.index}", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=5)

    def close(self) -> None:
        if self.cap is not None:
            self.cap.release()
            self.cap = None

    def report(self, label: str) -> dict:
        n = len(self.stamps)
        if n < 10:
            print(f"  {label}: only {n} frames captured - FAILED")
            return {"fps": 0.0, "hitches": 0, "drift": 0.0}

        elapsed = self.stamps[-1] - self.stamps[0]
        fps = (n - 1) / elapsed if elapsed > 0 else 0.0
        gaps = [b - a for a, b in zip(self.stamps, self.stamps[1:], strict=False)]
        nominal = 1.0 / TARGET_FPS
        hitches = sum(1 for g in gaps if g > nominal * HITCH_FACTOR)

        quarter = max(len(self.brightness) // 4, 1)
        drift = 0.0
        if len(self.brightness) >= 8:
            first = statistics.fmean(self.brightness[:quarter])
            last = statistics.fmean(self.brightness[-quarter:])
            drift = (last - first) / first if first else 0.0

        focus_cv = 0.0
        if len(self.focus) >= 8:
            mean_focus = statistics.fmean(self.focus)
            focus_cv = statistics.stdev(self.focus) / mean_focus if mean_focus else 0.0

        print(
            f"  {label}: {fps:5.1f} fps over {elapsed:4.1f}s  "
            f"({n} frames, {hitches} hitches>{HITCH_FACTOR:g}x, "
            f"p95 gap {sorted(gaps)[int(len(gaps) * 0.95)] * 1000:5.1f}ms, "
            f"max {max(gaps) * 1000:5.1f}ms)"
        )
        print(
            f"      brightness mean {statistics.fmean(self.brightness):5.1f} "
            f"drift {drift:+.1%}   focus mean {statistics.fmean(self.focus):7.0f} "
            f"variation {focus_cv:.1%}"
        )
        if self.read_failures:
            print(f"      {self.read_failures} failed read() calls")
        return {"fps": fps, "hitches": hitches, "drift": drift, "focus_cv": focus_cv}


def probe_modes(index: int) -> None:
    print(f"\n--- camera {index}: supported modes ---")
    for width, height in PROBE_MODES:
        cap = cv2.VideoCapture(index)
        if not cap.isOpened():
            print(f"  {width}x{height}: could not open camera")
            cap.release()
            return
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
        cap.read()
        got = (int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)))
        cap.release()
        verdict = "SUPPORTED" if got == (width, height) else f"snaps to {got[0]}x{got[1]}"
        print(f"  {width:>4}x{height:<4} -> {verdict}")


def parse_res(text: str, label: str) -> tuple[int, int]:
    try:
        w_str, h_str = text.lower().split("x", 1)
        return int(w_str), int(h_str)
    except ValueError:
        sys.exit(f"--{label} expects WxH, got {text!r}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seconds", type=float, default=20.0, help="duration of the both-cameras phase")
    parser.add_argument("--top-res", default=DEFAULT_TOP_RES)
    parser.add_argument("--wrist-res", default=DEFAULT_WRIST_RES)
    parser.add_argument("--modes", action="store_true", help="probe supported modes and exit")
    args = parser.parse_args()

    cv2.setNumThreads(1)  # match LeRobot (camera_opencv.py:156)

    if args.modes:
        probe_modes(TOP_CAM)
        probe_modes(WRIST_CAM)
        return 0

    top_w, top_h = parse_res(args.top_res, "top-res")
    wrist_w, wrist_h = parse_res(args.wrist_res, "wrist-res")
    solo = max(args.seconds / 2, 5.0)

    print("=" * 74)
    print("Camera capture check")
    print(f"  target      : {TARGET_FPS} fps")
    print(f"  top   cam {TOP_CAM} : {top_w}x{top_h}")
    print(f"  wrist cam {WRIST_CAM} : {wrist_w}x{wrist_h}")
    print("  Keep the scene STILL and the lighting unchanged for the whole run.")
    print("  NOTE: the wrist camera moves with the arm, and with torque disabled the")
    print("  arm DROOPS - so its focus/brightness here describe wherever it sagged to,")
    print("  not a working pose. Judge the wrist camera in tactilevla-camview.py while")
    print("  holding the arm at a grasp pose. Only its fps number is meaningful here.")
    print("=" * 74)

    top = Capture(TOP_CAM, top_w, top_h)
    wrist = Capture(WRIST_CAM, wrist_w, wrist_h)

    print("\nopening cameras...")
    for cam, label in ((top, "top"), (wrist, "wrist")):
        if not cam.open():
            print(f"  FAIL: could not open camera {cam.index} ({label})")
            top.close()
            wrist.close()
            return 1
        note = "" if cam.actual == cam.want else f"  <- NOT {cam.want[0]}x{cam.want[1]}"
        print(
            f"  {label:5s} cam {cam.index}: {cam.actual[0]}x{cam.actual[1]} "
            f"in {cam.open_seconds:.1f}s{note}"
        )

    results = {}
    print(f"\n--- phase 1: top camera alone ({solo:.0f}s) ---")
    top.start()
    time.sleep(solo)
    top.stop()
    results["top_solo"] = top.report("top  solo")

    print(f"\n--- phase 2: wrist camera alone ({solo:.0f}s) ---")
    wrist.start()
    time.sleep(solo)
    wrist.stop()
    results["wrist_solo"] = wrist.report("wrist solo")

    print(f"\n--- phase 3: BOTH together ({args.seconds:.0f}s) - the recording condition ---")
    top.start()
    wrist.start()
    time.sleep(args.seconds)
    top.stop()
    wrist.stop()
    results["top_both"] = top.report("top  both")
    results["wrist_both"] = wrist.report("wrist both")

    top.close()
    wrist.close()

    print("\n" + "=" * 74)
    problems = []
    for label, solo_key, both_key in (("top", "top_solo", "top_both"), ("wrist", "wrist_solo", "wrist_both")):
        solo_fps = results[solo_key]["fps"]
        both_fps = results[both_key]["fps"]
        cost = solo_fps - both_fps
        print(f"{label:5s}: {solo_fps:5.1f} fps alone -> {both_fps:5.1f} fps together  (contention cost {cost:+.1f})")
        if both_fps < TARGET_FPS * FPS_TOLERANCE:
            problems.append(
                f"{label} camera holds only {both_fps:.1f} fps against a {TARGET_FPS} fps target "
                "with both cameras running - this resolution is too expensive here"
            )
        if abs(results[both_key]["drift"]) > BRIGHTNESS_DRIFT_LIMIT:
            problems.append(
                f"{label} camera brightness drifted {results[both_key]['drift']:+.1%} during the test - "
                "auto-exposure is wandering and CANNOT be locked on macOS. Close blinds, "
                "use steady artificial light, and keep it identical for eval."
            )

    print("=" * 74)
    if problems:
        print("PROBLEMS:")
        for p in problems:
            print(f"  - {p}")
        return 1
    print(f"PASS - both cameras hold {TARGET_FPS} fps together, exposure stable.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
