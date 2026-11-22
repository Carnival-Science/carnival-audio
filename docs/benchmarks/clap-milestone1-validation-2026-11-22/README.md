# Milestone 1 external CLAP validation (2026-11-22)

Host: Windows 11 x64 (10.0.19045), MSVC 19.51.36248.0, CMake 4.4.4,
rustc/cargo 1.98.1, Odin dev-2026-11-nightly:08539cd.

Artifact validated:

| Item | Value |
| --- | --- |
| Path | `out/pulse.clap` |
| Plugin ID | `com.carnival-science.pulse.meter` |
| Size | 608,768 bytes |
| SHA-256 | `cbc7b516210257519bb05787f32d5a6e70c51b470bf037b0e71b73a3eea5afd7` |

Build command:

```powershell
C:\odin\odin.exe build products/pulse -collection:carnival=C:\Users\saman\dev\pulse `
  -build-mode:dll -define:PULSE_PLUGIN_BUILD=true -out:out\pulse.clap -o:minimal
```

`dumpbin /exports out\pulse.clap` reports exactly one exported name:
`clap_entry` (ordinal 1, RVA 0x89A40).

Odin's DLL output is **not byte-reproducible**: two consecutive builds of the
same source produced different PE files (timestamps; same size and behaviour).
The SHA-256 above identifies the exact artifact these checks were run against,
not a reproducible-build guarantee. This is recorded as remaining work.

## Tools (built outside the repository)

These were cloned to `%TEMP%\pulse-tools` and never vendored into this
repository.

| Tool | Upstream | Commit | Version / build | Binary SHA-256 |
| --- | --- | --- | --- | --- |
| clap-validator | https://github.com/free-audio/clap-validator | `7596871984e669823a90a71ff5823131a978df57` | 0.4.1, `cargo build --release` | `aeaae2a63b6e146eb841fbbbd47c68c27be837acb72821982ded87c6f7b7e705` |
| clap-trap | https://github.com/dfl/clap-trap | `c75d353dc57140cfceebf96dcbea9c491bef4f10` | MIT, CMake Release, `-DCLAP_TRAP_WASM_SUPPORT=OFF -DCLAP_TRAP_BUILD_TESTS=OFF` | `85c12b3b951aa1088111fd7020c873d5d1e0421482475bc793eb53cf7430ad86` |
| clap-info | https://github.com/free-audio/clap-info | `04c932f5efcae39a91e9d8db034ae25f090dcb71` | CMake Release; submodules clap `195b42a0…`, jsoncpp `42e892d9…` | `c0eaff079747e18bc8438a8587c03841a62966095ee765eed10a17c1ceb2add7` |

`free-audio/clap-trap` no longer resolves on GitHub; `dfl/clap-trap` is the MIT
headless host named by `NOTICE.md`. WASM support was disabled because the
native `.clap` path does not use it.

## clap-validator

Command:

```powershell
clap-validator validate C:\Users\saman\dev\pulse\out\pulse.clap `
  --json --hide-output -j 1 > clap-validator.json
```

Result: **exit 0, 32 passed, 12 skipped, 0 failed.** The raw JSON is
`clap-validator.json`; `clap-validator-summary.txt` lists every test name.

All applicable lifecycle, descriptor, audio port, parameter, state, transport
and process checks passed, including:

- `process-audio-basic-out-of-place`, `process-audio-basic-in-place`
- `process-varying-sample-rates`, `process-varying-block-sizes`,
  `process-random-block-sizes`, `process-reset-reactivate`
- `process-audio-denormals` (performance test, passed)
- `param-set-events`, `param-set-no-cookies`, `param-set-wrong-namespace`,
  `param-fuzz-basic`, `param-fuzz-bounds`, `param-fuzz-sample-accurate`,
  `param-fuzz-modulation`, `param-conversions`, `param-default-values`
- `state-invalid-empty`, `state-invalid-random`,
  `state-reproducibility-basic`, `state-reproducibility-binary`,
  `state-reproducibility-buffered`
- `transport-null`, `transport-fuzz`, `transport-fuzz-sample-accurate`

Skipped (not applicable, not failures):

- `scan-rtld-now` — Unix-only.
- 3 × preset-discovery — no preset discovery factory.
- 2 × 64-bit audio — not advertised.
- 3 × note ports — no note ports.
- audio-ports-activation / audio-ports-config / configurable-audio-ports —
  not implemented.

