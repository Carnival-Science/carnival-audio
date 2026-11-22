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
core/transport    bounded SPSC block ring, source-clock continuity, snapshots
tests/            integration tests: partitions, WAV round-trip, memory ceiling
verification/     A−1 verification laboratory; core record formats + neutral CLAP ABI, no implementation yet
third_party/clap  neutral CLAP ABI declarations (Milestone 1; no declarations yet)
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

adapters/ ─┐
products/ ─┼─────> third_party/clap (ABI declarations only)
verification/ ┘
research/         isolated; no product or adapter imports
```

- `core/` imports only Odin `core:` packages and its sibling core packages. It
  must never import `alicorn`, SDL3, miniaudio, WASAPI/ALSA/CoreAudio, CLAP,
  `third_party/`, `adapters/`, `products/` or `verification/`.
- `adapters/` may import `core/` and `third_party/clap`. It is never imported by
  `core/`.
- `products/` may import `adapters/`, `core/` and `third_party/clap`;
  `products/pulse` is the only place that imports Alicorn.
- `verification/` depends on core **record formats** only. It must never import
  `core/dsp`, `adapters/` or `products/`: its numerical references have to be
  independent of the implementation under test, and the import boundary makes
  that structural. Today the canonical record declaration is
  `Measurement_Snapshot` inside `core/transport`; before A−1 consumes it,
  extract that declaration into a small core records package so verification
  links the format without the ring implementation.
- `verification/` **may** import `third_party/clap`: verification is an
  independent host, so it needs the protocol declaration. Sharing an ABI
  declaration is not sharing the implementation; sharing the DSP that computes
  expected results is what the boundary forbids. `verification/` still must not
  import `adapters/clap` or any plugin implementation. Concretely,
  `core/stream` and `core/transport` record-format declarations remain allowed
  (that is the existing policy), while `core/dsp` stays blocked.
- `third_party/` is neutral protocol/ABI surface. It may import Odin `core:`
  packages and its own subpackages only; it must never import `core/`,
  `adapters/`, `products/`, `verification/`, Alicorn or platform audio/UI
  libraries. `third_party/clap` is the future open-source extraction candidate,
  but is extracted only after **both** a real plugin (`adapters/clap`) and an
  independent host (`verification/`) exercise it.
- `research/` is isolated execution research and imports neither products nor
  adapters.

`tools/check-boundary.ps1` enforces the `core/`, `verification/` and
`third_party/` import boundaries. Tests import core packages directly.

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
| Neutral CLAP ABI declarations (Milestone 1) | `third_party/clap` |
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
| CLAP ABI (`third_party/clap`, future) | standalone open-source ABI package, only after both a real plugin and an independent host use it |
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

### Transport continuity

The transport ring keeps the source's absolute frame clock separate from queue
storage. A forward jump in the source clock records an explicit
`transport.Discontinuity` (absolute lost range, stream epoch and continuity
segment) and advances the clock; a backward or resubmitted range is rejected as
a duplicate rather than accepted twice. Each data block and gap record carries
the continuity segment, so analysis that assembles a window across blocks must
invalidate it when the segment changes or a ledger range overlaps it. There is
no implicit gap accounting: recovery requires a reset or an explicit
higher-layer account of the lost frames. Overrun and ledger-overflow are sticky
latches. Variable-length host blocks are stored in slots preallocated at
`max_block_frames`; push/read never allocate.

## Remaining work (Milestone 0 review ledger)

The founder's Milestone 0 source review recorded these as remaining work, not
as solved guarantees:

- **Streaming / bounded-window WAV decode (#123).** `wav_decode` materializes
  the complete decoded f32 buffer, and `wav_load_file` reads the entire file, so
  memory is O(file duration) in both input and output. Issue #123's
  memory-independence requirement for long-file replay is **not yet solved**; a
  bounded-window/streaming decoder is remaining work.
- **Cross-platform reproducibility unproven.** Determinism evidence comes from
  Windows x86-64 with the pinned Odin nightly. There is no CI or golden evidence
  for Linux, macOS, ARM or another compiler build, so floating-point and
  toolchain variance across platforms is not established.
- **Snapshot record extraction.** Move `Measurement_Snapshot` into a small core
  records package before verification consumes it, so verification links the
  format without the transport ring implementation.
- **CLAP ABI declarations.** `third_party/clap` is a neutral, empty scope until
  Milestone 1 adds declarations generated from the official headers. Extraction
  is deferred until both a real plugin and an independent host use it.

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
