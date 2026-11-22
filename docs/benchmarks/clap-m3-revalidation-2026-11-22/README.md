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
| SHA-256 | `ea7a4fe60a0b423902b10c4e0f47ef3c7861b6daa8fd3b3d29c5d7c36a871568` |
| Build | `.\tools\build.ps1`, Odin `dev-2026-11-nightly:08539cd` |
| Plugin id / version | `com.carnival-science.pulse.meter` / `0.1.0` |

As in Milestone 1, consecutive Odin DLL builds are not byte-reproducible, so
this hash names the exact binary this pass exercised, not a reproducible build.

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

## Explicit gap

`clap-validator` and `clap-trap` were not available on this machine, so their
pass counts and render comparison were **not re-run**. No claim is made that
they were. Given the unchanged standard extension surface and state schema, the
pinned Milestone 1 results remain the applicable external evidence; a host
with those tools should rerun them against the hash above and append the result
here.