### Initial failure and fix

The first validator run failed 3 state tests: loading a state file changed
parameter values without asking the host to rescan. `adapters/clap` now looks up
`clap.params` from the host during `init` and calls
`host_params.rescan(CLAP_PARAM_RESCAN_VALUES)` after a successful state load on
the main thread. The rerun above is clean.

## clap-validator fuzz

Command:

```powershell
clap-validator fuzz C:\Users\saman\dev\pulse\out\pulse.clap `
  --json -d 10s -j 1 > clap-validator-fuzz.json
```

The 10-second bounded fuzz run stopped with one finding (recorded verbatim in
`clap-validator-fuzz.json`):

> The sample written to output port 0, channel 1, and sample index 0 is
> subnormal.

This is **expected by the product contract, not an ABI defect**. Pulse is a
bit-exact passthrough meter: clap-validator's fuzzer deliberately feeds a
subnormal input signal and rejects any subnormal in the output. Flushing it to
zero would break the required sample-for-sample passthrough and would alter
host audio. The plugin does not change FTZ/DAZ state. The finding is therefore
published as a known policy incompatibility rather than silently "fixed".
Non-fuzz process, denormal, parameter and state tests pass.

## clap-trap

All commands used `build\Release\clap-trap.exe` from the pinned build above.

### validate

```powershell
clap-trap validate out\pulse.clap --blocks 100 --buffer-size 256
```

```
✓ Plugin loaded
✓ Got plugin factory
✓ Found 1 plugin(s)
── Pulse Meter ──
  ✓ create_plugin()
  ✓ init()
  ✓ activate(48000 Hz, 256 samples)
  ✓ start_processing()
  ✓ process() x100 blocks
  ✓ stop_processing()
  ✓ deactivate()
  ✓ destroy()
All 1 plugin(s) validated successfully.
```

### info

`clap-trap info out\pulse.clap` → `clap-trap-info.txt`. It reports the correct
descriptor, one stereo input and one stereo output, four parameters with the
expected stable IDs/ranges/defaults, and the implemented extensions
(`clap.params`, `clap.audio-ports`, `clap.latency`, `clap.state`, `clap.tail`).

### state round-trip

```powershell
clap-trap state out\pulse.clap --roundtrip -o state.bin
```

```
Saved state: 64 bytes
Captured 4 parameter values
Restored state
All 4 parameters match after restore
```

64 bytes = 16-byte header + 4 × (u32 ID + f64 value), matching schema 2.

### WAV render, bit-exact passthrough

A deterministic 48 kHz/2-channel/48,000-frame float32 WAV was generated offline
(sine 440 Hz left at 0.6, 660 Hz right at 0.3) and rendered:

```powershell
clap-trap process out\pulse.clap -i input.wav -o output.wav --float --buffer-size 256
```

```
Input:  ... (48000 Hz, 2 ch, 48000 frames)
Output: ... (48000 Hz, 2 ch, 48000 frames, float32)
```

Byte comparison of the complete 384,044-byte WAV files: **0 differing bytes**
(header and f32 sample payload identical). This is external confirmation of the
bit-exact passthrough contract for the supported format.

### bench

```powershell
clap-trap bench out\pulse.clap --blocks 20000
```

```
Pulse Meter   107.4x realtime   49.6 µs/block  (20000 blocks)
```

The repo's own observation test (debug test build, 256-frame blocks) reports
p50 51.40 µs, p95 69.20 µs, p99 73.10 µs, max 99.90 µs, 0 dropped canonical
records, queue high-water 1250/4096, and cold create+activate 92.80 µs. Timings
are observations for this machine, not real-time guarantees.

## clap-info

```powershell
clap-info out\pulse.clap > clap-info.json
```

`clap-info.json` reports CLAP `1.2.10`, the correct descriptor/features, one
stereo input and output with in-place pair IDs, all four parameters, and the
implemented extension tables. This independently confirms the extension vtables
and parameter/port metadata through a second host implementation.

## Gaps recorded

- No macOS/Linux `.clap` artifact is released; CI compiles and tests those
  targets only.
- clap-validator fuzz has the documented subnormal-passthrough incompatibility.
- No pluginval run: GPL-3.0, external-only policy, and coverage is supplied by
  clap-validator + clap-trap here.
- Cross-OS numeric reproducibility of measurement records remains unproven;
  this evidence is Windows x64 only.









