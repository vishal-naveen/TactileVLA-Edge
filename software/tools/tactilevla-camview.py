#!/usr/bin/env python3
"""Live camera preview with brightness + focus meters.

Use this to (a) confirm a camera is actually seeing light, and (b) twist the lens
until the FOCUS number peaks — that is the sharpest setting.

    python3 ~/tactilevla-camview.py            # cameras 0 and 2 (skips built-in)
    python3 ~/tactilevla-camview.py 0 1 2      # specific indices
    python3 ~/tactilevla-camview.py --all      # probe 0..5

Keys (click a preview window first so it has focus):
    q / ESC   quit
    s         save a snapshot of every open camera to ~/camview-snaps/
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path

import cv2

# Roles, indices and resolutions come from ~/tactilevla-cams.json - one shared file,
# so a macOS renumbering is a one-line fix instead of six. Resolution is PER CAMERA:
# the two record at different sizes, so a single global value would make the preview
# lie about framing for at least one of them.
CAMS_JSON = Path.home() / "tactilevla-cams.json"
_cams = json.loads(CAMS_JSON.read_text())
ROLE_OF = {_cams[role]["index"]: role for role in ("top", "wrist")}
RECORD_RES = {_cams[role]["index"]: (_cams[role]["width"], _cams[role]["height"]) for role in ("top", "wrist")}
FALLBACK_RES = (800, 600)
CAP_FPS = 30

# Preview windows are scaled down to this width; capture stays at full resolution.
DISPLAY_WIDTH = 960

SNAP_DIR = Path.home() / "camview-snaps"

# A frame whose brightest pixel is below this is effectively dark (blocked lens).
DARK_MAX_PIXEL = 20
# Laplacian variance below this usually means badly out of focus.
BLURRY_THRESHOLD = 50.0

ROTATE_CODES = {
    90: cv2.ROTATE_90_CLOCKWISE,
    180: cv2.ROTATE_180,
    270: cv2.ROTATE_90_COUNTERCLOCKWISE,
}


def res_for(index: int) -> tuple[int, int]:
    return RECORD_RES.get(index, FALLBACK_RES)


def window_name(index: int) -> str:
    """Title carries the ROLE, not just the index.

    The indices swapped once already and cost real confusion; a window labelled
    "cam 1 [top]" is checkable at a glance against what you actually see.
    """
    role = ROLE_OF.get(index)
    return f"cam {index} [{role}]" if role else f"cam {index} (unused)"


def open_camera(index: int) -> cv2.VideoCapture | None:
    cap = cv2.VideoCapture(index)
    if not cap.isOpened():
        cap.release()
        return None
    width, height = res_for(index)
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    cap.set(cv2.CAP_PROP_FPS, CAP_FPS)
    return cap


def focus_score(gray) -> float:
    """Variance of the Laplacian — the standard sharpness metric. Higher = sharper."""
    return float(cv2.Laplacian(gray, cv2.CV_64F).var())


def to_display(frame):
    """Scale a full-resolution frame down to a comfortable preview size."""
    height, width = frame.shape[:2]
    if width <= DISPLAY_WIDTH:
        return frame
    scale = DISPLAY_WIDTH / width
    return cv2.resize(frame, (DISPLAY_WIDTH, int(height * scale)), interpolation=cv2.INTER_AREA)


def annotate(frame, index: int, peak_focus: float, source_shape=None) -> tuple[float, str]:
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    max_pixel = int(gray.max())
    mean = float(gray.mean())
    focus = focus_score(gray)
    shape = source_shape if source_shape is not None else frame.shape

    if max_pixel < DARK_MAX_PIXEL:
        status, color = "NO LIGHT - lens blocked or capped", (0, 0, 255)
    elif focus < BLURRY_THRESHOLD:
        status, color = "OUT OF FOCUS - twist the lens", (0, 165, 255)
    else:
        status, color = "OK", (0, 255, 0)

    lines = [
        f"cam {index}   {shape[1]}x{shape[0]}",
        f"bright: max {max_pixel:3d}  mean {mean:5.1f}",
        f"FOCUS: {focus:7.1f}   (best so far {peak_focus:7.1f})",
        status,
    ]
    for i, text in enumerate(lines):
        y = 24 + i * 26
        line_color = color if i == len(lines) - 1 else (255, 255, 255)
        # Outline first for legibility against any background.
        cv2.putText(frame, text, (10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 0, 0), 3)
        cv2.putText(frame, text, (10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.6, line_color, 1)

    return focus, status


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("indices", nargs="*", type=int, help="camera indices (default: 0 1)")
    parser.add_argument("--all", action="store_true", help="probe indices 0..5")
    parser.add_argument(
        "--rotate",
        action="append",
        default=[],
        metavar="INDEX:DEG",
        help="rotate a camera's preview, e.g. --rotate 1:90 (90, 180, or 270)",
    )
    default_desc = ", ".join(f"{i}={w}x{h}" for i, (w, h) in sorted(RECORD_RES.items()))
    parser.add_argument(
        "--res",
        action="append",
        default=[],
        metavar="WxH|INDEX:WxH",
        help=(
            f"capture resolution; defaults track the record config ({default_desc}). "
            "Bare WxH applies to every camera; INDEX:WxH sets just one. Repeatable."
        ),
    )
    args = parser.parse_args()

    for spec in args.res:
        try:
            if ":" in spec:
                idx_str, size = spec.split(":", 1)
                w_str, h_str = size.lower().split("x", 1)
                RECORD_RES[int(idx_str)] = (int(w_str), int(h_str))
            else:
                w_str, h_str = spec.lower().split("x", 1)
                for idx in list(RECORD_RES):
                    RECORD_RES[idx] = (int(w_str), int(h_str))
                globals()["FALLBACK_RES"] = (int(w_str), int(h_str))
        except ValueError:
            parser.error(f"--res expects WxH or INDEX:WxH, got {spec!r}")

    rotations: dict[int, int] = {}
    for spec in args.rotate:
        try:
            idx_str, deg_str = spec.split(":", 1)
            deg = int(deg_str) % 360
        except ValueError:
            parser.error(f"--rotate expects INDEX:DEG (e.g. 1:90), got {spec!r}")
        if deg not in (0, 90, 180, 270):
            parser.error(f"--rotate degrees must be 0, 90, 180, or 270, got {deg}")
        rotations[int(idx_str)] = deg

    if args.all:
        wanted = list(range(6))
    elif args.indices:
        wanted = args.indices
    else:
        # 0 and 1 are the two external cameras; 2 is the MacBook built-in.
        wanted = [0, 1]

    caps: dict[int, cv2.VideoCapture] = {}
    for index in wanted:
        cap = open_camera(index)
        if cap is None:
            print(f"cam {index}: could not open (skipping)")
            continue
        caps[index] = cap
        window = window_name(index)
        cv2.namedWindow(window, cv2.WINDOW_NORMAL)
        want_w, want_h = res_for(index)
        cv2.resizeWindow(window, DISPLAY_WIDTH, int(DISPLAY_WIDTH * want_h / want_w))
        actual_w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        actual_h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        note = "" if (actual_w, actual_h) == (want_w, want_h) else f"  <- NOT the requested {want_w}x{want_h}"
        print(f"cam {index}: opened at {actual_w}x{actual_h}{note}")

    if not caps:
        print("\nNo cameras opened. If this is the first run, macOS may need camera")
        print("permission: System Settings > Privacy & Security > Camera > enable Terminal.")
        return 1

    print("\nClick a preview window, then: 'q' or ESC to quit, 's' to save snapshots.")
    print("To focus: twist the lens slowly and watch FOCUS climb, then back off when it drops.\n")

    peaks = dict.fromkeys(caps, 0.0)
    try:
        while True:
            for index, cap in caps.items():
                ok, frame = cap.read()
                if not ok:
                    continue
                deg = rotations.get(index, 0)
                if deg:
                    frame = cv2.rotate(frame, ROTATE_CODES[deg])
                # Metrics come from the full-resolution frame; only the preview is scaled.
                display = to_display(frame)
                focus, _ = annotate(display, index, peaks[index], source_shape=frame.shape)
                peaks[index] = max(peaks[index], focus)
                cv2.imshow(window_name(index), display)

            key = cv2.waitKey(1) & 0xFF
            if key in (ord("q"), 27):
                break
            if key == ord("s"):
                SNAP_DIR.mkdir(parents=True, exist_ok=True)
                stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
                for index, cap in caps.items():
                    ok, frame = cap.read()
                    if ok:
                        path = SNAP_DIR / f"cam{index}-{stamp}.png"
                        cv2.imwrite(str(path), frame)
                        print(f"saved {path}")
    except KeyboardInterrupt:
        pass
    finally:
        for cap in caps.values():
            cap.release()
        cv2.destroyAllWindows()

    print("\nPeak focus scores this session:")
    for index, peak in peaks.items():
        print(f"  cam {index}: {peak:.1f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
