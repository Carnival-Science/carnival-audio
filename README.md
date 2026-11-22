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
  (`core/stream`, `core/dsp`, `core/transport`, `core/meter`), verification
  (`verification/`), and the CLAP/WASAPI adapters and the Pulse products.
- **Verification** (`verification/`): independent headless verification of
  measurement records, partitions, automation classes, state migration,
  isolation, tails and perturbations. It depends on core record formats only
  and never imports `core/dsp`, `adapters/` or `products/`; it uses its own
  seeded generator, closed-form peak/RMS and naive DFT as references.

## Module map and dependency direction

```
products/       products/pulse (CLAP) + products/pulse-mini (standalone)
                + products/reference fixtures
    |
    v
adapters/       adapters/clap, adapters/wasapi
    |
    v
core/           stream | dsp | transport | meter          <- the stable center

verification/   independent CLAP host + worker + probes; record formats and
                third_party/clap ABI only, independent numerical references
research/       (future) isolated execution research
```

Imports point only toward the core: products may import adapters and core;
adapters may import core; core imports only Odin `core:` packages and its
sibling core packages. Only `adapters/wasapi` may import `vendor:miniaudio`.
`verification/` sits beside the chain — it may read core
record formats, but it never imports the DSP implementation, adapters or
products, so it cannot validate Pulse with Pulse's own math.

| Path | Package | Role | State |
| --- | --- | --- | --- |
| `core/stream` | `stream` | Stream descriptor, sample clock, WAV replay, generated signals | implemented (M0) |
| `core/dsp` | `dsp` | Sample peak, windowed RMS, peak hold, FFT, correlation | implemented (M0) |
| `core/transport` | `transport` | Bounded SPSC block ring, revisioned snapshots | implemented (M0) |
| `core/meter` | `meter` | Source-independent meter engine (analysis, epochs, records, snapshots) | implemented (M3.0) |
| `third_party/clap` | `clap` | Pinned CLAP 1.2.10 ABI declarations + vendored headers + draft extensions | implemented (M1/M3) |
| `third_party/miniaudio` | — | Vendored miniaudio 0.11.26 single header (public domain) | vendored (M3.1) |
| `adapters/clap` | `clap_adapter` | Generic CLAP lifecycle, params, authoring state, draft extensions | implemented (M1/M3) |
| `adapters/wasapi` | `wasapi` | Shared-mode WASAPI loopback capture, ring, recovery | implemented (M3.1) |
| `products/pulse` | `pulse` | Pulse headless CLAP meter binding | implemented (M1/M3.0) |
| `products/pulse-mini` | `main` | Standalone Mini meter (console, loopback) | implemented (M3.1) |
| `tests` | `tests` | Integration tests: partitions, WAV round-trip, memory ceiling | implemented (M0) |
| `products/reference` | per-plugin | Gain, biquad, delay + defective test fixtures | implemented (M2) |
| `verification` | — | Independent A−1 host, worker, probes and census | implemented (M2) |
| `adapters` | `clap_adapter` | CLAP lifecycle adapter (M1); WASAPI capture (M3) | `adapters/clap` implemented (M1) |
| `products` | `pulse` | Pulse meter (M1); standalone app and editor (M3) | headless CLAP meter implemented (M1) |
| `research` | - | Isolated execution research | destination only |

`adapters/clap`, `adapters/wasapi`, `products/pulse`, `products/pulse-mini`,
`products/reference` and `verification/` exist through Milestone 3;
`research/` and the Alicorn standalone/editor UI remain architectural
destinations recorded in [docs/architecture.md](docs/architecture.md).

## Documentation

- [Architecture](docs/architecture.md) — module map, dependency direction,
  architectural destinations, future-extraction table, state separation.
- [Determinism policy](docs/determinism.md) — FMA/FTZ policy, measurement
  conventions, tolerances, partition invariance.
- [Headless CLAP meter](docs/clap-plugin.md) — build, ABI proof, lifecycle,
  params/state schema, measurement export, RT evidence and limits.
- [Processing-checkpoint draft](docs/draft-processing-checkpoint.md) — the optional
  processing-checkpoint capability, separate from authoring state.
- [Pulse Mini](docs/pulse-mini.md) — standalone loopback capture, CLI, idle
  policy, self-loop measurements and tolerance rationale.
- [Telemetry draft](docs/draft-telemetry-extension.md) — canonical measurement
  records through the real plugin binary.
- [Milestone 1 validation](docs/benchmarks/clap-milestone1-validation-2026-11-22/README.md)
  — pinned clap-validator/clap-trap/clap-info results.
- [Verification](verification/README.md) — A‑1 laboratory map, run command,
  scenario/evidence formats, probe classes, independence rule and census.
- [Program research audit](docs/research/program-audit-2026-11-22.md) —
  ecosystem findings, reuse-vs-build decisions, risk register.

## Build and test

From the repository root:

```powershell
.\tools\check-boundary.ps1    # core/, third_party/, adapters/, products/, verification/ boundaries
.\tools\build.ps1             # odin check, out\pulse.clap, out\pulse-mini.exe, reference processors, worker
.\tools\test.ps1              # boundary gate + C ABI probes + every package's tests
.\tools\run_verification.ps1  # A-1 census: fresh workers, evidence under verification\reports\
```

After building, the standalone meter can be run directly:

```powershell
.\out\pulse-mini.exe --input=loopback --duration=5 --print-cadence=10
.\out\pulse-mini.exe --input=loopback --duration=2 --self-loop
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
- Milestone 2 (verification laboratory A‑1, #236): implemented
  (`verification/host`, `lab`, `worker`, scenarios, reference processors and a
  dated census). Evidence is local Windows x64; CI remains billing-blocked.
- Milestone 3 (standalone Mini meter + embedded CLAP editor, #131): M3.0 and
  M3.1 implemented. `core/meter` is the shared analysis engine, `adapters/wasapi`
  captures shared-mode loopback with explicit stall/recovery discontinuities,
  and `products/pulse-mini` is a functional console meter (self-loop verified).
  The Alicorn UI, hidden/idle work elision and the embedded editor are M3.2.

## License

zlib — matching Alicorn. Third-party notes in `NOTICE.md`.
