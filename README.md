# carnival-audio

Carnival Science's consolidated audio foundations repository: the
source-independent Odin core behind Pulse, its integration tests, and the
verification laboratory that checks it with independent numerical references.

It is **one repository with strict internal module boundaries — not a
monolithic application**. Keeping the modules together lets the abstractions
earn their shape against real plugins before anything is split into an
independently versioned library. Pulse remains the product name; its standalone
application will live at `products/pulse`.

## Project boundaries (non-negotiable)

- **Alicorn** (separate repository): UI, rendering, accessibility, native host
  integration. No audio, DSP, or plugin-hosting code ever.
- **carnival-audio** (this repository): the audio analysis core
  (`core/stream`, `core/dsp`, `core/transport`), verification
  (`verification/`), and later the CLAP/WASAPI adapters and the Pulse product.
- **Verification** (`verification/`): independent headless verification of
  measurement records. It depends on core record formats only and never
  imports `core/dsp`, `adapters/` or `products/`; it uses its own naive DFT and
  external offline tools as references.

## Module map and dependency direction

```
products/       (future) products/pulse: standalone meter + embedded editor
    |
    v
adapters/       (future) adapters/clap (M1), adapters/wasapi (M3)
    |
    v
core/           stream | dsp | transport            <- the stable center

verification/   record formats only; independent numerical references
research/       (future) isolated execution research
```

Imports point only toward the core: products may import adapters and core;
adapters may import core; core imports only Odin `core:` packages and its
sibling core packages. `verification/` sits beside the chain — it may read core
record formats, but it never imports the DSP implementation, adapters or
products, so it cannot validate Pulse with Pulse's own math.

| Path | Package | Role | State |
| --- | --- | --- | --- |
| `core/stream` | `stream` | Stream descriptor, sample clock, WAV replay, generated signals | implemented (M0) |
| `core/dsp` | `dsp` | Sample peak, windowed RMS, peak hold, FFT, correlation | implemented (M0) |
| `core/transport` | `transport` | Bounded SPSC block ring, revisioned snapshots | implemented (M0) |
| `tests` | `tests` | Integration tests: partitions, WAV round-trip, memory ceiling | implemented (M0) |
| `verification` | — | Independent A−1 measurement-record verification | planned (M2) |
| `adapters` | — | CLAP (M1) and WASAPI capture (M3) adapters | destination only |
| `products` | — | `products/pulse` standalone meter and editor | destination only |
| `research` | — | Isolated execution research | destination only |

`adapters/`, `products/` and `research/` do not exist yet. They are recorded in
[docs/architecture.md](docs/architecture.md) as architectural destinations so
the current layout points at the founder's extraction plan.

## Documentation

- [Architecture](docs/architecture.md) — module map, dependency direction,
  architectural destinations, future-extraction table, state separation.
- [Determinism policy](docs/determinism.md) — FMA/FTZ policy, measurement
  conventions, tolerances, partition invariance.
- [Verification](verification/README.md) — A−1 thesis, method stance,
  independence rule.
- [Program research audit](docs/research/program-audit-2026-11-22.md) —
  ecosystem findings, reuse-vs-build decisions, risk register.

## Build and test

Milestone 0 is a library plus headless tests; there is no executable yet.
From the repository root (Windows PowerShell):

```powershell
.\tools\check-boundary.ps1   # core/ and verification/ import boundaries
.\tools\build.ps1            # odin check every package with -vet
.\tools\test.ps1             # boundary gate + every package's @(test)s
```

The tools resolve Odin from `-Odin`, `PULSE_ODIN`, the local development path,
or `PATH`. Packages import each other through the `carnival` collection, which
the scripts point at the repository root (`-collection:carnival=.`).

## Status

- Milestone 0 (source-independent audio analysis core): implemented
  (`core/stream`, `core/dsp`, `core/transport`, headless integration tests).
- Milestone 1 (headless CLAP meter, Carnival-Science/Alicorn#237): not started.
- Milestone 2 (verification laboratory A−1, #236): not started;
  `verification/` is prepared but has no implementation.
- Milestone 3 (standalone Mini meter + embedded CLAP editor, #131): not
  started.

## License

zlib — matching Alicorn. Third-party notes in `NOTICE.md`.
