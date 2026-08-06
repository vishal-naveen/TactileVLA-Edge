#!/usr/bin/env python3
"""Check whether macOS is actually delivering keystrokes to pynput.

lerobot-record 0.5.2 relies entirely on pynput's global keyboard listener for
its arrow-key / Escape controls. On macOS that requires Accessibility (and
Input Monitoring) permission for the terminal app. Without it the listener
starts fine and then silently receives nothing.

    python3 ~/tactilevla-keytest.py

Press LEFT, RIGHT, and ESC. If nothing registers, permission is missing.
"""

from __future__ import annotations

import sys
import time

DURATION_S = 20


def main() -> int:
    try:
        from pynput import keyboard
    except Exception as exc:  # noqa: BLE001
        print(f"pynput failed to import: {exc}")
        return 1

    seen: set[str] = set()

    def on_press(key) -> None:
        if key == keyboard.Key.right:
            seen.add("right")
            print("  RIGHT arrow  -> would end episode / skip reset")
        elif key == keyboard.Key.left:
            seen.add("left")
            print("  LEFT arrow   -> would re-record episode")
        elif key == keyboard.Key.esc:
            seen.add("esc")
            print("  ESC          -> would stop the session")

    listener = keyboard.Listener(on_press=on_press)
    listener.start()

    print(f"Listening for {DURATION_S}s. Press LEFT, RIGHT, and ESC now.")
    print("(Keep THIS terminal window focused.)\n")

    start = time.perf_counter()
    try:
        while time.perf_counter() - start < DURATION_S and len(seen) < 3:
            time.sleep(0.1)
    except KeyboardInterrupt:
        pass
    finally:
        listener.stop()

    print()
    if not seen:
        print("RESULT: NO KEYS DETECTED.")
        print("macOS is not delivering keystrokes to pynput. Grant permission in")
        print("System Settings > Privacy & Security > Accessibility (and Input")
        print("Monitoring) for your terminal app, then FULLY QUIT and reopen it.")
        return 1

    missing = {"right", "left", "esc"} - seen
    if missing:
        print(f"RESULT: PARTIAL - detected {sorted(seen)}, never saw {sorted(missing)}.")
        print("Try again and press the missing keys; if they still never appear,")
        print("something else is intercepting them.")
        return 1

    print("RESULT: ALL KEYS WORK. Recording controls will respond.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
