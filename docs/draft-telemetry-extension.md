# Draft: Carnival telemetry-capture CLAP extension

> **DRAFT — PRIVATE AND EXPERIMENTAL.** This is **not** a CLAP standard
> proposal. It is not submitted upstream, not offered as a compatibility
> promise to other vendors, and its identifier, UUIDs, vtable order and record
> schema may change until the verification laboratory stabilises them. An
> incompatible revision gets a new `/N` suffix on the extension id; it never
> silently redefines the existing draft.

Status: implemented for the Milestone 2 preparation. Declarations live in
`third_party/clap/abi/ext_carnival.odin`; the C mirror used by the ABI probes is
`third_party/clap/draft/carnival-telemetry-capture.h`; the plugin side is
`adapters/clap` + `products/pulse`.

## Why it exists

Pulse's canonical measurement records must be observable through the **real
plugin binary** by an independent host (the A−1 laboratory, Alicorn#236). A
CLAP parameter would expose this to every user and overstate its stability; a
private extension keeps the verification seam out of the public authoring
surface while still using the normal `plugin.get_extension` mechanism.

The extension is plugin-implemented and host-queried:

```c
const clap_carnival_telemetry_capture_t *ext =
    plugin->get_extension(plugin, CARNIVAL_EXT_TELEMETRY_CAPTURE_DRAFT);
```

## Identifiers

| Item | Value |
| --- | --- |
| Extension id | `com.carnival-science.telemetry-capture.draft/1` |
| Draft extension UUID | `33c18b91-bc23-4290-86a8-2d4035316ecc` |
| Measurement schema UUID | `fdecfe25-9b08-4163-ade3-baf7bcc2edab` |
| Measurement schema version | `1` (`CARNIVAL_MEASUREMENT_SCHEMA_VERSION`) |
| Channels per record | `2` |

The UUIDs are fixed draft identifiers used in evidence and logs; CLAP
extension lookup itself uses the string id. `schema_version()` and the
`schema_version` field in every record are the authority for the record layout.

## Vtable

| Function | Semantics |
| --- | --- |
| `capture_set_enabled(plugin, enabled) -> bool` | Enable or disable canonical capture. Off by default. **Requires quiescent processing:** the host must have stopped processing (`clap.stop_processing`) — while processing is active the call returns false and changes nothing. A successful call starts a fresh capture episode: pending records are discarded, the dropped counter is zeroed and capture validity is reset. |
| `capture_drain(plugin, sink, max_records) -> u32` | Deliver up to `max_records` pending records oldest-first through the host sink; `0` means "all pending". Returns the number delivered (stopped early if the sink returns false). |
| `capture_dropped(plugin) -> u64` | Records discarded because the bounded queue was full, since the most recent enable (current or most recent capture episode). Zero while capture is disabled or was never enabled. |
| `capture_valid(plugin) -> bool` | Capture-domain validity. True unless a record was dropped during the current episode. It never reflects lost audio samples. |
| `capture_schema_version(plugin) -> u32` | Measurement schema implemented by this build (`1`). |

`Carnival_Capture_Sink` is `{ ctx: rawptr, push: fn(ctx, ^record) -> bool }`,
passed **by value**. Returning false stops the drain without consuming that
record.

## Record schema (draft version 1)

The record is the canonical, sample-clock-aligned measurement export (one per
complete RMS window). `products/pulse` aliases this declaration as
`Measurement_Record`; verification may import the same declaration without
importing product code.

| Field | Meaning |
| --- | --- |
| `schema_version` | Draft schema version (`1`). |
| `epoch` | Analysis epoch; advances on reset so old/new records cannot mix. |
| `generation` | Per-epoch record sequence. |
| `start_frame` | Absolute sample frame of the window start. |
| `frames` | Window length in frames. |
| `channels` | Always 2. |
| `sample_rate` | Sample rate used for the window. |
| `peak[2]`, `peak_frame[2]` | Window peak amplitude and absolute peak frame per channel. |
| `rms[2]` | Window RMS per channel. |
| `hold[2]` | Peak-hold value per channel at window close. |
| `valid` | **Audio-domain** validity: false after lost/out-of-order audio samples. |
| `overrun` | Milestone 1 alias for audio-domain invalid. |
| `capture_valid` | **Capture-domain** validity at emission: false after a measurement record was lost. Never changes `valid`. |

The two validity domains are deliberately independent:

- lost **audio** samples invalidate the affected live analysis and records;
- lost **measurement records** invalidate the verification capture only;
- dropped **presentation frames** (snapshots) are harmless.

## Thread rules and ABI notes

- **Main thread only.** Every vtable function must be called from the host main
  thread, never the audio thread. When the host offers `clap.thread-check`,
  `adapters/clap` enforces this and returns a failure/zero otherwise. Without
  thread-check the rule is contractual and must be honoured by the host.
- **Synchronous callback.** `capture_drain` invokes the sink on the calling
  thread. The record pointer points into the plugin's bounded queue and is valid
  only for the duration of that call: do not retain it, and do not call back
  into the plugin from the sink (no re-entrancy). Copy the record if it must
  outlive the callback.
- **Zero-copy and the SPSC cursor.** The plugin advances its read cursor only
  after the sink accepts a record and does so one record at a time. The audio
  thread can therefore never overwrite the slot currently being read; it can
  only drop new records when the queue is full. This is a single-producer /
  single-consumer queue with the main thread as the only consumer.
- **Enable/disable boundary.** `capture_set_enabled` clears the queue, so it
  requires quiescent processing: the adapter refuses the call while
  `start_processing` is held, and the meter returns `Busy` without touching the
  episode if called while active. Stop processing first. Live capture
  switching while audio runs is deliberately not implemented; it needs a
  concurrent publication handshake and its own tests, and is recorded as
  remaining work.
- **Authoring state.** Capture mode is persisted in `clap.state` schema 3 bit 0.
  Loading a schema 1/2 state leaves capture off. This makes the verification
  mode survive a host save/load without exposing a public parameter. Loading a
  state that changes capture mode while processing is active does not switch
  the live episode; hosts load state while stopped.
- **Not a checkpoint.** Capture mode is authoring state. Processing
  checkpoints are a separate draft capability
  (`com.carnival-science.processing-checkpoint.draft/1`); see
  [draft-processing-checkpoint.md](draft-processing-checkpoint.md).
- **No allocation, no locks.** Drain is a bounded copy/iteration over
  preallocated storage. The real-time process path never calls the sink.

## C ABI proof

`tools/abi/abi_probe.c` prints C `sizeof`/`offsetof` for the record, sink and
vtable (and the UUIDs/extension id); `third_party/clap/abi/abi_test.odin`
compares every value with Odin. `tools/abi/cc_probe.c` is a C plugin that
implements the extension; `cc_test.odin` queries it through the Odin
declaration, enables capture, drains records through an Odin callback and
checks the forced-overflow counter. Both directions of the draft vtable are
therefore exercised by a real C compiler on the host OS.

## Tests in the product

- capture off, more windows than queue capacity: live analysis valid, zero
  records produced, no invalid latch;
- capture on, queue overflow: capture invalid + dropped counter, live analysis
  and audio validity unchanged, drain still returns the pre-loss records;
- extension drain over the real plugin binary equals the backend export
  field-for-field;
- extension enable/disable and schema version;
- capture mode round-trips through `clap.state` schema 3;
- C miniature plugin: `get_extension`, enable, drain with an Odin callback,
  dropped counter after forced overflow, disable.
