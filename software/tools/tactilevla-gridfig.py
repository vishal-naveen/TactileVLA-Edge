"""Render the recorded workspace grid as an SVG figure for the docs.

    python3 tactilevla-gridfig.py --cells <session>-cells.csv --out docs/media/workspace-grid.svg

Reproduces the geometry `tactilevla-grid.py` draws on the overhead camera: the same
unit-square homography onto the four clicked table corners, the same `cell_name(row, col)`.
Drawing an idealized 3x3 instead would misrepresent the workspace, which is a perspective
quad -- the outer cells cover noticeably more table than the inner ones.

Per-cell episode counts come from the session's cell log, so the published figure cannot
drift from what was actually recorded.
"""

from __future__ import annotations

import argparse
import csv
import json
from collections import Counter
from pathlib import Path

import cv2
import numpy as np

ROW_LABELS = "ABC"
TRAINED_FILL = "#3ba88f"
HOLDOUT_FILL = "#e0a33c"
EDGE = "#1d2b32"

HERE = Path(__file__).resolve().parent


def cell_name(row: int, col: int) -> str:
    return f"{ROW_LABELS[row]}{col + 1}"


def homography(corners: list[list[float]]) -> np.ndarray:
    """Map the unit square onto the clicked table quad. Mirrors tactilevla-grid.py."""
    unit = np.array([[0, 0], [1, 0], [1, 1], [0, 1]], np.float32)
    return cv2.getPerspectiveTransform(unit, np.array(corners, np.float32))


def to_image(matrix: np.ndarray, points: np.ndarray) -> np.ndarray:
    return cv2.perspectiveTransform(points.reshape(-1, 1, 2).astype(np.float32), matrix).reshape(
        -1, 2
    )


def final_take_per_episode(cells_csv: Path) -> Counter[str]:
    """Count episodes per cell, keeping only the take that survived into the dataset.

    The cell log is append-only: a re-recorded episode is logged again under the same
    episode_index. The noodlegrid session has 283 lines for 160 episodes, so counting
    raw rows overstates some cells by 3x.
    """
    with cells_csv.open(encoding="utf-8") as fh:
        final = {row["episode_index"]: row["cell"] for row in csv.DictReader(fh)}
    return Counter(final.values())


def render(grid: dict, counts: Counter[str]) -> str:
    rows, cols = grid["rows"], grid["cols"]
    holdout = set(grid.get("holdout", []))
    matrix = homography(grid["corners"])
    total = sum(counts.values())

    # Crop to the table quad: the grid occupies a corner of the camera frame, so the
    # full-frame viewBox would be mostly empty.
    outline = to_image(matrix, np.array([[0, 0], [1, 0], [1, 1], [0, 1]], np.float32))
    pad, footer = 28, 46
    vx, vy = outline[:, 0].min() - pad, outline[:, 1].min() - pad
    vw = np.ptp(outline[:, 0]) + 2 * pad
    vh = np.ptp(outline[:, 1]) + 2 * pad + footer

    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vx:.1f} {vy:.1f} {vw:.1f} {vh:.1f}" '
        f'width="{vw:.0f}" height="{vh:.0f}" font-family="-apple-system,Segoe UI,sans-serif">',
        f'<rect x="{vx:.1f}" y="{vy:.1f}" width="{vw:.1f}" height="{vh:.1f}" fill="#f6f7f8"/>',
    ]

    for row in range(rows):
        for col in range(cols):
            name = cell_name(row, col)
            quad = to_image(
                matrix,
                np.array(
                    [
                        [col / cols, row / rows],
                        [(col + 1) / cols, row / rows],
                        [(col + 1) / cols, (row + 1) / rows],
                        [col / cols, (row + 1) / rows],
                    ]
                ),
            )
            held = name in holdout
            points = " ".join(f"{x:.1f},{y:.1f}" for x, y in quad)
            cx, cy = quad.mean(axis=0)
            parts += [
                f'<polygon points="{points}" fill="{HOLDOUT_FILL if held else TRAINED_FILL}" '
                f'fill-opacity="{0.55 if held else 0.28}" stroke="{EDGE}" stroke-width="1.5"/>',
                f'<text x="{cx:.1f}" y="{cy - 4:.1f}" text-anchor="middle" font-size="21" '
                f'font-weight="700" fill="{EDGE}">{name}</text>',
                f'<text x="{cx:.1f}" y="{cy + 15:.1f}" text-anchor="middle" font-size="14" '
                f'fill="{EDGE}" opacity="0.85">'
                f"{'held out' if held else f'{counts.get(name, 0)} eps'}</text>",
            ]

    width, height = grid["resolution"]
    parts += [
        f'<text x="{vx + 6:.1f}" y="{vy + vh - 14:.1f}" font-size="15" fill="{EDGE}" '
        f'opacity="0.75">{total} episodes over {rows * cols - len(holdout)} cells &#183; '
        f"{', '.join(sorted(holdout))} held out &#183; overhead camera, "
        f"{width}&#215;{height}</text>",
        "</svg>",
    ]
    return "\n".join(parts)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--grid", type=Path, default=HERE / "tactilevla-grid.json")
    parser.add_argument("--cells", type=Path, required=True, help="<session>-cells.csv")
    parser.add_argument("--out", type=Path, required=True, help="destination .svg")
    args = parser.parse_args()

    grid = json.loads(args.grid.read_text(encoding="utf-8"))
    counts = final_take_per_episode(args.cells)
    args.out.write_text(render(grid, counts), encoding="utf-8")

    print(f"wrote {args.out}")
    for name, n in sorted(counts.items()):
        print(f"  {name}: {n}")
    print(f"  total: {sum(counts.values())}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
