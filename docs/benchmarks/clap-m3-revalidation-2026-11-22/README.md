# M3 `.clap` revalidation (2026-11-22)

Quick revalidation after the Milestone 3.0/3.1 changes. This is **not** a new
external-tool run: the pinned `clap-validator`/`clap-trap`/`clap-info` tools are
not installed in the development environment used for this pass. What was run
is recorded below, together with the explicit gap.

## Artifact

| Item | Value |
| --- | --- |
| Path | `out/pulse.clap` |
| Size | 618,496 bytes |
| SHA-256 (census pass) | `ea7a4fe60a0b423902b10c4e0f47ef3c7861b6daa8fd3b3d29c5d7c36a871568` |
| SHA-256 (later source-identical rebuild) | `5838e6c45288b9c3da2ed87786030a71711ade125a8f762f69cd18cde4f08219` |
| Build | `.\tools\build.ps1`, Odin `dev-2026-11-nightly:08539cd` |
| Plugin id / version | `com.carnival-science.pulse.meter` / `0.1.0` |

As in Milestone 1, consecutive Odin DLL builds are not byte-reproducible, so
these hashes name exact binaries, not a reproducible build. The two hashes
above are the same source built twice (the later rebuild includes only an
unrelated capture-adapter cleanup), which is the reproducibility gap already in
the ledger.

## What changed in the standard CLAP surface

- The standard extensions are unchanged: audio-ports, params, state, latency,
  thread-check and tail. There is still no standard render/params automation
  extension.
- Pulse's **authoring state schema is still 3**; no migration was added and the
  three historical fixtures (v1, v2, v3 capture-off/on) still pass.
- The new processing-checkpoint extension is a **private draft extension**
  (`com.carnival-science.processing-checkpoint.draft/1`). Standard hosts never
  query it. Pulse reports `supported() == false`.
- No new parameters; IDs and ranges are unchanged.

Therefore clap-validator's parameter/state/fuzz surface for the standard
extensions is the same as the pinned Milestone 1 pass, which remains the
external-tool record
(`docs/benchmarks/clap-milestone1-validation-2026-11-22/`).

## What was run

1. **Independent host census** (`.\tools\run_verification.ps1`, report
   `verification/reports/2026-11-22-172719/`): 8 specimens, 82 rows, 3 expected
   failures, 0 unexpected, 0 lab failures. Pulse loads, activates, processes,
   saves/loads state, migrates all four fixtures and drains telemetry through a
   host that does not link Pulse code.
2. **Bit-exact passthrough**: the census input and output WAVs are byte
   identical (`sha256 4e10deff…d4d5ff` for both over 16,384 frames), and the
   product tests cover in-place and non-in-place passthrough.
3. **State round-trip**: schema-1/2/3 fixtures restore the expected parameter
   values and capture default; a just-saved schema-3 state round-trips. Pulse's
   processing state is not serialized (declared unsupported checkpoint).
4. **Engine extraction regression**: the pre-extraction and post-extraction
   census rows, classes and Pulse `output.wav`/`records.csv` hashes are
   identical.

## Explicit gap — closed (2026-11-22, later same day)

The pinned external tools were located in the M1 tool cache
(`%TEMP%\pulse-tools`) and rerun against the rebuilt artifact above
(`5838e6c4…`, the source-identical rebuild):

| Tool | Result |
| --- | --- |
| `clap-validator` (0.4.1, pinned) | **44 run, 32 passed, 0 failed, 12 skipped** — identical to Milestone 1; `tools/m3-validator.log` |
| `clap-trap validate` | clean pass; `tools/m3-trap-validate.log` |
| `clap-trap state --roundtrip` | **68 bytes saved, all 4 parameters match after restore**; `tools/m3-trap-state.log` |
| `clap-trap process` (float, 256-frame blocks) | **0 differing data bytes across 384,000** (48 kHz stereo float32 sine render); input/output WAVs and logs in `tools/` |

Inputs for this run were regenerated (`tools/m3-render-input.wav`); the render
output is byte-identical to its input over the data chunk. The earlier gap
statement above applied only until this run.
