# Contributing

## Branching

GitHub Flow. `main` is protected and always works; short-lived branches merge via PR with one
review and green CI. A red `main` stops everyone and gets fixed before anything else proceeds.

Branch names: `feat/tactile-sync`, `fix/calibration-offset`, `docs/bringup`.

## Commits

[Conventional Commits](https://www.conventionalcommits.org), from the first commit:

```
<type>: <description>

<optional body>
```

Types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `perf`, `ci`.

## Pull requests

- Docs change in the same PR as the code they describe.
- New behaviour ships with a test. Most robotics repos have no tests; that is a differentiator
  worth keeping.
- CI must be green: lint, then test, under 10 minutes.

## Architecture decisions

Anything hard to reverse gets an ADR in `docs/adr/`. See
[ADR-0001](docs/adr/0001-record-architecture-decisions.md) for what qualifies.

## Engineering log

Dated entries in `docs/log/`, tagged by subsystem: `[SW]`, `[FW]`, `[PCB]`, `[CAD]`,
`[INTEGRATION]`. Write down what failed, not just what worked — the failures are what you will
want back in three months.

## What never gets committed

- Secrets. `.env` is gitignored; `.env.example` is the tracked template.
- Datasets, checkpoints, and video. Those live on the Hugging Face Hub.
- Calibration files. They are machine-specific and generated locally.

## Binary design files

CAD and PCB sources use git-LFS with file locking — one editor per file at a time, since binary
formats cannot be merged.
