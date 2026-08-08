#!/usr/bin/env python3
"""Upload a locally recorded dataset to the Hugging Face Hub.

    python3 ~/tactilevla-push-dataset.py                    # active session, PRIVATE
    python3 ~/tactilevla-push-dataset.py <dataset>          # a specific one
    python3 ~/tactilevla-push-dataset.py <dataset> --public

This is the bridge to the PC. Recording happens on the Mac; SmolVLA training
needs the RTX 3060. The Hub is how the dataset crosses, and nothing else in the
pipeline uploads anything (record.sh runs with --dataset.push_to_hub=false).

Defaults to PRIVATE. A 160-episode dataset is ~1 GB and is your own unpublished
work; make it public deliberately, not by accident.

First time only:
    huggingface-cli login       # or: export HF_TOKEN=hf_...
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

LOCAL_ROOT = Path.home() / ".cache/huggingface/lerobot/local"
SESSION_FILE = Path.home() / "tactilevla-session.json"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("dataset", nargs="?", help="dataset name (default: the active session)")
    ap.add_argument("--user", help="HF username or org (default: your logged-in account)")
    ap.add_argument("--public", action="store_true", help="make the repo public (default: private)")
    ap.add_argument("--no-videos", action="store_true", help="upload metadata + parquet only")
    args = ap.parse_args()

    name = args.dataset
    if not name:
        if not SESSION_FILE.exists():
            sys.exit("No active session and no dataset named. Pass one explicitly.")
        name = json.loads(SESSION_FILE.read_text())["dataset"]
        print(f"active session: {name}")

    root = LOCAL_ROOT / name
    if not root.is_dir():
        print(f"Not found: {root}\nAvailable:")
        for p in sorted(LOCAL_ROOT.glob("*")):
            print(f"  {p.name}")
        return 1

    from huggingface_hub import whoami

    user = args.user
    if not user:
        try:
            user = whoami()["name"]
        except Exception:
            sys.exit(
                "Not logged in to the Hugging Face Hub.\n"
                "  huggingface-cli login      (or export HF_TOKEN=hf_...)"
            )

    repo_id = f"{user}/{name}"
    info = json.loads((root / "meta/info.json").read_text())
    size_gb = sum(f.stat().st_size for f in root.rglob("*") if f.is_file()) / 1024**3

    print()
    print(f"  dataset    {name}")
    print(f"  episodes   {info['total_episodes']}   frames {info['total_frames']}")
    print(f"  size       {size_gb:.2f} GB")
    print(f"  -> repo    {repo_id}   ({'PUBLIC' if args.public else 'private'})")
    print()
    reply = input("  Upload? [y/N] ").strip().lower()
    if not reply.startswith("y"):
        print("  Cancelled.")
        return 1

    from lerobot.datasets.lerobot_dataset import LeRobotDataset

    print("\nloading dataset...")
    ds = LeRobotDataset(repo_id=f"local/{name}", root=root)
    print(f"uploading to {repo_id} - this takes a while for ~1 GB...")
    # upload_large_folder is the resumable path; a dropped connection partway
    # through a 1 GB push should not mean starting over.
    ds.push_to_hub(
        private=not args.public,
        push_videos=not args.no_videos,
        upload_large_folder=True,
        tags=["so101", "act", "tactilevla-edge"],
    )
    print(f"\ndone: https://huggingface.co/datasets/{repo_id}")
    print("\nOn the PC:")
    print(f"    bash ~/tactilevla-train-smolvla.sh {repo_id}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
