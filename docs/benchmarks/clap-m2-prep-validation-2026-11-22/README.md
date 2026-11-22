# Milestone 2 preparation revalidation (2026-11-22)

Revalidation of the Pulse meter after the two founder findings from the
Milestone 1 review:

1. measurement-queue overflow no longer invalidates live analysis (capture is an
   explicitly enabled verification mode);
2. the private draft Carnival telemetry-capture extension exposes the canonical
   records through the real plugin binary.

Milestone 1 evidence is untouched in
[`../clap-milestone1-validation-2026-11-22/`](../clap-milestone1-validation-2026-11-22/README.md);
the exact M1 artifact is preserved there under `artifacts/`.

Host: Windows 11 x64 (10.0.19045), MSVC 19.51.36248.0, CMake 4.4.4,
rustc/cargo 1.98.1, Odin dev-2026-11-nightly:08539cd.

## Artifact

| Item | Value |
| --- | --- |
| Built path | `out/pulse.clap` |
| Preserved copy | [`artifacts/pulse-meter-m2-prep.clap`](artifacts/pulse-meter-m2-prep.clap) |
| Plugin ID | `com.carnival-science.pulse.meter` |
| Size | 613,376 bytes |
| SHA-256 | `0fa1e272ec8b4f86fc1fbb0a431e8a19da2239506f7b09dbc0dbfea578f4fe81` |
| Source revision | `95084f8` (`feat(pulse): split audio-domain and capture-domain validity; explicit capture mode`), clean working tree at build time |

Build command:

```powershell
C:\odin\odin.exe build products/pulse -collection:carnival=C:\Users\saman\dev\pulse `
  -build-mode:dll -define:PULSE_PLUGIN_BUILD=true -out:out\pulse.clap -o:minimal
