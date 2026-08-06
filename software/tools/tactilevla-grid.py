#!/usr/bin/env python3
"""Overlay a perspective-correct placement grid on the top camera.

    python3 ~/tactilevla-grid.py                          # 3x3, uses saved corners
    python3 ~/tactilevla-grid.py --rows 3 --cols 3
    python3 ~/tactilevla-grid.py --skip B2                # cell not used at all
    python3 ~/tactilevla-grid.py --holdout A2,C3          # recorded nothing, tested later
    python3 ~/tactilevla-grid.py --reset                  # re-click the corners

First run asks you to click the four corners of the reachable box, in this order:

    1. NEAR-LEFT      2. NEAR-RIGHT      3. FAR-RIGHT      4. FAR-LEFT

"Near" means closest to the bottom of the camera image. The corners are saved to
~/tactilevla-grid.json and reused, so you only click once.

WHY A HOMOGRAPHY: the camera looks down at an angle, so equal spacing in the
IMAGE is not equal spacing on the TABLE - far cells would cover much more table
area than near ones, and the grid would silently be non-uniform. Clicking the
four physical corners lets us map a true rectangle on the table into the image,
so every cell covers the same real area and appears correctly trapezoidal.

Keys (click the window first so it has focus):
    r        rotate the labelling 90 deg (fixes clicking the corners out of order)
    f        mirror the labelling (fixes clicking counter-clockwise)
    1-4      select a corner, then arrow keys nudge it 2 px for fine alignment
    c        re-click the corners from scratch
    s        save a snapshot to ~/camview-snaps/
    q        quit

r/f/nudge all reshape the SAME four clicks, so getting the order wrong costs a
keypress rather than another round of clicking. Cell A1 should end up in the
corner nearest you on the left.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path

import cv2
import numpy as np

# The grid only makes sense on the OVERHEAD camera: the homography assumes a fixed
# camera, so on the wrist camera it would be correct for exactly one arm pose and
# wrong in every other frame. Index and resolution come from the shared config.
CAMS_JSON = Path.home() / "tactilevla-cams.json"
_cams = json.loads(CAMS_JSON.read_text())
TOP_CAM = _cams["top"]["index"]
DEFAULT_RES = f"{_cams['top']['width']}x{_cams['top']['height']}"
CONFIG = Path.home() / "tactilevla-grid.json"
SNAP_DIR = Path.home() / "camview-snaps"

ROW_LABELS = "ABCDEFGH"

COLOR_TRAINED = (80, 220, 80)  # BGR green
COLOR_HOLDOUT = (60, 200, 255)  # amber
COLOR_SKIP = (70, 70, 220)  # red
COLOR_EDGE = (255, 255, 255)

CLICK_PROMPTS = ("NEAR-LEFT", "NEAR-RIGHT", "FAR-RIGHT", "FAR-LEFT")


def cell_name(row: int, col: int) -> str:
    return f"{ROW_LABELS[row]}{col + 1}"


def collect_corners(cap: cv2.VideoCapture, window: str) -> list[list[float]] | None:
    """Let the user click four table corners. Returns None if they quit."""
    points: list[list[float]] = []

    def on_click(event: int, x: int, y: int, flags: int, param) -> None:  # noqa: ARG001
        if event == cv2.EVENT_LBUTTONDOWN and len(points) < 4:
            points.append([float(x), float(y)])

    cv2.setMouseCallback(window, on_click)
    while True:
        good, frame = cap.read()
        if not good:
            continue
        shown = frame.copy()
        for i, (px, py) in enumerate(points):
            cv2.circle(shown, (int(px), int(py)), 6, COLOR_EDGE, -1)
            cv2.putText(
                shown, str(i + 1), (int(px) + 9, int(py) - 9),
                cv2.FONT_HERSHEY_SIMPLEX, 0.6, COLOR_EDGE, 2,
            )
        if len(points) >= 2:
            cv2.polylines(
                shown, [np.array(points, np.int32)], len(points) == 4, COLOR_EDGE, 1
            )
        if len(points) < 4:
            msg = f"Click corner {len(points) + 1}/4: {CLICK_PROMPTS[len(points)]}"
        else:
            msg = "Enter = accept    c = start over    q = quit"
        cv2.putText(shown, msg, (12, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.65, (0, 0, 0), 4)
        cv2.putText(shown, msg, (12, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.65, COLOR_EDGE, 1)
        cv2.imshow(window, shown)

        key = cv2.waitKey(1) & 0xFF
        if key == ord("q"):
            return None
        if key == ord("c"):
            points.clear()
        if key in (13, 10) and len(points) == 4:
            cv2.setMouseCallback(window, lambda *a: None)
            return points


def homography(corners: list[list[float]]) -> np.ndarray:
    """Map the unit square onto the clicked table rectangle.

    Unit space: (u, v) with u = 0..1 left->right (columns) and v = 0..1
    near->far (rows). Corner order matches CLICK_PROMPTS.
    """
    unit = np.array([[0, 0], [1, 0], [1, 1], [0, 1]], np.float32)
    return cv2.getPerspectiveTransform(unit, np.array(corners, np.float32))


def to_image(matrix: np.ndarray, points: np.ndarray) -> np.ndarray:
    """Transform unit-space points (N,2) into image pixels."""
    reshaped = points.reshape(-1, 1, 2).astype(np.float32)
    return cv2.perspectiveTransform(reshaped, matrix).reshape(-1, 2)


def draw_grid(
    frame: np.ndarray,
    matrix: np.ndarray,
    rows: int,
    cols: int,
    skip: set[str],
    holdout: set[str],
) -> np.ndarray:
    out = frame.copy()

    # Cell fills first, so the lines and labels sit on top.
    overlay = out.copy()
    for row in range(rows):
        for col in range(cols):
            name = cell_name(row, col)
            if name in skip:
                color = COLOR_SKIP
            elif name in holdout:
                color = COLOR_HOLDOUT
            else:
                color = COLOR_TRAINED
            quad = to_image(
                matrix,
                np.array([
                    [col / cols, row / rows],
                    [(col + 1) / cols, row / rows],
                    [(col + 1) / cols, (row + 1) / rows],
                    [col / cols, (row + 1) / rows],
                ]),
            )
            cv2.fillPoly(overlay, [quad.astype(np.int32)], color)
    cv2.addWeighted(overlay, 0.20, out, 0.80, 0, out)

    # A homography maps straight lines to straight lines, so two points per line.
    for col in range(cols + 1):
        a, b = to_image(matrix, np.array([[col / cols, 0.0], [col / cols, 1.0]]))
        cv2.line(out, tuple(a.astype(int)), tuple(b.astype(int)), COLOR_EDGE, 1)
    for row in range(rows + 1):
        a, b = to_image(matrix, np.array([[0.0, row / rows], [1.0, row / rows]]))
        cv2.line(out, tuple(a.astype(int)), tuple(b.astype(int)), COLOR_EDGE, 1)

    for row in range(rows):
        for col in range(cols):
            name = cell_name(row, col)
            centre = to_image(
                matrix, np.array([[(col + 0.5) / cols, (row + 0.5) / rows]])
            )[0]
            cx, cy = int(centre[0]), int(centre[1])
            if name in skip:
                # An X, so an unusable cell is unmistakable at a glance.
                for dx, dy in ((-9, -9), (-9, 9)):
                    cv2.line(out, (cx + dx, cy + dy), (cx - dx, cy - dy), COLOR_SKIP, 2)
            else:
                # Aim point: this is where the noodle goes.
                cv2.drawMarker(out, (cx, cy), COLOR_EDGE, cv2.MARKER_CROSS, 12, 1)
            suffix = "" if name not in holdout else " (hold)"
            label = f"{name}{suffix}"
            cv2.putText(out, label, (cx - 26, cy - 14), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 0, 0), 3)
            cv2.putText(out, label, (cx - 26, cy - 14), cv2.FONT_HERSHEY_SIMPLEX, 0.5, COLOR_EDGE, 1)

    trained = rows * cols - len(skip) - len(holdout)
    legend = [
        f"green = record here ({trained} cells)",
        f"amber = hold out, test only ({len(holdout)})",
    ]
    if skip:
        legend.append(f"red X = unusable, skipped ({len(skip)})")
    for i, text in enumerate(legend):
        y = out.shape[0] - 12 - (len(legend) - 1 - i) * 22
        cv2.putText(out, text, (12, y), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 0, 0), 4)
        cv2.putText(out, text, (12, y), cv2.FONT_HERSHEY_SIMPLEX, 0.55, COLOR_EDGE, 1)
    return out


def parse_cells(text: str, rows: int, cols: int, flag: str) -> set[str]:
    if not text:
        return set()
    valid = {cell_name(r, c) for r in range(rows) for c in range(cols)}
    wanted = {piece.strip().upper() for piece in text.split(",") if piece.strip()}
    unknown = wanted - valid
    if unknown:
        sys.exit(f"--{flag}: {sorted(unknown)} not in a {rows}x{cols} grid ({sorted(valid)})")
    return wanted


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    # default=None distinguishes "not passed" from "passed empty", so the saved
    # layout persists. Retyping --skip every run is how you eventually forget it
    # and place the noodle in a cell you had ruled out.
    parser.add_argument("--rows", type=int, default=None)
    parser.add_argument("--cols", type=int, default=None)
    parser.add_argument("--res", default=DEFAULT_RES, help=f"capture resolution (default {DEFAULT_RES})")
    parser.add_argument("--index", type=int, default=TOP_CAM)
    parser.add_argument("--skip", default=None, help="cells that cannot be used at all, e.g. B2")
    parser.add_argument("--holdout", default=None, help="cells to record nothing in, e.g. A2,C3")
    parser.add_argument("--reset", action="store_true", help="re-click the corners")
    parser.add_argument(
        "--export",
        action="store_true",
        help="save a still grid reference to ~/camview-snaps/grid-reference.png and exit",
    )
    # Corners auto-save on every rotate/mirror/nudge, which is convenient while
    # aligning and dangerous afterwards: one stray arrow key silently rewrites a
    # grid you had already measured. Locking makes those keys refuse.
    parser.add_argument("--lock", action="store_true", help="freeze the current grid, then exit")
    parser.add_argument("--unlock", action="store_true", help="allow edits again, then exit")
    args = parser.parse_args()

    if args.lock or args.unlock:
        if not CONFIG.exists():
            sys.exit(f"No grid to lock - {CONFIG} does not exist yet.")
        cfg = json.loads(CONFIG.read_text())
        cfg["locked"] = bool(args.lock)
        CONFIG.write_text(json.dumps(cfg, indent=2))
        state = "LOCKED" if args.lock else "unlocked"
        print(f"grid {state}: {CONFIG}")
        if args.lock:
            print("r / f / arrow-key edits are now refused. Unlock with --unlock.")
        return 0

    stored = json.loads(CONFIG.read_text()) if CONFIG.exists() else {}
    rows = args.rows if args.rows is not None else stored.get("rows", 3)
    cols = args.cols if args.cols is not None else stored.get("cols", 3)
    skip_text = args.skip if args.skip is not None else ",".join(stored.get("skip", []))
    holdout_text = args.holdout if args.holdout is not None else ",".join(stored.get("holdout", []))

    args.rows, args.cols = rows, cols
    skip = parse_cells(skip_text, rows, cols, "skip")
    holdout = parse_cells(holdout_text, rows, cols, "holdout")
    overlap = skip & holdout
    if overlap:
        sys.exit(f"cells {sorted(overlap)} are both --skip and --holdout; pick one")

    try:
        width, height = (int(v) for v in args.res.lower().split("x", 1))
    except ValueError:
        sys.exit(f"--res expects WxH, got {args.res!r}")

    # Locked to the overhead camera. A homography assumes a FIXED camera; on the
    # wrist camera the grid would be correct for exactly one arm pose and wrong in
    # every other frame, which is worse than having no grid at all.
    wrist_index = _cams["wrist"]["index"]
    if args.index == wrist_index:
        print(f"Camera {args.index} is the WRIST camera - a grid there is meaningless.")
        print("The wrist camera moves with the arm, so a fixed table-plane grid only")
        print(f"lines up at one pose. The overhead camera is index {TOP_CAM}.")
        return 1

    cap = cv2.VideoCapture(args.index)
    if not cap.isOpened():
        print(f"Could not open camera {args.index}")
        return 1
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    actual = (int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)))
    if actual != (width, height):
        print(f"WARNING: camera opened at {actual[0]}x{actual[1]}, not {width}x{height}")
        print("The grid is stored in pixel coordinates, so it only lines up at ONE")
        print("resolution. Re-click the corners if you change the record resolution.")

    window = f"grid overlay - cam {args.index}"
    cv2.namedWindow(window, cv2.WINDOW_NORMAL)
    cv2.resizeWindow(window, min(1100, actual[0]), int(min(1100, actual[0]) * actual[1] / actual[0]))

    corners: list[list[float]] = [] if args.reset else stored.get("corners") or []
    if corners and stored.get("resolution") != list(actual):
        print(f"NOTE: corners were clicked at {stored.get('resolution')}, now running {list(actual)}.")
        print("      Corners are stored in PIXELS, so they only line up at one")
        print("      resolution - press 'c' to re-click if the grid is off.")

    locked = bool(stored.get("locked", False))

    def save_corners() -> None:
        # Keep one generation of history. A measured grid is worth minutes of
        # tape-measure work; overwriting it with no undo is not acceptable.
        if CONFIG.exists():
            (CONFIG.parent / (CONFIG.name + ".bak")).write_text(CONFIG.read_text())
        CONFIG.write_text(
            json.dumps(
                {
                    "corners": corners,
                    "resolution": list(actual),
                    "index": args.index,
                    "rows": args.rows,
                    "cols": args.cols,
                    "skip": sorted(skip),
                    "holdout": sorted(holdout),
                    "locked": locked,
                },
                indent=2,
            )
        )

    if not corners:
        print("No saved corners - click the four table corners.")
        fresh = collect_corners(cap, window)
        if fresh is None:
            cap.release()
            cv2.destroyAllWindows()
            return 1
        corners = fresh
        save_corners()
        print(f"Saved layout to {CONFIG}")
    else:
        # Persist the layout on every run so the file always reflects what was shown.
        save_corners()

    matrix = homography(corners)
    selected = 0  # which corner the arrow keys nudge

    # --export writes a STILL reference and releases the camera immediately, so you
    # can keep the grid on screen during a session without a second process
    # competing for the overhead camera.
    if args.export:
        for _ in range(5):
            cap.read()  # let exposure settle
        good, frame = cap.read()
        cap.release()
        cv2.destroyAllWindows()
        if not good:
            print("Could not grab a frame to export.")
            return 1
        SNAP_DIR.mkdir(parents=True, exist_ok=True)
        out = SNAP_DIR / "grid-reference.png"
        cv2.imwrite(str(out), draw_grid(frame, matrix, args.rows, args.cols, skip, holdout))
        print(f"\nwrote {out}")
        print("Open it in Preview and leave it on screen. The camera is released, so")
        print("this costs the recorder nothing. Re-run --export to refresh it.")
        return 0
    print(f"\n{args.rows}x{args.cols} grid on cam {args.index} at {actual[0]}x{actual[1]}")
    print(f"  record in : {sorted({cell_name(r, c) for r in range(args.rows) for c in range(args.cols)} - skip - holdout)}")
    print(f"  hold out  : {sorted(holdout) or '(none)'}")
    print(f"  skipped   : {sorted(skip) or '(none)'}")
    if locked:
        print("\n*** GRID IS LOCKED *** - r / f / c / arrow edits are refused.")
        print("s = snapshot    q = quit    (unlock with --unlock)")
    else:
        print("\nr = rotate 90    f = mirror    1-4 + arrows = nudge a corner")
        print("c = re-click      s = snapshot   q = quit")
        print("Lock it once aligned:  python3 ~/tactilevla-grid.py --lock")
    print()
    print("Safe to leave open while recording - measured: two and three readers on the")
    print("overhead camera all held 30.0 fps. For a zero-cost static copy instead, use")
    print("--export and open ~/camview-snaps/grid-reference.png in Preview.")

    while True:
        good, frame = cap.read()
        if not good:
            continue
        shown = draw_grid(frame, matrix, args.rows, args.cols, skip, holdout)
        # Mark the corner the arrow keys will move, so nudging is never blind.
        cv2.circle(shown, (int(corners[selected][0]), int(corners[selected][1])), 7, COLOR_EDGE, 2)
        hint = f"corner {selected + 1} selected ({CLICK_PROMPTS[selected]})   r rotate  f mirror"
        cv2.putText(shown, hint, (12, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 0, 0), 4)
        cv2.putText(shown, hint, (12, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.55, COLOR_EDGE, 1)
        cv2.imshow(window, shown)

        key = cv2.waitKey(1) & 0xFF
        if key == ord("q"):
            break
        if key in (ord("1"), ord("2"), ord("3"), ord("4")):
            selected = key - ord("1")
        if locked and key in (ord("r"), ord("f"), ord("c"), 0, 1, 2, 3, 81, 82, 83, 84):
            print("grid is LOCKED - edit refused. Unlock with: python3 ~/tactilevla-grid.py --unlock")
            continue
        if key == ord("r"):
            # Rotating the corner list rotates which physical corner is treated as
            # "near-left", which turns the labelling 90 deg without re-clicking.
            corners = corners[1:] + corners[:1]
            matrix = homography(corners)
            save_corners()
            print("rotated labelling 90 deg")
        if key == ord("f"):
            corners = list(reversed(corners))
            matrix = homography(corners)
            save_corners()
            print("mirrored labelling")
        # Arrow keys: macOS OpenCV reports these as 0/1/2/3 with the low byte mask.
        nudge = {0: (0, -2), 1: (0, 2), 2: (-2, 0), 3: (2, 0), 81: (-2, 0), 82: (0, -2), 83: (2, 0), 84: (0, 2)}
        if key in nudge:
            dx, dy = nudge[key]
            corners[selected][0] += dx
            corners[selected][1] += dy
            matrix = homography(corners)
            save_corners()
        if key == ord("c"):
            fresh = collect_corners(cap, window)
            if fresh is not None:
                corners = fresh
                selected = 0
                matrix = homography(corners)
                save_corners()
                print(f"Corners updated and saved to {CONFIG}")
        if key == ord("s"):
            SNAP_DIR.mkdir(parents=True, exist_ok=True)
            stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            path = SNAP_DIR / f"grid_cam{args.index}_{stamp}.png"
            cv2.imwrite(str(path), shown)
            print(f"saved {path}")

    cap.release()
    cv2.destroyAllWindows()
    return 0


if __name__ == "__main__":
    sys.exit(main())
