# hardware/

CAD, STLs, PCB sources, and bills of materials.

- SO-101 arm parts derive from [TheRobotStudio/SO-ARM100](https://github.com/TheRobotStudio/SO-ARM100).
  Print in PLA+, 0.2 mm layers, 15% infill.
- AnySkin molds and PCB derive from the [AnySkin project](https://any-skin.github.io).
- Custom PCB revisions land here as they are designed.

## Conventions

- BOM part numbers are unique and never reused. A changed part gets a new revision, not an edited
  entry.
- Binary sources (CAD, PCB) use git-LFS with file locking. One editor per file — these formats do
  not merge.
- Fabrication spend is preceded by a short engineering change note, so the reason for a revision
  survives.

Licensed CERN-OHL-P v2 — see [LICENSE-hardware](../LICENSE-hardware).
