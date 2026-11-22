# carnival-audio architecture (Milestone 0 + M3)

`carnival-audio` is one repository with strict internal module boundaries. It
holds a source-independent Odin audio core and two edges: a standalone capture
meter and a native CLAP plugin. Alicorn supplies UI, rendering and
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
core/meter        source-independent meter engine: window/epoch analysis,
                  capture-domain records, snapshot publication (two consumers)
tests/            integration tests: partitions, WAV round-trip, memory ceiling
verification/     A−1 laboratory: independent CLAP host, worker, probes, scenarios, reports
third_party/clap  neutral CLAP 1.2.10 ABI declarations + vendored headers/C probes
                  + private draft Carnival telemetry and checkpoint extensions
third_party/miniaudio  vendored single-file miniaudio 0.11.26 (public domain)
adapters/clap     CLAP lifecycle/params/state adapter (M1; authoring schema 3)
adapters/wasapi   shared-mode WASAPI loopback capture (M3.1)
products/pulse    Pulse headless CLAP meter binding (M1/M3.0)
products/pulse-mini  standalone Mini meter (M3.1)
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
- `adapters/` may import `core/` and `third_party/clap`, and only
  `adapters/wasapi` may import `vendor:miniaudio` (the capture backend). It is
  never imported by `core/`.
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

## The three reusable foundations

1. **Sample and stream** (`core/stream`, `core/transport`) — the absolute frame
   clock, bounded block transport, discontinuity ledger and revisioned
   snapshots.
2. **Measurement primitives** (`core/dsp`) — sample peak, windowed RMS,
   peak hold, FFT, correlation.
3. **Meter engine** (`core/meter`) — window/epoch analysis, audio-domain
   validity, capture-domain records and queue, snapshot publication. It was
   extracted from `products/pulse` in M3.0 and has two genuine consumers from
   day one: the CLAP binding and the standalone capture meter.

The engine's intake contract is deliberately source-independent:

| Consumer | Entry point | Clock | Discontinuity |
| --- | --- | --- | --- |
| CLAP (`products/pulse`) | `engine_push_passthrough` with planar input/output | host `steady_time`; a forward jump is a source gap | recorded by the transport ring; new continuity segment |
| Capture (`products/pulse-mini`) | `engine_push_interleaved` | delivered frames (`steady_time < 0` advances by the block) | `engine_note_discontinuity` on stall/recovery; no fabricated silence |

Both accept variable-length blocks up to the activation maximum. Gaps never
complete a window: the RMS window restarts at the post-gap absolute frame.
`engine_note_discontinuity` also advances the analysis epoch; host steady-time
gaps keep the existing epoch so Census labels and records stay unchanged.

## Architectural destinations

These directories are destinations, not current structure. They are recorded
here instead of being created empty, because an empty directory would imply a
stability commitment the code has not earned.

| Milestone-0 content / future module | Destination |
| --- | --- |
| `core/stream` (stream/replay) | stays `core/stream`; later DAW engine foundations |
| `core/dsp` (peak/RMS, FFT, correlation) | stays `core/dsp`; later shared DSP library |
| `core/transport` (ring, snapshots) | stays `core/transport`; later DAW engine foundations |
| `core/meter` (analysis engine) | stays `core/meter`; shared analysis engine for CLAP and capture (two consumers already) |
| audio-verification content (A-1) | `verification/` |
| WASAPI capture (Milestone 3) | `adapters/wasapi` (implemented M3.1) |
| CLAP bindings and headless plugin (Milestone 1) | `adapters/clap` |
| Neutral CLAP ABI declarations (Milestone 1) | `third_party/clap` |
| standalone meter and embedded editor (Milestone 3) | `products/pulse-mini` (implemented M3.1); `products/pulse` UI/editor later |
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
Audio_Source (WAV replay, generated fixture, CLAP host, WASAPI loopback)
    -> bounded blocks on an explicit source clock (epoch, absolute frame)
    -> core/meter engine intake (planar passthrough or interleaved capture)
    -> preallocated transport ring
    -> pure analysis accumulators (no allocation, no I/O, no locks)
    -> Measurement_Snapshot (revisioned, copied by value)
    -> presentation (Alicorn UI, console, CLAP parameter/state export,
                    verification lab)
