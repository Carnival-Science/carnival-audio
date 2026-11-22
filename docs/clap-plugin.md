# Headless CLAP meter (Milestone 1 / Alicorn #237)

`products/pulse` builds a Windows x64 CLAP 1.2 plugin. It is a stereo insert
effect that passes audio through bit-for-bit and derives sample peak, windowed
RMS and peak-hold measurements from the same stream. There is no GUI, no
Alicorn dependency and no platform audio backend in this target.

## Artifact and commands

```powershell
.\tools\build.ps1     # compile-check packages, then write out\pulse.clap
.\tools\test.ps1      # boundary gate, C ABI probes, every package's tests
```

Windows CLAP binaries are a single DLL whose file name ends in `.clap`; the
file lives at the bundle root and exports `clap_entry` (`dumpbin /exports
out\pulse.clap`). The Linux `.so` and macOS bundle paths are kept portable but
are not released in this milestone. `products/pulse/plugin.odin` compiles the
entry point only with `-define:PULSE_PLUGIN_BUILD=true`; the DLL build uses
that define.

The plugin ID is `com.carnival-science.pulse.meter` (version `0.1.0`).

## Layers

| Layer | Role |
| --- | --- |
| `third_party/clap/abi` | Hand-written Odin declarations for CLAP 1.2.10 core + audio-ports/params/state/latency/thread-check/tail/render, plus the private draft Carnival telemetry-capture extension and its record schema |
| `adapters/clap` | Lifecycle, factory, thread-state checks, parameter atomics/events, extension tables (including the draft telemetry vtable), versioned authoring state |
| `products/pulse` | Meter backend, transport-ring analysis, canonical measurement capture, snapshot, product descriptor/params |

`core/` never imports CLAP. The adapter does not import a product; the product
registers its `Definition` with the adapter from the exported entry point.

## Audio contract

- Stereo in / stereo out, interleaved-or-planar f32 as supplied by CLAP.
- 32-bit audio only; 64-bit buffers and any count other than one input and one
  output are rejected with `CLAP_PROCESS_ERROR`.
- Input is copied to output sample-for-sample, including in-place buffers
  (when both channel pointers alias input and output) and non-in-place buffers.
  No gain, dither, denormal flush or sample-format conversion is applied.
- No intentional latency; the `clap.latency` extension reports 0 and
  `clap.tail` reports 0.
- The plugin advertises one stereo input and one stereo output, both main
  ports, with in-place pairs assigned.

A subnormal sample is therefore preserved. This is deliberate and conflicts
with clap-validator's fuzz policy, which treats a subnormal in the output as a
failure; see the validation evidence for the recorded gap.

## Parameters and authoring state

Stable IDs (never renumber):

| ID | Name | Range | Default | Format |
| --- | --- | --- | --- | --- |
| 1001 | Window Frames | 128..8192, stepped | 1024 | integer |
| 1002 | Hold Frames | 0..96000, stepped | 4800 | integer |
| 1003 | Hold Decay | 0..1, stepped | 1 | On/Off |
| 1004 | Hold Decay Rate | 0..120 dB/s | 20 | one decimal dB |

State format (native little-endian):

```
" CSPULSE1"          8 bytes magic
schema              u32 (current 3)
param_count         u32
record[param_count] { id: u32, value: f64 }
flags               u32 (schema 3+; bit 0 = capture mode enabled)
```

Schema 1 stored 1001..1003. Schema 2 adds 1004; loading a v1 fixture leaves
1004 at its descriptor default. Schema 3 appends the product flag word; loading
a v1/v2 file leaves the flags at zero, so telemetry capture is off. The
migration is covered by hand-written fixtures in `products/pulse/meter_test.odin`.
Unknown IDs in a newer file are ignored; a bad magic, unsupported schema or
truncated stream fails the load. The load commits only after the whole stream
is parsed and then asks the host to rescan parameter values.

Only authoring state is serialized. Sample clock, epoch, windows, accumulators,
hold timers, overrun latches and the canonical records are processing state and
never appear in `clap.state`. The capture-mode flag is the one non-parameter
authoring bit: it records whether the verification capture was enabled.

## Processing and invalidation

