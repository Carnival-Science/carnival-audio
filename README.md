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
| `third_party/clap` | `clap` | Pinned CLAP 1.2.10 ABI declarations + vendored headers | implemented (M1) |
| `adapters/clap` | `clap_adapter` | Generic CLAP lifecycle, params, state extensions | implemented (M1) |
| `products/pulse` | `pulse` | Pulse headless CLAP meter backend | implemented (M1) |
| `tests` | `tests` | Integration tests: partitions, WAV round-trip, memory ceiling | implemented (M0) |
| `verification` | — | Independent A−1 measurement-record verification | planned (M2) |
| `adapters` | `clap_adapter` | CLAP lifecycle adapter (M1); WASAPI capture (M3) | `adapters/clap` implemented (M1) |
| `products` | `pulse` | Pulse meter (M1); standalone app and editor (M3) | headless CLAP meter implemented (M1) |
| `research` | - | Isolated execution research | destination only |

`adapters/clap` and `products/pulse` now exist for Milestone 1; `research/` and
the standalone/editor products remain architectural destinations recorded in
[docs/architecture.md](docs/architecture.md).

## Documentation

- [Architecture](docs/architecture.md) — module map, dependency direction,
  architectural destinations, future-extraction table, state separation.
- [Determinism policy](docs/determinism.md) — FMA/FTZ policy, measurement
  conventions, tolerances, partition invariance.
- [Headless CLAP meter](docs/clap-plugin.md) — build, ABI proof, lifecycle,
  params/state schema, measurement export, RT evidence and limits.
- [Milestone 1 validation](docs/benchmarks/clap-milestone1-validation-2026-11-22/README.md)
  — pinned clap-validator/clap-trap/clap-info results.
- [Verification](verification/README.md) — A‑1 thesis, method stance,
  independence rule.
- [Program research audit](docs/research/program-audit-2026-11-22.md) —
  ecosystem findings, reuse-vs-build decisions, risk register.

## Build and test

From the repository root:

```powershell
.\tools\check-boundary.ps1   # core/, third_party/, adapters/, products/ boundaries
.\tools\build.ps1            # odin check every package, then build out\pulse.clap
.\tools\test.ps1             # boundary gate + C ABI probes + every package's tests
```

```sh
./tools/test.sh              # same gates on Linux/macOS (requires pwsh for the boundary gate)
```

The tools resolve Odin from `-Odin`, `PULSE_ODIN`, the local development path,
or `PATH`. Packages import each other through the `carnival` collection, which
the scripts point at the repository root (`-collection:carnival=.`). CI pins
Odin `dev-2026-11a`; cross-platform numeric reproducibility of measurement
records is not yet claimed.

## Status

- Milestone 0 (source-independent audio analysis core): implemented
  (`core/stream`, `core/dsp`, `core/transport`, headless integration tests).
- Milestone 1 (headless CLAP meter, Carnival-Science/Alicorn#237): implemented
  (`third_party/clap` ABI + C proof, `adapters/clap`, `products/pulse` Windows
  `.clap`). External validation and known gaps in `docs/benchmarks/`.
- Milestone 2 (verification laboratory A‑1, #236): not started;
  `verification/` is prepared but has no implementation.
- Milestone 3 (standalone Mini meter + embedded CLAP editor, #131): not
  started.

## License

zlib — matching Alicorn. Third-party notes in `NOTICE.md`.