```

Analysis never reads from a device or a GUI directly, and presentation never
reads mutable analyser state. A dropped audio block produces an explicit
invalid/overrun state; it must not be displayed as a valid quiet reading.

### Capture intake (M3.1)

`adapters/wasapi` opens shared-mode loopback on the default render endpoint and
the data callback writes whole frames into a preallocated SPSC ring. A polling
session (`session_poll`) is the only consumer. Two facts about loopback drive
the design:

- **A silent endpoint delivers no callbacks.** The session does not fabricate
  silence and does not advance the source clock. After a documented idle
  threshold it reports one explicit stall/discontinuity; when data resumes it
  reports the broken timeline once. The consumer starts a new analysis epoch.
- **The endpoint can be switched or removed.** A `stopped`/`rerouted`
  notification marks the device lost; the session clears the ring, reopens,
  and reports recovery with a new epoch. A failed reopen stays explicitly
  unavailable and is retried, never shown as a valid quiet reading.

Shared-mode loopback is not bit-transparent: endpoint mixing, format conversion
and resampling are allowed. The contract is level accuracy, not bit equality;
the self-loop test documents the measured deviation (about +0.001% on the
development machine against a 1% tolerance).

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

### Milestone 3 remaining work (founder review ledger)

- **Spectrum end-to-end is not yet verified (F3).** The laboratory's
  `spectrum` probe validates its own naive O(n²) DFT against the *generated
  input*; it does **not** compare against spectral measurements emitted by
  Pulse, because Pulse currently exports no spectrum data. The full
  input→analysis→export comparison becomes possible when the Studio analyzer
  exposes spectrum data (M3.2). Until then, the probe is a reference check on
  the fixture, not an end-to-end spectral test.
- **Migration tests compare passthrough audio, not measurement records (F3).**
  The `state` fixtures currently render and compare `output.wav`; for a
  measurement product the stronger assertion is record equality after a
  migration. This needs a canonical-record comparison once a migrating
  specimen exposes telemetry (Pulse does; the fixture render path should be
  rewired to compare `records.csv`).
- **Live capture switching is future work.** Capture episodes require
  quiescent processing (F2). Switching capture while audio is running needs its
  own concurrent publication tests and a documented lock-free handshake; the
  current contract refuses the switch and says so.
- **Vendored miniaudio is a provenance copy, not a local build.** The linked
  implementation is the Odin distribution's build of the same 0.11.26 header;
  `third_party/miniaudio/UPSTREAM.md` records the exact hash. A self-contained
  C build step (MSVC/clang) is possible but not required by this milestone.
- **Loopback level evidence is machine-local.** The self-loop test measures
  about +0.001% peak/RMS deviation on the development machine against a 1%
  tolerance. Shared-mode loopback is not bit-transparent; other endpoints,
  sample-rate conversions and process mixes may differ.
- **pulse-mini is console-only.** The Alicorn UI, hidden/idle work elision and
  presentation profiling are M3.2. The engine is already snapshot-driven, so
  presentation cadence cannot change analysis results.

## State separation: four distinct contracts

1. **Authoring state** — versioned settings, stable identifiers, user
   preferences. Mandatory; reopens a project with the same configuration.
   Migratable, stored by the host or the standalone app (`clap.state` schema 3
   for Pulse and the reference processors). It does **not** promise that
   processing continues from the same sample.
2. **Processing checkpoint** — an **explicitly optional** capability that
   resumes computation at an exact sample position: filter history, delay
   lines, envelope timers. Exposed by the separate draft extension
   `com.carnival-science.processing-checkpoint.draft/1`; a host must query
   `supported()` first. A product may declare it unsupported without any
   authoring-state defect.
3. **Live processing state** — sample clocks, epoch, windows, accumulators,
   hold timers, overrun counters. Owned by the audio/analysis side; not a CLAP
   preset and not reconstructed from presentation state.
4. **Presentation state** — immutable revisioned snapshots and bounded
   visualisation history. Latest-wins; may be dropped or coalesced freely.

The first two were conflated in the Milestone 2 preparation by a schema-4
authoring blob that carried plugin-owned processing bytes. That blob was
removed: authoring state is parameters-only again, and processing state moved
to the checkpoint capability. The laboratory correspondingly tests authoring
round-trip and migration separately from checkpoint continuation.

Milestone 0 implements live processing state and the snapshot seam. Milestone 1
adds parameter authoring state (stable IDs, schema version 2, one v1→v2
migration) inside `adapters/clap`. Milestone 2 preparation adds schema 3 (one
product flag word for capture mode), separates audio-domain from capture-domain
validity, and introduces the telemetry draft. Milestone 3 adds the checkpoint
draft and the capture intake.

Per-product checkpoint support (recorded, not implied):

| Product | Authoring schema | Checkpoint | Why |
| --- | --- | --- | --- |
| Pulse (`products/pulse`) | 3 | **unsupported** | its window/hold/clock pipeline is tied to an absolute source position; a partial resume would be misleading, and a stateless declaration is the honest choice |
| Reference biquad | 3 | supported | eight f64 history words |
| Reference delay | 3 | supported | delay line plus write cursor |
| Reference leaky delay | 3 | claims supported, deliberately omits the line | negative fixture for the checkpoint capability; its authoring state passes |

Reference processors also use an optional `clap.tail` hook; Pulse still reports
a zero tail.

### Draft checkpoint extension

| Item | Value |
| --- | --- |
| Extension id | `com.carnival-science.processing-checkpoint.draft/1` |
| Draft UUID | `5c2f0a7e-4b1d-4c8e-9f3a-7d6e2b1c0a95` |
| Contract schema | `1` (`CARNIVAL_CHECKPOINT_SCHEMA_VERSION`) |
| Vtable | `supported`, `save`, `load`, `schema_version` |
| Thread | main thread only (enforced through `clap.thread-check` when offered) |

The payload is plugin-owned: the plugin writes a magic, its own payload
version and its fields through the normal CLAP streams, validates them before
committing, and may leave its previous state untouched on failure. The draft
frames nothing itself. See
[draft-processing-checkpoint.md](draft-processing-checkpoint.md).

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

## Milestone 3: standalone engine and capture

### M3.0 — meter engine extraction

`core/meter` now owns the analysis engine that used to live in
`products/pulse/meter.odin`: windowed peak/RMS/peak-hold, the absolute source
clock and continuity semantics, audio-domain validity, the capture-domain
record queue and snapshot publication. `products/pulse` is a thin binding:
adapter parameter mapping, authoring schema 3, wire-record conversion for the
telemetry extension, and lifecycle wiring.

Regression gate: rerunning the M2 census after the extraction produced the same
82 rows, the same classes and expectations, and the same Pulse `output.wav` /
`records.csv` hashes as before. The engine tests pin partition invariance, an
explicit discontinuity's epoch/window restart, the quiescent capture switch and
zero allocation on the push/drain path.

### M3.1 — WASAPI loopback and the Mini meter

`adapters/wasapi` implements shared-mode loopback capture with a bounded ring
and polling session (see the capture intake section above).
`products/pulse-mini` wires capture → ring → engine → console snapshots and is
built as `out/pulse-mini.exe`:

```
pulse-mini.exe --input=loopback [--duration=N] [--print-cadence=Hz]
               [--window=FRAMES] [--self-loop]
```

The self-loop verification renders a known 400 Hz / 0.5 sine while capturing
loopback, feeds the captured frames through the shared ring and engine, and
checks the presentation snapshot: peak 0.500004 versus 0.5 (+0.001%), RMS
0.353555 versus 1/(2√2) (+0.001%). The 1% tolerance is a level-accuracy
contract for a shared-mode path that may mix, convert and resample; it is not a
bit-equality claim. Device loss/recovery and idle stalls are covered by the
fake-backend tests.

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
