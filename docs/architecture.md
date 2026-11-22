# Pulse architecture (Milestone 0)

Pulse is a source-independent Odin audio analysis core with two later edges: a
standalone desktop meter and a native CLAP plugin. Alicorn supplies UI,
rendering and accessibility at the standalone/editor edge only.

## Module map

```
core/audio       stream descriptor, sample clock, WAV replay, generated signals
core/analysis    sample peak, windowed RMS, peak hold, FFT, stereo correlation
core/transport   bounded SPSC block ring, revisioned measurement snapshots
tests/           integration tests: partitions, WAV round-trip, memory ceiling
tools/           build, test and boundary-check harness
clap/            (Milestone 1) CLAP foreign declarations and headless plugin
standalone/      (Milestone 3) desktop application; only Alicorn importer
verification/    canonical measurement-record formats (no hosting logic)
```

`core/` imports only Odin `core:` packages. It must never import `alicorn`,
SDL3, miniaudio, CLAP or a platform audio/graphics library.
`tools/check-boundary.ps1` enforces the import boundary.

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
this core; the core API must not change shape to accommodate the host.
