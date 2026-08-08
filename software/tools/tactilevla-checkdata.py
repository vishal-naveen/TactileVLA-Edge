#!/usr/bin/env python3
"""Check a recorded LeRobot dataset before spending hours training on it.

    python3 ~/tactilevla-checkdata.py                     # newest dataset
    python3 ~/tactilevla-checkdata.py noodle10_2026...    # a specific one

Reports, and gives a PASS/FAIL on, the things that silently ruin a dataset:

  1. Achieved loop rate, read from the RECORDING LOG written by
     ~/tactilevla-record.sh. This cannot be measured from the dataset: LeRobot
     writes nominal timestamps (frame_index / fps), so the `timestamp` column
     reads as a flawless 33.3 ms even when the loop was really running at 18 Hz.
     The only report of the true rate is lerobot-record's console warning
     "Record loop is running slower (X Hz)", which is why record.sh tees it.
  2. Video/parquet agreement. Every parquet row must have a matching video frame.
     A mismatch means the encoder dropped frames and observations are misaligned
     with actions - unrecoverable, and invisible until the policy behaves oddly.
  3. Episode length spread. One wildly long or short episode is usually a botched
     take that should be deleted rather than trained on.
  4. Frame index integrity in the parquet (complete, gap-free per episode).
"""

from __future__ import annotations

import glob
import json
import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import numpy as np
import pandas as pd

LOCAL_ROOT = Path.home() / ".cache/huggingface/lerobot/local"
LOG_DIR = Path.home() / "tactilevla-logs"
SESSION_FILE = Path.home() / "tactilevla-session.json"

# lerobot-record warns once per slow control step. Slow steps in the first moments
# of an episode are the SVT-AV1 encoders spinning up for that episode's video files
# and are harmless - the operator has not started moving yet. Only slow steps once
# an episode is underway distort the recorded motion.
WARMUP_WINDOW_S = 2.0
# Fraction of all frames allowed to run slow mid-episode.
SLOW_STEP_TOLERANCE = 0.01
# Mid-episode stalls allowed per episode before failing, regardless of fraction.
SLOW_STEPS_PER_EPISODE = 2.0

SLOW_LOOP_RE = re.compile(
    r"^\w+\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*Record loop is running slower \(([0-9.]+) Hz\)"
)
EPISODE_START_RE = re.compile(
    r"^\w+\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*Recording episode (\d+)"
)
# The reset ("setup") phase between episodes runs its own record_loop, but that
# call passes no dataset= argument (lerobot_record.py:502-513), so nothing it
# does is written. A slow step there costs NOTHING - it happens while you are
# repositioning the object. Without this marker every stall during setup was
# attributed to the episode and failed a good dataset.
RESET_START_RE = re.compile(
    r"^\w+\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*Reset the environment"
)
# The streaming AV1 encoder DROPS a frame when its queue is full rather than
# blocking (datasets/video_utils.py, feed_frame: `except queue.Full`). No
# exception is raised, but the parquet row for that step is still written - so
# video and parquet desync for the rest of that episode, and the error only
# surfaces as a decode tolerance failure HOURS into training. The warning is
# logged at WARNING level (1st, then every 10th), so the record log sees it.
DROPPED_FRAME_RE = re.compile(r"Encoder queue full for (\S+), dropped (\d+) frame")


def parse_slow_steps(log_text: str) -> tuple[list[float], list[float], list[float]]:
    """Split slow-loop warnings into (warm-up, mid-episode, reset-phase) rates.

    Attribution is by log timestamp against the preceding phase marker:
    "Recording episode N" opens a recorded phase, "Reset the environment" opens
    an unrecorded one. Only mid-episode stalls distort the data - warm-up stalls
    are the encoders spinning up before the operator has moved, and reset-phase
    stalls are not written at all.

    LeRobot logs at one-second resolution, so a genuine stall inside the first
    WARMUP_WINDOW_S of an episode is indistinguishable from encoder warm-up and
    gets excused - acceptable, since nothing meaningful has happened that early.
    """
    fmt = "%Y-%m-%d %H:%M:%S"
    episode_start: datetime | None = None
    recording = False
    warmup: list[float] = []
    mid: list[float] = []
    reset: list[float] = []

    for line in log_text.splitlines():
        start_match = EPISODE_START_RE.match(line)
        if start_match:
            episode_start = datetime.strptime(start_match.group(1), fmt)
            recording = True
            continue
        if RESET_START_RE.match(line):
            recording = False
            continue
        slow_match = SLOW_LOOP_RE.match(line)
        if not slow_match:
            continue
        rate = float(slow_match.group(2))
        when = datetime.strptime(slow_match.group(1), fmt)
        if not recording:
            reset.append(rate)
        elif episode_start is None or (when - episode_start).total_seconds() <= WARMUP_WINDOW_S:
            warmup.append(rate)
        else:
            mid.append(rate)
    return warmup, mid, reset