1. The adapter validates the host process struct and copies parameter atomics
   into a bounded stack array. Automation events are applied at block start
   (the meter's settings are control-rate); the audio path never splits a block
   because of a parameter event.
2. `products/pulse` copies input to output and builds an interleaved staging
   buffer (`max_frames * 2`, preallocated at activation).
3. The block is pushed into a bounded SPSC transport ring with its absolute
   start frame. The ring records gaps/overruns in its discontinuity ledger.
4. The same callback drains the ring (unless a test disables draining) and
   feeds `core/dsp` peak, RMS-window and peak-hold accumulators.
5. Each complete RMS window updates live analysis. If capture is enabled, one
   `Measurement_Record` is appended to a preallocated SPSC queue. The latest
   `Measurement_Snapshot` is published through the existing seqlock regardless.

Validity is split into two independent domains:

- **Audio domain.** A source gap, ring overrun or ledger overflow latches
  `audio_invalid`. Snapshots then carry `valid = false` / `overrun = true` and
  emitted records carry `valid = false` until an explicit reset. Passthrough
  continues. No dropped sample is ever silently treated as a valid quiet
  interval.
- **Capture domain.** Complete measurement capture is an explicitly enabled
  verification mode, off by default. When it is off, records are **not
  produced** (the cheapest correct behaviour), so the 4096-record queue is not a
  lifecycle hazard and an ordinary session cannot saturate it. When capture is
  on and the queue is full, the record is dropped, the dropped counter grows and
  `capture_valid` becomes false. Live analysis, snapshots and the audio-domain
  validity are **not** affected. Draining does not repair capture validity; a
  new `capture_set_enabled` episode does.

Dropped presentation frames (snapshots) are harmless: snapshots are
latest-wins and never feed the canonical queue.

### Canonical export

`meter_measurement_drain(meter, destination)` copies pending records oldest
first; loop it for a complete drain at a quiescent boundary.
`meter_measurement_drain_sink(meter, sink, max_records)` is the zero-copy form
used by the telemetry extension: the callback receives a pointer into the queue
that is valid only for the call. Records are keyed by `epoch`, `start_frame` and
`frames`, carry per-channel peak/peak frame, RMS, hold, the record schema
version and both validity flags. Reading the presentation snapshot does not
touch the record queue, so UI cadence cannot change canonical results. Forced
queue saturation is observable via `meter_measurement_dropped`; capture-domain
validity via `meter_capture_valid`.

An independent host reaches the same queue through the draft Carnival telemetry
extension; see
[docs/draft-telemetry-extension.md](draft-telemetry-extension.md). It is a
private experimental draft, not a CLAP standard proposal.

The tests process the same 10,000-frame stream at 64/128/256/512/997-frame
partitions and at two drain cadences, and require bit-identical records. They
also compare sine/impulse/silence/noise measurements with closed-form literals at
44.1/48/96 kHz and 64/128/512/irregular partitions. Capture-off saturation,
capture-on overflow and extension-versus-backend record equality have their own
tests.

## Real-time safety evidence

The process callback performs no allocation, locking, I/O or rendering work
after activation. Evidence:

- `adapters/clap` test installs a counting allocator as both
  `context.allocator` and `context.temp_allocator` for the process callback and
  asserts zero allocations across 32 process calls.
- `products/pulse` repeats the probe through the full adapter + meter path
  (64 calls of 512 frames) and asserts zero allocations.
- Ring, staging, drain buffer and measurement queue storage are all allocated in
  `activate`/`create`; destroy frees them on the main thread.
- The process path has bounded loops only: `frames`, `channels`, parameter
  count, host event count and ring depth. Host events outside core
  parameter-value type are ignored.

This is observed evidence for this build and these paths, not a universal
real-time guarantee. Denormal/FTZ state is not changed by the plugin.

## External validation

See
[docs/benchmarks/clap-milestone1-validation-2026-11-22/](benchmarks/clap-milestone1-validation-2026-11-22/README.md)
for pinned tool hashes, commands, clap-validator results, the clap-info JSON
dump and the recorded fuzz gap.

## Known limits

- Windows x64 only for release; Linux/macOS are compile+test gates.
- Odin DLL builds are not byte-reproducible today (PE timestamps); the evidence
  hash names the exact validated artifact, not a reproducible build. The
  Milestone 1 artifact is preserved under
  `docs/benchmarks/clap-milestone1-validation-2026-11-22/artifacts/`.
- Stereo only; no 64-bit audio, note ports, GUI, audio-ports-config or
  multi-instance sharing of allocation (each instance owns its buffers).
- Cross-platform bit-identical measurement records are not established.
- `state_load` treats a missing parameter as its default (the v1 migration
  rule); it does not preserve a parameter that a corrupt file omits.
- The Carnival telemetry-capture extension and its record schema are a
  **private experimental draft**, not a public standard; both may change.
