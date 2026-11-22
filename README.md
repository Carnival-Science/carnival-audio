# Pulse

Pulse is Carnival Science's production-quality audio meter and visualizer: a
source-independent Odin audio analysis core, a standalone meter, and a native
CLAP plugin. It is the first real reference plugin for Carnival Science's audio
research, dogfooding Alicorn the way Scratchpad and Punks do — while keeping
Alicorn strictly a UI/rendering/accessibility library.

## Project boundaries (non-negotiable)

- **Alicorn** (separate repo): UI, rendering, accessibility, native host
  integration. No audio, DSP, or plugin-hosting code ever.
- **Pulse** (this repo): Odin audio analysis core, standalone application, CLAP
  plugin. Depends on Alicorn only at the standalone/editor edges.
- **Verification** (sibling repo `audio-verification`): independent headless
  plugin host, test methodology, behavioral evidence. Develops independently of
  Pulse releases; uses Pulse's headless CLAP meter as its first reference
  specimen, not its only subject.

## Documentation

- [Architecture](docs/architecture.md) — module map, data flow, state separation.
- [Determinism policy](docs/determinism.md) — FMA/FTZ policy, measurement
  conventions, tolerances, partition invariance.
- [Program research audit](docs/research/program-audit-2026-11-22.md) —
  ecosystem findings, reuse-vs-build decisions, risk register.

## Status

- Milestone 0 (source-independent audio analysis core): implemented
  (`core/audio`, `core/analysis`, `core/transport`, headless tests).
- Milestone 1 (headless CLAP meter, Carnival-Science/Alicorn#237): not started.
- Milestone 2 (verification laboratory A−1, #236): not started.
- Milestone 3 (standalone Mini meter + embedded CLAP editor, #131): not started.

## License

zlib — matching Alicorn. Third-party notes in `NOTICE.md`.