def ffprobe_frame_count(path: Path) -> int | None:
    """Exact frame count for one video file, or None if ffprobe is unavailable."""
    try:
        out = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-count_frames",
                "-show_entries",
                "stream=nb_read_frames",
                "-of",
                "csv=p=0",
                str(path),
            ],
            capture_output=True,
            text=True,
            timeout=300,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    value = out.stdout.strip()
    return int(value) if value.isdigit() else None


def main() -> int:
    name = sys.argv[1] if len(sys.argv) > 1 else None
    if name is None:
        # Prefer the ACTIVE SESSION over "most recent" - most-recent silently picks
        # up throwaway rate-test datasets and then reports PASS on the wrong data.
        if SESSION_FILE.exists():
            name = json.loads(SESSION_FILE.read_text())["dataset"]
            root = LOCAL_ROOT / name
            print(f"active session: {name}\n")
            if not root.is_dir():
                print(f"Session registered but no data yet at {root}")
                return 1
        else:
            candidates = sorted(LOCAL_ROOT.glob("*"), key=lambda p: p.stat().st_mtime)
            if not candidates:
                print(f"No datasets in {LOCAL_ROOT}")
                return 1
            root = candidates[-1]
            print(f"No active session; using most recent: {root.name}\n")
    else:
        root = LOCAL_ROOT / name
        if not root.is_dir():
            print(f"Not found: {root}\nAvailable:")
            for p in sorted(LOCAL_ROOT.glob("*")):
                print(f"  {p.name}")
            return 1

    info = json.loads((root / "meta/info.json").read_text())
    fps = info["fps"]
    target_dt = 1.0 / fps

    print(f"dataset   : {root.name}")
    print(f"episodes  : {info['total_episodes']}")
    print(f"frames    : {info['total_frames']}")
    print(f"fps target: {fps}")
    cameras = {
        key: feat["shape"] for key, feat in info["features"].items() if feat["dtype"] == "video"
    }
    for key, shape in cameras.items():
        print(f"camera    : {key}  {shape[1]}x{shape[0]}")

    tasks_path = root / "meta/tasks.parquet"
    if tasks_path.exists():
        for task in pd.read_parquet(tasks_path).index.tolist():
            print(f"task      : {task!r}")
    print()

    files = sorted(glob.glob(str(root / "data" / "**" / "*.parquet"), recursive=True))
    if not files:
        print("FAIL: no parquet data files found")
        return 1
    df = pd.concat([pd.read_parquet(f) for f in files], ignore_index=True)

    print(f"{'ep':>4}  {'frames':>6}  {'nominal dur':>12}  {'index gaps':>10}")
    lengths = []
    index_gaps = 0
    for ep in sorted(df["episode_index"].unique()):
        e = df[df["episode_index"] == ep].sort_values("frame_index")
        idx = e["frame_index"].to_numpy()
        gaps = int((np.diff(idx) != 1).sum()) if len(idx) > 1 else 0
        index_gaps += gaps
        lengths.append(len(e))
        print(f"{ep:>4}  {len(e):>6}  {len(e) * target_dt:>11.1f}s  {gaps:>10}")

    print()
    failures = []

    # 1. Achieved loop rate - only knowable from the recording log.
    log_path = LOG_DIR / f"{root.name}-record.log"
    allow_no_log = os.environ.get("ALLOW_NO_LOG") == "1"
    if not log_path.exists():
        print(f"loop rate: NO LOG at {log_path}")
        print("  Cannot verify the record loop held its target rate. The dataset's")
        print("  timestamps are nominal (frame_index/fps) and always look perfect.")
        print("  Re-record with ~/tactilevla-record.sh, which tees the console log.")
        if not allow_no_log:
            failures.append(
                f"loop rate: UNVERIFIED - no log at {log_path.name}. "
                "Re-run with ALLOW_NO_LOG=1 to train anyway."
            )
    else:
        log_text = log_path.read_text()

        # POSITIVE CONTROL. Without this the gate cannot tell "no slow-loop
        # warnings" from "the log captured nothing at all" - and it reported the
        # strongest possible PASS ("held 30 Hz") against a 418-byte log that held
        # only an unrelated objc warning. A log that never saw LeRobot's output
        # is not evidence of a healthy loop; it is the absence of evidence.
        # Counted per line, like parse_slow_steps: EPISODE_START_RE anchors with
        # ^, and findall() without re.MULTILINE anchors to the start of the whole
        # string - it would report 1 for a log with 160 episode-start lines.
        n_starts = sum(1 for line in log_text.splitlines() if EPISODE_START_RE.match(line))
        if n_starts == 0:
            failures.append(
                f"loop rate: UNVERIFIED - {log_path.name} contains no 'Recording episode' "
                "lines, so it captured none of lerobot-record's output. The loop rate is "
                "unknown, NOT known-good. Check that record.sh still tees the console."
            )
        elif n_starts < len(lengths):
            failures.append(
                f"loop rate: PARTIAL - log has {n_starts} episode-start lines but the "
                f"dataset has {len(lengths)} episodes. The log is incomplete, so stalls "
                "in the unlogged episodes would be invisible."
            )
        else:
            print(f"log       : {n_starts} episode-start lines for {len(lengths)} episodes - log is complete")

        # Encoder frame drops -> video/parquet desync. The frame-count check
        # below catches the consequence; this catches the cause, by name.
        drops = DROPPED_FRAME_RE.findall(log_text)
        if drops:
            worst = {}
            for cam, count in drops:
                worst[cam] = max(worst.get(cam, 0), int(count))
            detail = ", ".join(f"{cam} >= {n}" for cam, n in sorted(worst.items()))
            failures.append(
                f"encoder: DROPPED FRAMES ({detail}). The AV1 encoder queue filled and "
                "frames were discarded while parquet rows were still written - video and "
                "actions are misaligned. Re-record the affected episodes, and use "
                "--dataset.camera_encoder.vcodec=auto (hardware encoder) next time."
            )
        else:
            print("encoder   : no dropped-frame warnings")

        warmup, mid, reset = parse_slow_steps(log_text)
        n_episodes = max(len(lengths), 1)
        mid_frac = len(mid) / max(len(df), 1)
        if not warmup and not mid and not reset:
            print(f"loop rate: held {fps} Hz - no slow-loop warnings in {log_path.name}")
        else:
            if warmup:
                print(
                    f"loop rate: {len(warmup)} slow step(s) at episode start "
                    f"(slowest {min(warmup):.1f} Hz) - encoder warm-up, harmless"
                )
            if reset:
                print(
                    f"loop rate: {len(reset)} slow step(s) during SETUP "
                    f"(slowest {min(reset):.1f} Hz) - not recorded, no effect on the data"
                )
            if mid:
                print(
                    f"loop rate: {len(mid)} slow step(s) MID-EPISODE "
                    f"({mid_frac:.2%} of frames, slowest {min(mid):.1f} Hz, target {fps})"
                )
            else:
                print(f"loop rate: no mid-episode stalls - held {fps} Hz while recording")
        if mid_frac > SLOW_STEP_TOLERANCE or len(mid) / n_episodes > SLOW_STEPS_PER_EPISODE:
            failures.append(
                f"loop rate: {len(mid)} mid-episode stalls ({mid_frac:.2%} of frames, "
                f"slowest {min(mid):.1f} Hz). Camera resolution or encoder load is too high "
                "for this machine - lower TOP_RES in ~/tactilevla-record.sh and re-record."
            )

    if index_gaps:
        failures.append(f"frame indices: {index_gaps} gaps found - episodes are not contiguous")

    # 2. Video/parquet agreement.
    for key in cameras:
        video_files = sorted(glob.glob(str(root / "videos" / key / "**" / "*.mp4"), recursive=True))
        counts = [ffprobe_frame_count(Path(f)) for f in video_files]
        if not video_files:
            failures.append(f"video: no files found for {key}")
            continue
        if any(c is None for c in counts):
            print(f"{key}: could not count video frames (ffprobe unavailable) - SKIPPED")
            continue
        total_video = sum(counts)
        status = "OK" if total_video == len(df) else "MISMATCH"
        print(f"{key}: {total_video} video frames vs {len(df)} parquet rows - {status}")
        if total_video != len(df):
            failures.append(f"video: {key} has {total_video} frames but there are {len(df)} rows")

    # 3. Episode length spread.
    if lengths:
        arr = np.array(lengths)
        print(f"episode length: min {arr.min()}  median {int(np.median(arr))}  max {arr.max()}")
        outliers = [
            int(ep)
            for ep, n in zip(sorted(df["episode_index"].unique()), lengths, strict=False)
            if n < np.median(arr) * 0.4 or n > np.median(arr) * 2.5
        ]
        if outliers:
            print(f"  length outliers (consider deleting): episodes {outliers}")

    print()
    if failures:
        print("FAIL - do not train on this dataset yet:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("PASS - dataset is sound. Safe to train.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
