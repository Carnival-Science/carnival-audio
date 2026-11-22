# AGENTS.md — Pulse

Pulse is an Odin audio analysis/CLAP-plugin project by Carnival Science.
Alicorn is a separate repository and stays a UI/rendering/accessibility
library: no audio, DSP, or plugin-hosting code may be added to Alicorn
(Carnival-Science/Alicorn#122 is a non-negotiable boundary).

## Layout scopes

- `core/` — source-independent audio API, deterministic replay, analysis DSP,
  bounded transport. **Must not import alicorn, SDL, CLAP, or any platform
  audio/graphic library.** Build with `tools/test.ps1`; the boundary check
  (`tools/check-boundary.ps1`) enforces this.
- `clap/` — CLAP foreign bindings and the headless plugin. May import `core/`
  and the pinned CLAP headers; must not import alicorn until the editor glue
  milestone, which imports alicorn only through the documented surface.
- `standalone/` — desktop application entry; the only place that imports
  alicorn.
- `verification/` — canonical measurement-record types shared with the
  verification laboratory (formats only, no hosting logic).

## Checks

Run `.\tools\test.ps1` before proposing changes. Keep the real-time callback
free of allocation, locking, I/O, and rendering work; analysis overrun must
produce explicit invalid state, never silently valid readings.

## Conventions

Match Alicorn's Odin style (tabs, `Pascal_Snake` naming, `@(test)`
procedures). Determinism: fixed block sizes, documented FTZ/DAZ and FMA
policy, explicit rounding; golden test vectors in `tests/vectors/`.
