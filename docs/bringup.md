# SO-101 bring-up

Getting from two arms in a box to the leader arm driving the follower in real time.

> **Read the electrical section first.** One mistake here destroys six servos and is not
> recoverable.

## Electrical safety

The SO-ARM101 Pro kit ships **two power supplies at different voltages**:

| Arm | Supply | Identify it by |
|---|---|---|
| Follower | **12V** | The gripper jaws that close on objects. Motors C001 / C018 / C047, all 1:345 |
| Leader | **5V** | The hand grip you hold. Motors C044 / C001 / C046, mixed gear ratios |

**12V into the leader burns all six of its motors.** Assembled arms look nearly identical, so
label both power supplies physically before the first power-on.

Also:

- USB alone does not power the arm. Both the barrel jack (5.5x2.1 mm) and USB must be connected.
- On the Waveshare bus servo adapter, set both jumpers to the **B (USB)** channel.
- Power off before plugging or unplugging anything.
- Clear a 1 m radius before any motion command, and clamp the arm to the table.
- On abnormal motion or noise: kill power first, diagnose second.

## 1. Find the serial ports

```bash
lerobot-find-port
```

Run it interactively — it blocks on a prompt. Plug in one arm, run the command, unplug that arm,
press Enter, and it reports which port disappeared.

On macOS the "before" list includes roughly 140 pseudo-terminals and any paired Bluetooth
devices. Ignore all of it; the arms appear as `/dev/tty.usbmodem*`. On Linux they are
`/dev/ttyACM0` and `/dev/ttyACM1` in plug order, and you will likely need:

```bash
sudo chmod 666 /dev/ttyACM*
```

## 2. Motor IDs

Each servo needs a unique bus ID (gripper = 6 down to shoulder_pan = 1). **Arms bought
pre-assembled generally ship with IDs already set**, since they cannot be daisy-chained
otherwise.

The cheapest way to find out is to skip ahead to calibration (step 3). If the joints respond,
the IDs are set and you never need `lerobot-setup-motors`. If you get
`Motor 'gripper' not found`, they are not:

```bash
lerobot-setup-motors --robot.type=so101_follower --robot.port=/dev/tty.usbmodemXXXX
```

This must be done **one motor at a time, not daisy-chained**. The script prompts for the gripper
first (id 6), then wrist_roll (5), and so on down to shoulder_pan (1). Label each motor F1-F6
physically as you go. Then daisy-chain all six with shoulder_pan connected to the board.

Note that `Motor 'gripper' not found` can also mean wrong voltage or a loose cable — check those
before concluding the IDs are unset.

## 3. Calibrate

Calibration maps physical joint positions onto software state. It cannot be skipped, and buying
pre-assembled arms does not cover it: the calibration files are generated per-machine and live in
`~/.cache/huggingface/lerobot/calibration/{robots,teleoperators}/`.

```bash
lerobot-calibrate \
  --robot.type=so101_follower \
  --robot.port=/dev/tty.usbmodemXXXX \
  --robot.id=follower_01

lerobot-calibrate \
  --teleop.type=so101_leader \
  --teleop.port=/dev/tty.usbmodemYYYY \
  --teleop.id=leader_01
```

Procedure: move every joint to mid-range, press Enter, then sweep each joint through its full
travel. The terminal showing no signal from servo 5 during this is known and harmless.

**The `--robot.id` and `--teleop.id` strings are permanent.** They are the lookup key into the
calibration files, and every dataset you record is tied to them. Changing one silently
invalidates prior data. Pick them once.

## 4. Teleoperate

```bash
lerobot-teleoperate \
  --robot.type=so101_follower \
  --robot.port=/dev/tty.usbmodemXXXX \
  --robot.id=follower_01 \
  --teleop.type=so101_leader \
  --teleop.port=/dev/tty.usbmodemYYYY \
  --teleop.id=leader_01
```

The leader now drives the follower in real time. That is the Phase 1 milestone.

## 5. Cameras (needed only for data collection)

Teleoperation needs no cameras. Policy learning is entirely camera-gated.

```bash
lerobot-find-cameras opencv
```

Use `MJPG` as the fourcc — `YUYV` lags badly. Do not put two cameras on one USB hub. Add them to
teleoperation with `--robot.cameras=...` and `--display_data=true` to confirm framing before
recording anything.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `Could not connect on port ...` | Linux permissions — `sudo chmod 666 /dev/ttyACM*` |
| `Motor 'gripper' not found` | Wrong voltage, loose cable, or unset motor IDs |
| `Magnitude 30841 exceeds 2047` | Bad zero offset — power-cycle, or re-center with the Seeed servo tools, then recalibrate |
| `mean is infinity ...` | Camera key names differ between recording and evaluation |
| Keyboard dead while recording | `pynput` missing or below LeRobot's minimum version |
| Visualizer misbehaving | `rerun-sdk` outside LeRobot's supported range |

After any servo replacement or repair, delete the relevant calibration JSON and recalibrate.

Resolve dependency versions from LeRobot's own `pyproject.toml`, not from third-party guides —
several circulating guides pin versions below LeRobot's actual minimums. See
[ADR-0002](adr/0002-pin-lerobot-version.md).
