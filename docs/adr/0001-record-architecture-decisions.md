# ADR-0001: Record architecture decisions

- **Status:** Accepted
- **Date:** 2026-08-04

## Context

This project makes a number of hard-to-reverse technical choices early: servo family, arm
platform, ML framework, tactile sensor, fusion method, dataset format. Decisions like these tend
to be made once, in a conversation nobody wrote down, and then get re-litigated for months
because the reasoning was lost. On a multi-person project with a research output attached, that
cost compounds.

## Decision

Every hard-to-reverse technical decision gets an Architecture Decision Record in `docs/adr/`,
numbered sequentially and never renumbered.

Format: Context / Decision / Consequences, with a Status of Proposed, Accepted, Deprecated, or
Superseded. Superseding an ADR means writing a new one that references the old, not editing
history.

An ADR is warranted when reversing the choice later would cost more than a day, or when it
constrains what other subsystems can do. Routine implementation choices do not need one.

## Consequences

- Onboarding reads as a sequence of decisions rather than an archaeology exercise.
- Some overhead per decision, which is the point — it forces the reasoning to be explicit.
- The ADR log doubles as the paper's methods-justification trail, which matters for publication.
