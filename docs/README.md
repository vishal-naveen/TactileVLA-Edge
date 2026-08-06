# Documentation

Organized along [Diataxis](https://diataxis.fr) lines:

| Path | Kind | Contents |
|---|---|---|
| `bringup.md` | Tutorial | First-time SO-101 bring-up, start to teleoperation |
| `recording-protocol.md` | How-to | Collecting a dataset that generalizes across object positions |
| `training-setup.md` | How-to | Training machine setup (Windows + WSL2, RTX 3060) |
| `pc-setup-runbook.md` | How-to | The same setup as an agent-executable runbook with hard gates |
| `adr/` | Explanation | Architecture decision records, numbered, never renumbered |
| `log/` | Reference | Dated engineering log entries |
| `../software/tools/` | Reference | Session scripts, and the failure modes they encode |

Docs are reviewed in the same PR as the code they describe.

## A note on scope

Internal planning material — strategy, competitive positioning, go/no-go criteria, funding and
team agreements — is deliberately kept out of this repository. It is gitignored rather than
published. What lives here is what someone reproducing the work needs.
