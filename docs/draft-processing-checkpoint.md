# Draft: Carnival processing-checkpoint CLAP extension

> **DRAFT — PRIVATE AND EXPERIMENTAL.** This is **not** a CLAP standard
> proposal. It is not submitted upstream, not offered as a compatibility
> promise to other vendors, and its identifier, UUIDs, vtable order and
> contract may change until the laboratory stabilises them. An incompatible
> revision gets a new `/N` suffix on the extension id; it never silently
> redefines the existing draft.

Status: implemented in Milestone 3. Declarations live in
`third_party/clap/abi/ext_carnival.odin`; the C mirror is
`third_party/clap/draft/carnival-telemetry-capture.h`; the adapter side is
`adapters/clap`; the product side is `products/reference/{biquad,delay}` and the
negative fixture `products/reference/leaky_delay`.

## Why it is separate from `clap.state`

Two contracts are routinely conflated:

- **Authoring state** (`clap.state`) reopens a project with the same settings.
  It is mandatory and migratable. It does **not** promise that computation
  continues at the same sample position. A delay whose authoring state stores
  only parameters is not defective.
- **Processing checkpoint** resumes computation at an exact sample position:
  filter history, delay-line contents, envelope timers. It is optional. A host
  must ask `supported()` before using it, and a plugin may decline.

Milestone 2 preparation put a plugin-owned processing blob inside authoring
state schema 4. That made a missing delay line look like a broken preset and
gave hosts no way to distinguish "cannot checkpoint" from "checkpoint is
wrong". The blob was removed; schema 4 authoring files are rejected, and
processing state now uses this extension. A host that wants to resume a session
loads `clap.state` first (settings) and, only if `supported()` is true, loads a
checkpoint.

## Identifiers

| Item | Value |
| --- | --- |
| Extension id | `com.carnival-science.processing-checkpoint.draft/1` |
| Draft extension UUID | `5c2f0a7e-4b1d-4c8e-9f3a-7d6e2b1c0a95` |
| Contract schema | `1` (`CARNIVAL_CHECKPOINT_SCHEMA_VERSION`) |
| Payload | plugin-owned bytes through `clap.ostream`/`clap.istream` |

The UUID is a fixed draft identifier used in evidence and logs; CLAP extension
lookup uses the string id. The contract schema versions the vtable semantics.
The payload carries the plugin's own magic and payload version: this draft
frames nothing.

## Vtable

| Function | Semantics |
| --- | --- |
| `supported(plugin) -> bool` | True only when save/load can snapshot and restore processing state at an exact sample position. False means "do not probe further"; it is not a defect. |
| `save(plugin, ostream) -> bool` | Write the complete checkpoint. Return false on failure; the host then has no checkpoint. |
| `load(plugin, istream) -> bool` | Validate the plugin's magic/version/length, then commit. On false the previous processing state is kept (all-or-nothing). |
| `schema_version(plugin) -> u32` | Contract schema implemented by this build (`1`). |

`save` must write enough to continue the exact output; the payload is bounded by
the plugin's own maximum state (a delay line is bounded by its maximum delay).
A plugin that cannot snapshot cheaply declares `supported() == false`.

## Thread rules

- **Main thread only.** The adapter enforces this through `clap.thread-check`
  when the host offers it; without it the rule is contractual.
- No allocation is required by the host side; the plugin may allocate in
  `save`/`load` (they are not audio-thread calls). A plugin that wants a
  real-time-safe checkpoint should preallocate its payload buffer.
- `load` does not need quiescent processing in this draft, but a host should
  stop processing first: a checkpoint restore changes live analysis state.

## Product decisions (recorded)

| Product | Supported | Payload |
| --- | --- | --- |
| Pulse | **no** | Pulse's live state (RMS window partials, hold timers, absolute clock) is tied to the source timeline; declaring no checkpoint is more honest than a partial resume |
| Reference biquad | yes | magic `CSBQCK01`, version 1, 8 × f64 history words |
| Reference delay | yes | magic `CSDLCK01`, version 1, write cursor + both delay lines (f32 bit patterns) |
| Reference leaky delay | claims yes, saves the cursor only | deliberate negative fixture: the laboratory's checkpoint probe must fail it while its authoring state passes |

## Laboratory mapping

The A-1 laboratory now has two probes:

- `state` (`authoring_state_and_migration`) saves/loads parameters and
  migrates historical fixtures. Render equality after a restore is **not**
  required; for stateful processors it would be the wrong question.
- `checkpoint` (`processing_checkpoint_restore`) skips unless
  `supported()` is true, then renders a prefix, saves, restores into a fresh
  instance, renders the suffix and requires byte equality with the
  uninterrupted suffix.

Census consequences: `leaky_delay` reports `state = pass` and
`checkpoint = fail`; biquad and delay report both `pass`; Pulse reports
`checkpoint = skip` ("no processing-checkpoint support").

## C ABI proof

`tools/abi/abi_probe.c` prints the C `sizeof`/`offsetof` for the vtable and its
functions plus the id and UUID; `third_party/clap/abi/abi_test.odin` compares
every fact with Odin. The adapter tests exercise `supported`, save/load
forwarding, payload validation and refusal without hooks.

## Tests

- adapter: capability query, round trip, unsupported refusal, incomplete hooks
  rejected at factory creation, checkpoint bytes absent from `clap.state`;
- reference products: laboratory checkpoint pass (biquad, delay);
- negative fixture: laboratory checkpoint fail with an authoring-state pass;
- ABI: C/Odin vtable layout and id agreement.
