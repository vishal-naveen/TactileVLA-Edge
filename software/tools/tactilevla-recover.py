#!/usr/bin/env python3
"""Work out what actually survived after a recording session died, and what to run next.

    python3 ~/tactilevla-recover.py                  # the active session
    python3 ~/tactilevla-recover.py <dataset_name>   # a specific one

Run this ANY time recording stops for a reason you did not choose: a USB
disconnect, a serial timeout, a force-quit, a power cut, or the Mac sleeping.

It answers three questions, in order of how much they cost you:

  1. How many episodes are really there? Two different numbers can disagree.
     Episode metadata is buffered in memory and only written every 10 episodes
     or on a clean shutdown (metadata_buffer_size=10, not settable from the CLI).
     A CLEAN stop - ESC, Ctrl-C, or a serial ConnectionError - flushes it, so you
     lose at most the one in-flight episode. A HARD stop - force-quit, kill -9,
     power loss, kernel panic - does not, so up to 9 fully-recorded episodes can
     be sitting on disk complete but unregistered, invisible to every reader.
     That gap is what this script measures.

  2. Is anything corrupt? A hard stop can also leave the open parquet file with
     no footer, which makes it unreadable. There is no repair tool in LeRobot.

  3. Where were you? Maps the episode count back onto the recording plan so you
     know which cell to restart from.
"""

from __future__ import annotations

import glob
import json
import sys
from pathlib import Path

LOCAL_ROOT = Path.home() / ".cache/huggingface/lerobot/local"
SESSION_FILE = Path.home() / "tactilevla-session.json"

# The recording plan, so a resume can be mapped back to a physical cell.
BASE_ORDER = ["A1", "B1", "C1", "C2", "C3", "B3", "A3", "A2"]
EPISODES_PER_CELL = 5
CELLS_PER_ROUND = len(BASE_ORDER)
ROUND_SIZE = EPISODES_PER_CELL * CELLS_PER_ROUND  # 40

W = 66
rule = "─" * W


def cell_for(episode_index: int) -> tuple[str, int, str]:
    """(cell, round_number, position-in-cell) for a 0-based episode index."""
    rnd, within = divmod(episode_index, ROUND_SIZE)
    slot, in_cell = divmod(within, EPISODES_PER_CELL)
    # Rounds 2 and 4 walk the perimeter backwards, so that a given cell is not
    # always recorded at the same point in a round (which would re-introduce the
    # drift that rounds exist to average out).
    order = BASE_ORDER if rnd % 2 == 0 else list(reversed(BASE_ORDER))
    return order[slot], rnd + 1, f"{in_cell + 1} of {EPISODES_PER_CELL}"


def main() -> int:
    name = sys.argv[1] if len(sys.argv) > 1 else None
    task = None
    if name is None:
        if not SESSION_FILE.exists():
            print(f"No active session at {SESSION_FILE} and no dataset named.")
            print("Datasets on disk:")
            for p in sorted(LOCAL_ROOT.glob("*")):
                print(f"  {p.name}")
            return 1
        session = json.loads(SESSION_FILE.read_text())
        name, task = session["dataset"], session.get("task")

    root = LOCAL_ROOT / name
    if not root.is_dir():
        print(f"Session {name} is registered but has no data directory yet ({root}).")
        print("Nothing was recorded. Start the session normally.")
        return 1

    print()
    print(rule)
    print(f"  RECOVERY REPORT   {name}")
    print(rule)

    # ── 1. registered vs physically present ──────────────────────────────────
    registered = frames_registered = None
    try:
        info = json.loads((root / "meta/info.json").read_text())
        registered, frames_registered = info["total_episodes"], info["total_frames"]
    except Exception as exc:
        print(f"  meta/info.json unreadable: {exc}")

    on_disk = None
    unreadable = []
    try:
        import pandas as pd

        files = sorted(glob.glob(str(root / "data" / "**" / "*.parquet"), recursive=True))
        eps: set[int] = set()
        for f in files:
            try:
                eps.update(pd.read_parquet(f, columns=["episode_index"])["episode_index"].unique().tolist())
            except Exception as exc:
                unreadable.append((Path(f).name, str(exc)[:60]))
        on_disk = len(eps)
    except ImportError:
        print("  (pandas unavailable - skipping the physical-row check)")

    if registered is not None:
        print(f"  registered episodes   {registered}   ({frames_registered} frames)")
    if on_disk is not None:
        print(f"  episodes with data    {on_disk}")

    print()
    verdict_clean = True

    if unreadable:
        verdict_clean = False
        print("  ✗ CORRUPT FILES - a hard stop left parquet without a footer:")
        for fname, err in unreadable:
            print(f"      {fname}: {err}")
        print("      There is no repair tool. Move these aside and treat the")
        print("      episodes in them as lost:")
        for fname, _ in unreadable:
            print(f"        mv <path>/{fname} <path>/{fname}.corrupt")

    if registered is not None and on_disk is not None and on_disk > registered:
        verdict_clean = False
        lost = on_disk - registered
        print(f"  ✗ {lost} ORPHANED EPISODE(S) - recorded fully, never registered.")
        print("      This is the metadata buffer: the process died hard before it")
        print("      flushed. The frames and video are on disk but no reader can")
        print("      see them. They are effectively lost - re-record them.")
        print(f"      Treat the dataset as having {registered} usable episodes.")
    elif registered is not None and on_disk is not None:
        print("  ✓ no orphaned episodes - metadata is consistent with the data")

    # ── 2. video vs parquet ──────────────────────────────────────────────────
    for cam in ("observation.images.top", "observation.images.wrist"):
        vids = sorted(glob.glob(str(root / "videos" / cam / "**" / "*.mp4"), recursive=True))
        if vids:
            size = sum(Path(v).stat().st_size for v in vids) / 1024**2
            print(f"  ✓ {cam.split('.')[-1]:<5} {len(vids)} file(s), {size:.0f} MB")
        else:
            verdict_clean = False
            print(f"  ✗ {cam}: no video files")
    print()
    print("  Run the full gate before training either way:")
    print("      python3 ~/tactilevla-checkdata.py")

    # ── 3. where you were, and what to run ───────────────────────────────────
    usable = registered if registered is not None else (on_disk or 0)
    print()
    print(rule)
    if usable == 0:
        print("  Nothing usable was saved. Start the session again from scratch.")
        print(rule)
        return 1

    cell, rnd, pos = cell_for(usable)  # usable is a count -> index of the NEXT episode
    done_r, done_c = divmod(usable, ROUND_SIZE)
    print(f"  YOU HAVE {usable} EPISODES. Next one is round {rnd}, cell {cell} ({pos}).")
    print(f"  ({done_r} full round(s) done, {done_c} episodes into the current one.)")
    print()
    print("  Before resuming, in this order:")
    print("    1. python3 ~/tactilevla-findports.py        # ports renumber on replug")
    print("    2. python3 ~/tactilevla-verify.py           # arms + voltages + cameras")
    print("    3. python3 ~/tactilevla-camview.py          # confirm top/wrist BY EYE")
    print()
    remaining_round = ROUND_SIZE - done_c
    print("  Then resume. The number is how many MORE episodes, not the new total:")
    print(f"      bash ~/tactilevla-record.sh resume {name} {remaining_round}")
    print(f"      ({remaining_round} finishes the current round; use any number you like)")
    if task:
        print()
        print(f"  task: {task!r}")
    print(rule)
    return 0 if verdict_clean else 1


if __name__ == "__main__":
    sys.exit(main())