```

Odin DLL builds remain **not byte-reproducible** (PE timestamps). The hash names
this exact artifact; the preserved copy is the historical evidence. The M2-prep
artifact is committed for the same reason as the M1 one: later migration
research compares behaviour against exact binaries, not rebuild recipes.

## Tool versions (unchanged from M1)

Tools are external, cloned to `%TEMP%\pulse-tools`, never vendored.

| Tool | Commit | Binary SHA-256 |
| --- | --- | --- |
| clap-validator 0.4.1 | `7596871984e669823a90a71ff5823131a978df57` | `aeaae2a63b6e146eb841fbbbd47c68c27be837acb72821982ded87c6f7b7e705` |
| clap-trap (MIT) | `c75d353dc57140cfceebf96dcbea9c491bef4f10` | `85c12b3b951aa1088111fd7020c873d5d1e0421482475bc793eb53cf7430ad86` |
| clap-info | `04c932f5efcae39a91e9d8db034ae25f090dcb71` | `c0eaff079747e18bc8438a8587c03841a62966095ee765eed10a17c1ceb2add7` |

## Repository tests

`.\tools\test.ps1` is green; stdout is `test-run.txt` and the Odin test-runner
log (with the per-package counts) is `test-run-stderr.txt`.

| Package | Tests |
| --- | --- |
| `core/stream` | 9 |
| `core/dsp` | 14 |
| `core/transport` | 9 |
| `tests` | 7 |
| `third_party/clap/abi` | 2 |
| `adapters/clap` | 10 |
| `products/pulse` | 16 |
| **Total** | **67** |

The Milestone 1 count was 61. New tests cover: capture off with more windows than
queue capacity (live analysis valid, zero records produced, no invalid latch);
capture on with forced overflow (capture invalid + dropped counter, audio domain
and snapshot still valid); telemetry drain through the real plugin binary equal
to the backend export field-for-field; extension enable/disable/schema;
capture-mode round-trip in authoring state; adapter forwarding with a host sink;
and the C miniature plugin implementing the draft extension.

The ABI gate now checks 36 struct sizes and 153 field offsets against C (M1:
33/132); the extra facts are the draft record, sink and vtable.

```
check-boundary: ok (12 core files, 0 verification files, 7 third_party files, 2 adapters files, 3 products files scanned)
CLAP ABI layout: 36 struct sizes and 153 field offsets agree with C
CLAP C probe: entry/factory/plugin/host/events/audio-ports vtables agree in both directions
```

## clap-validator

```powershell
clap-validator validate out\pulse.clap --json --hide-output -j 1 > clap-validator.json
```

Result: **exit 0, 32 passed, 12 skipped, 0 failed** — identical to Milestone 1.
Raw JSON in `clap-validator.json`; every name/status in
`clap-validator-summary.txt`. No parameter was added (the capture mode is an
extension plus an authoring-state flag), so parameter-count/range checks are
unchanged. State tests still pass with the schema 3 flag word.

### Fuzz (known policy incompatibility, expected)

```powershell
clap-validator fuzz out\pulse.clap --json -d 10s -j 1
```

Exit 1 with one finding, recorded verbatim in `clap-validator-fuzz.json`:

> The sample written to output port 0, channel 0, and sample index 0 is
> subnormal.

This is the same M1 finding (the fuzzer's channel/seed varies): Pulse is a
bit-exact passthrough meter, so deliberately subnormal input remains subnormal
in output. Flushing it would break the passthrough contract. Non-fuzz process,
denormal, parameter and state tests pass.

## clap-trap

All commands used the pinned `build\Release\clap-trap.exe`.

| Check | File | Result |
| --- | --- | --- |
| `validate --blocks 100 --buffer-size 256` | `clap-trap-validate.txt` | load/create/init/activate/start/process/stop/deactivate/destroy |
| `info` | `clap-trap-info.txt` | descriptor, one stereo in/out, 4 parameters, standard extensions |
| `state --roundtrip -o state.bin` | `clap-trap-state.txt` | **68 bytes**, 4 parameters, all match after restore |
| `process -i input.wav -o output.wav --float --buffer-size 256` | `clap-trap-render.txt`, `clap-trap-render-compare.txt` | **0 differing bytes** of 384,044 |
| `bench --blocks 20000` | `clap-trap-bench.txt` | 105.9× realtime, 50.4 µs/block |

State grew from 64 to 68 bytes because schema 3 appends the product flag word
(`u32`); the 4 parameter values are unchanged. The render is bit-exact:
input/output SHA-256 both
`2b257fb81bb0f074f4dc887632be2b568fb887f2b068743cb5abbe377cefe2cc`
(48 kHz, 2 ch, 48,000 frames, float32, 384,044 bytes).

`clap-trap info` does not list the private draft extension: third-party tools
enumerate CLAP's known extension ids. The draft is reachable through
`get_extension` and is exercised by the repository tests and the C probe. This
is expected for a private draft, not a regression.

## clap-info

```powershell
clap-info out\pulse.clap > clap-info.json
```

Exit 0. Reports CLAP 1.2.10, the correct descriptor/features, one stereo input
and output with in-place pairs, and all four parameters. The JSON is the same
size as the M1 dump (7,618 bytes) because the public descriptor, ports and
parameters did not change. clap-info enumerates CLAP's known extension list, so
the private draft appears under its enumerated-but-unimplemented section; that
is expected.

## Telemetry extension evidence

The draft is documented in
[`docs/draft-telemetry-extension.md`](../../draft-telemetry-extension.md).

| Item | Value |
| --- | --- |
| Extension id | `com.carnival-science.telemetry-capture.draft/1` |
| Draft extension UUID | `33c18b91-bc23-4290-86a8-2d4035316ecc` |
| Measurement schema UUID | `fdecfe25-9b08-4163-ade3-baf7bcc2edab` |
| Schema version | 1 |
| Thread rule | main thread only; host sink is synchronous; record pointer valid for the call only |
| Enable | clears the queue, dropped counter and capture validity; off by default |
| Disable | produces nothing further; resets dropped/capture validity to 0/true |

ABI proof: `tools/abi/abi_probe.c` emits C `sizeof`/`offsetof` for the record,
sink and vtable plus the ids/UUIDs; `abi_test.odin` compares all of them.
`tools/abi/cc_probe.c` implements the extension in C; `cc_test.odin` enables it,
drains records through an Odin callback, forces overflow and checks the dropped
counter.

## What changed in behaviour

- **Capture off (default):** no canonical records are produced. The 4096-record
  queue cannot saturate in an ordinary session; live analysis and snapshots are
  unchanged and stay valid.
- **Capture on, queue overflow:** records are dropped, `dropped` grows and
  `capture_valid` becomes false. Live analysis, snapshots and `valid`/`overrun`
  do not change.
- **Lost audio samples:** unchanged. Audio-domain invalid still latches and
  invalidates records/snapshots until reset.
- **Capture validity is sticky** until a new enable episode or reset; draining
  the queue does not repair it.
- **Authoring state:** schema 3 adds a flag word; bit 0 is the capture mode.
  v1/v2 files load with capture off.

## Gaps / honesty notes

- Hosted CI still does not execute (the M1 billing/spending-limit block is
  unchanged); evidence is local Windows x64.
- Cross-OS bit-identical records remain unproven.
- The draft extension's UUIDs and schema are frozen only within draft `/1`;
  a breaking revision must change the id.
- `capture_set_enabled` clears the queue on the main thread. Calling it while
  audio is running can discard a record at the switch; callers needing an exact
  boundary should stop processing first. This is documented in the draft doc.
- Main-thread enforcement relies on `clap.thread-check` when the host provides
  it; without it the rule is contractual.
- Record layout is declared once in `third_party/clap` and aliased by
  `products/pulse`; the C header is a mirror proven by the layout probe. A
  future field change must update both and bump the schema.
