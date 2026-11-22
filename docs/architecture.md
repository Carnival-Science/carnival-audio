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
verification/     A−1 laboratory: independent CLAP host, worker, probes, scenarios, reports
third_party/clap  neutral CLAP 1.2.10 ABI declarations + vendored headers/C probes
                  + private draft Carnival telemetry-capture extension
adapters/clap     CLAP lifecycle/params/state adapter (M1; state schema 4 + tail hooks)
adapters/         future adapters/wasapi capture (M3)
products/pulse    Pulse headless CLAP meter (M1); standalone app/editor later
products/reference/  gain, biquad, delay + defective test-the-tester processors (M2)
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
  that structural. The A−1 laboratory reads the canonical measurement record
  through the draft telemetry extension declared in `third_party/clap`, and it
  computes expectations with verification-local peak/RMS/DFT code. The
  `Measurement_Snapshot` presentation record remains in `core/transport`; it is
  not the verification wire format.
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
- **Cross-platform reproducibility unproven (CI added, evidence still
  Windows-only).** `.github/workflows/ci.yml` now compiles and tests on Windows,
  Ubuntu and macOS with Odin `dev-2026-11a`, but CI gates compile+test pass; it
  does not compare measurement records across OS/CPU/libm. Determinism evidence
  remains Windows x86-64, so floating-point/toolchain variance is not
  established and cross-OS goldens are still remaining work.
- **Snapshot record extraction.** Move `Measurement_Snapshot` into a small core
  records package before verification consumes it, so verification links the
  format without the transport ring implementation.
- **CLAP ABI declarations (done for M1).** `third_party/clap` now pins CLAP
  1.2.10 headers and Odin declarations, with independent C size/offsetof and
  calling-convention probes. The package remains in-repo: extraction is deferred
  until both a real plugin (`adapters/clap`, done) and an independent host
  (`verification/`, not done) exercise it.
- **CLAP fuzz denormal policy gap.** clap-validator's fuzzer rejects subnormal
  output; bit-exact passthrough intentionally preserves subnormal input. This is
  recorded in
  `docs/benchmarks/clap-milestone1-validation-2026-11-22/README.md` rather than
  hidden by flushing samples.
- **Reproducible plugin artifacts unproven.** Consecutive Odin DLL builds of the
  same source produce different PE bytes (timestamps). Evidence records the
  SHA-256 of the exact validated artifact; bit-reproducible builds are remaining
  work.

## State separation

Three kinds of state are deliberately distinct:

1. **Authoring state** — versioned settings, stable identifiers, user
   preferences. Migratable; stored by the host or the standalone app.
2. **Processing state** — sample clocks, epoch, windows, accumulators, hold
   timers, overrun counters. Owned by the audio/analysis side; not a CLAP
   preset and not reconstructed from presentation state.
3. **Presentation state** — immutable revisioned snapshots and bounded
   visualisation history. Latest-wins; may be dropped or coalesced freely.

Milestone 0 implements processing state and the snapshot seam. Milestone 1 adds
parameter authoring state (stable IDs, schema version 2, one v1→v2 migration)
inside `adapters/clap`, while `products/pulse` keeps clocks, windows,
accumulators, holds, validity latches and canonical records in processing state.
Milestone 2 preparation adds schema 3 (one product flag word for capture mode)
and separates audio-domain from capture-domain validity.

Milestone 2 adds an optional schema-4 processing-state blob to the generic
adapter for processors whose output must continue from saved state (the
reference biquad history and feedback-delay line). The blob is plugin-owned
bytes framed by a length; it is not a general DSP-state promise, and schemas
1–3 load with a fresh processing state. Reference processors also use an
optional `clap.tail` hook; Pulse still reports a zero tail and does not
serialize processing state.

## Milestone 2 preparation

The M1 review found two issues, fixed without changing the audio contract:

- **The measurement queue is no longer a lifecycle hazard.** Complete
  measurement capture is an explicitly enabled verification mode (off by
  default, toggled through the draft telemetry extension and recorded in
  authoring-state schema 3). With capture off, records are not produced at all.
  With capture on, queue overflow drops records and invalidates the **capture**
  domain only; live analysis, snapshots and audio-domain validity are untouched.
  Lost audio samples still invalidate the live analysis.
- **A private draft CLAP extension exposes the canonical records.** The
  `com.carnival-science.telemetry-capture.draft/1` extension (declared in
  `third_party/clap`, implemented in `adapters/clap` + `products/pulse`) lets an
  independent host enable capture, drain records through a synchronous callback,
  and read the dropped counter, capture validity and schema version over the
  real plugin binary. It is experimental and not a standard proposal; see
  [draft-telemetry-extension.md](draft-telemetry-extension.md).

The exact Milestone 1 validated plugin binary is preserved under
`docs/benchmarks/clap-milestone1-validation-2026-11-22/artifacts/` because Odin
DLL builds are not byte-reproducible.

## Milestone 2 verification laboratory

`verification/` is the A−1 behavioral laboratory (Alicorn#236). It is
separate from the products in both directions:

- `verification/host` loads `.clap` shared libraries through `core:dynlib` and
  speaks the neutral `third_party/clap` ABI. It does not import `adapters/clap`
  or any product.
- `verification/lab` owns the deterministic scenario/evidence schemas, the
  independent numerical references (seeded generator, peak/RMS, naive O(n²)
  DFT), the WAV writer, hashing, the numeric-environment fingerprint and the
  probes.
- `verification/worker` is one fresh process per run: scenario in, evidence
  JSON/CSV/WAV out. Exit 0 = all probes pass, 1 = specimen probe failure,
  2 = laboratory failure. The runner preserves failure stderr/stdout and
  partial artifacts.
- `tools/run_verification.ps1` builds the products, reference processors and
  worker, spawns workers under a watchdog, checks declarations of expected
  specimen failures/classes, compares cross-process artifact hashes, and writes
  a dated `verification/reports/` census, manifest and report.

Probe classes are kept distinct: static partition invariance is strict; the
automation probe labels `automation_partition_sensitive_control_rate` for the
adapter's documented block-start application, and can observe
`automation_partition_invariant_observed` for a plugin that applies events at
sample offsets (the third-party census specimen does). Tail and perturbation
probes report measured windows and explicit applicability instead of inferring
convergence.

The census includes Pulse, three good reference processors
(`products/reference/gain`, `biquad`, `delay`), three deliberately defective
fixtures (block-boundary smoother, leaky delay, NaN trigger), and one small
pinned MIT third-party CLAP binary with provenance. See
`verification/README.md` and `verification/reports/`.

## Milestone 0 scope

Pure Odin, headless, deterministic. No SDL, no CLAP, no miniaudio, no Alicorn.
The core API did not change shape to accommodate the host.

## Milestone 1 scope

`third_party/clap/abi` declares CLAP 1.2.10 and is proven against the official
C headers by independent sizeof/offsetof and calling-convention probes.
`adapters/clap` implements the protocol lifecycle, parameter atomics/events and
authoring state. `products/pulse` implements the headless Windows `.clap`
meter backend: bit-exact stereo passthrough, explicit invalid state on
ring/queue loss, canonical record export and a presentation snapshot. Details,
commands and evidence are in `docs/clap-plugin.md` and
`docs/benchmarks/clap-milestone1-validation-2026-11-22/`.
