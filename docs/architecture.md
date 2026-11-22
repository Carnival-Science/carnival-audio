# carnival-audio architecture (Milestone 0)

`carnival-audio` is one repository with strict internal module boundaries. It
holds a source-independent Odin audio core and two later edges: a standalone
desktop meter and a native CLAP plugin. Alicorn supplies UI, rendering and
accessibility at the standalone/editor edge only; it stays a separate
repository.

The repository is deliberately **not** split into independently versioned
libraries yet. The abstractions are allowed to settle against real plugins
first; extraction follows the criteria and table below.

## Module map

```
core/stream       stream descriptor, sample clock, WAV replay, generated signals
core/dsp          sample peak, windowed RMS, peak hold, FFT, stereo correlation
core/transport    bounded SPSC block ring, revisioned measurement snapshots
tests/            integration tests: partitions, WAV round-trip, memory ceiling
verification/     A−1 verification laboratory; record formats only, no implementation yet
tools/            build, test and boundary-check harness
adapters/         (not created) adapters/clap for M1, adapters/wasapi for M3
products/         (not created) products/pulse for the standalone app
research/         (not created) isolated execution research
```

## Dependency direction

Imports point only toward the core:

```
products/ ──────> adapters/ ──────> core/
                                      ^
verification/ ── record formats only ─┘
research/         isolated; no product or adapter imports
```

- `core/` imports only Odin `core:` packages and its sibling core packages. It
  must never import `alicorn`, SDL3, miniaudio, WASAPI/ALSA/CoreAudio, CLAP,
  `adapters/`, `products/` or `verification/`.
- `adapters/` may import `core/`. It is never imported by `core/`.
- `products/` may import `adapters/` and `core/`; `products/pulse` is the only
  place that imports Alicorn.
- `verification/` depends on core **record formats** only. It must never import
  `core/dsp`, `adapters/` or `products/`: its numerical references have to be
  independent of the implementation under test, and the import boundary makes
  that structural. Today the canonical record declaration is
  `Measurement_Snapshot` inside `core/transport`; before A−1 consumes it,
  extract that declaration into a small core records package so verification
  links the format without the ring implementation.
- `research/` is isolated execution research and imports neither products nor
  adapters.

`tools/check-boundary.ps1` enforces the `core/` and `verification/` import
boundaries. Tests import core packages directly.

## Architectural destinations

These directories are destinations, not current structure. They are recorded
here instead of being created empty, because an empty directory would imply a
stability commitment the code has not earned.

| Milestone-0 content / future module | Destination |
| --- | --- |
| `core/stream` (stream/replay) | stays `core/stream`; later DAW engine foundations |
| `core/dsp` (peak/RMS, FFT, correlation) | stays `core/dsp`; later shared DSP library |
| `core/transport` (ring, snapshots) | stays `core/transport`; later DAW engine foundations |
| audio-verification content (A−1) | `verification/` |
| WASAPI capture (Milestone 3) | `adapters/wasapi` |
| CLAP bindings and headless plugin (Milestone 1) | `adapters/clap` |
| standalone meter and embedded editor (Milestone 3) | `products/pulse` |
| semantic state (future) | shared plugin/project serialization, then `products/` / `adapters/` consumers |
| render capsules (future) | reproducibility / incremental rendering |

## Future-extraction table

Extraction into an independently versioned library or repository is allowed
only with **at least two genuine consumers**, a **reasonably stable interface**,
**independent tests**, and a **concrete reason for its own release cycle**.

| Module | Future destination |
| --- | --- |
| DSP primitives (`core/dsp`) | shared DSP library |
| Stream and transport (`core/stream`, `core/transport`) | DAW engine foundations |
| Semantic state (future) | shared plugin/project serialization |
| CLAP adapter (`adapters/clap`, future) | reusable plugin-authoring infrastructure |
| Verification (`verification/`) | independent developer-facing product |
| Render capsules (future) | reproducibility / incremental rendering |
| Pulse (`products/pulse`, future) | standalone product |

## Data flow

```
Audio_Source (WAV replay, generated fixture, later capture/plugin)
    -> bounded Audio_Block stream on an absolute sample clock (epoch, frame)
    -> preallocated transport ring
    -> pure analysis accumulators (no allocation, no I/O, no locks)
    -> Measurement_Snapshot (revisioned, copied by value)
    -> presentation (Alicorn UI, CLAP parameter/state export, verification lab)
```

Analysis never reads from a device or a GUI directly, and presentation never
reads mutable analyser state. A dropped audio block produces an explicit
invalid/overrun state; it must not be displayed as a valid quiet reading.

## State separation

Three kinds of state are deliberately distinct:

1. **Authoring state** — versioned settings, stable identifiers, user
   preferences. Migratable; stored by the host or the standalone app.
2. **Processing state** — sample clocks, epoch, windows, accumulators, hold
   timers, overrun counters. Owned by the audio/analysis side; not a CLAP
   preset and not reconstructed from presentation state.
3. **Presentation state** — immutable revisioned snapshots and bounded
   visualisation history. Latest-wins; may be dropped or coalesced freely.

Milestone 0 implements processing state and the snapshot seam. It deliberately
contains no authoring state yet.

## Milestone 0 scope

Pure Odin, headless, deterministic. No SDL, no CLAP, no miniaudio, no Alicorn.
The next milestone (#237) adds CLAP declarations and a headless plugin around
this core in `adapters/clap`; the core API must not change shape to accommodate
the host.
