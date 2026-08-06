# Recording protocol: position generalization

The first policy trained for this project worked on its first autonomous attempt and then
only from the spot it was trained in. That is the expected result for ten episodes from a
single pickup region: it learned one trajectory, not the task. This document is the
protocol for the dataset that fixes it.

## What the evidence says about episode counts

LeRobot's docs suggest "at least 50 episodes, with 10 episodes per location." The field
reports say 10 per location is often not enough. The closest published match to this
setup — SO-101, ACT, pick-and-place into a container, a 12 GB GPU — went:

| Attempt | Data | In-distribution | Held-out positions |
|---|---|---|---|
| 1 | 50 eps (10 x 5 locations) | 0% | — |
| 2 | 72 eps (10 x 6 bins) | 60% | 10% |
| 3 | ~25 eps/bin + ±45° yaw | 90% | 75% |

An independent field report found the same shape: 20 episodes centre-only gave 60%; 100
episodes varying one axis gave 90% in-distribution and no generalization; 340 episodes
varying two axes gave 79% with genuine generalization.

The original ALOHA/ACT paper reached 80%+ with 50 demos per task at randomized positions,
but on far better hardware with expert teleoperation. Do not calibrate against it.

**Read:** ~10 per cell buys competence *inside* that cell. Generalizing *between* cells
needs ~20 per cell plus orientation variation.

## The failure modes that are not about data volume

Three of the four things that killed the published runs cost nothing to avoid:

1. **The camera moved between recording and evaluation.** Produces an arm that pecks at
   nothing. Tape everything down; verify indices *and* physical position before each
   session.
2. **Demonstrations grasped the object inconsistently.** The policy faithfully learns a
   bad grasp. Pick one grasp point and hit it every time.
3. **Watching the arm instead of the camera feeds while teleoperating.** If you cannot do
   the task from the camera images alone, neither can the policy.
4. **Sparse coverage with gaps.** Plot the positions actually recorded; stratified cells
   beat randomizing by feel.

## The grid

A 3x3 grid over the reachable region, drawn by `software/tools/tactilevla-grid.py`, which
maps four clicked table corners through a homography so cells are uniform *on the table*
rather than in the image.

```
        A       B       C          letter = left-to-right across the image
 far  [A1]    [B1]    [C1]         number = depth (1 far, 3 near)
      [A2]    [B2]*   [C2]         * held out: no training data, tested after
 near [A3]    [B3]    [C3]
```

- **8 recorded cells x 20 episodes = 160 episodes.**
- **B2 is held out.** It is the only cell in a 3x3 with trained data on all four sides,
  which makes it the cleanest interpolation test available. Never hold out a corner —
  that tests extrapolation, which fails for essentially every imitation-learning policy,
  so a failure there teaches nothing actionable.
- Cells must clear ~4 cm in both axes. Below that they are smaller than the arm's own
  ±2 mm repeatability plus placement error, and the grid stops carrying information.
- Verify the arm reaches a real grasp pose — jaws closed, object lifted — at every cell
  before recording. Not a hover; a grasp.

## Per-episode discipline

- Place the object at a **different spot inside the cell** each time, not the exact
  centre.
- Rotate it across the cell's episodes: roughly **−45°, −20°, 0°, +20°, +45°**. Adding
  yaw variation is what moved the reference run from 10% to 75% on held-out positions.
- **Move briskly.** Speed is learned from the demonstrations; no inference setting
  recovers a slow demo.
- Keep the same motion shape every time: approach, grasp, lift, carry, release.
- Change nothing else — same object, same target, same lights, cameras untouched.

## Round structure

One round = 5 episodes in each of the 8 cells, walking the perimeter:

```
A1 -> B1 -> C1 -> C2 -> C3 -> B3 -> A3 -> A2
```

Four rounds gives 160. Rounds rather than 20-at-a-time per cell, because technique drifts
and light shifts over 90 minutes; rounds spread that evenly across cells instead of
confounding cell with time, and an early stop still leaves balanced coverage.

Run `checkdata` after every round, not only at the end — a problem then costs 40 episodes
instead of 160. Five minutes between rounds; the STS3215s overheat, and `verify.py`
reports their temperature.

## Evaluation

Trained cells measure execution. **The held-out cell measures generalization**, and it is
the only number that distinguishes a policy that learned the task from one that memorized
eight trajectories. Both score high on trained cells.

Score in stages rather than pass/fail:

| Score | Reached |
|---|---|
| 0.2 | got to the object |
| 0.4 | grasped it |
| 0.7 | carried it over the target |
| 1.0 | released it in the target |

Ten trials in the held-out cell, five in each trained cell. Trained-cell average versus
held-out average is the result. If trained cells succeed and the held-out cell fails, the
policy memorized positions: more episodes per cell, or a tighter grid.

## Resolution

Recording at 800x600 (overhead) and 640x480 (wrist). Higher is not better here:

- **ACT does not resize images.** They enter ResNet18 at native resolution, and the
  transformer attends over the feature map, so cost grows faster than pixel count. At
  1920x1080 with batch 8, ACT needs more than 21 GB and does not fit on either machine
  in this project.
- **SmolVLA resizes to 512x512 internally** (`resize_imgs_with_padding`), so detail above
  ~512 px is discarded by the target model regardless.
- Measured ACT step time at 800x600, batch 8: **1.41 s/step**. A 160-episode dataset at
  5 epochs is ~45,000 steps — about 17.6 h on an M-series Mac, ~4.6 h on an RTX 3060.

Resolution also does not widen the field of view. To see more table, move the camera.
