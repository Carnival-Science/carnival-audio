# AGENTS.md — verification

`verification/` is the independent A−1 behavioral verification laboratory
(Alicorn#236, Milestone 2). It is implemented, not a placeholder.

## Layout

| Path | Role |
| --- | --- |
| `host/` | independent CLAP host library: dynamic library load, factory/descriptors, instance lifecycle, variable blocks, parameter events, transport, state save/load, host extensions (audio-ports/params/state/latency/tail/thread-check), draft Carnival telemetry drain |
| `lab/` | verification-local numerical references (signal generator, peak/RMS, naive O(n²) DFT), WAV writer, hashing, scenario/evidence schemas, numeric fingerprint, probes |
| `worker/` | one-process-per-run executable: scenario in, JSON evidence + WAV/CSV artifacts out, exit codes 0/1/2 |
| `scenarios/` | deterministic scenario files for Pulse, the reference processors and the third-party specimen |
| `specimens/third_party/` | pinned MIT third-party CLAP census binary and provenance |
| `reports/` | dated run reports: census JSON/CSV, manifest, human report, raw per-run evidence |

`tools/run_verification.ps1` builds and runs the whole census.

## Non-negotiable: independent numerical references

Verification must obtain expected values from **independent numerical
references**, never from the implementation under test:

- the hand-written naive DFT and closed-form peak/RMS in `lab/math_ref.odin`;
- closed-form values and literals;
- external offline tools if later added, with version and provenance recorded.

Do not import `core/dsp`, do not call into Pulse DSP, and do not reuse its FFT,
window, filter or measurement code to generate expectations. If verification
and Pulse share the FFT implementation, the comparison proves little. See
`README.md` for the full rule.

## Import boundary

Allowed: core record-format declarations (`core/stream`, `core/transport`
records), the neutral `third_party/clap` ABI declarations, and Odin `core:`
packages.

Forbidden: `core/dsp`, `adapters/`, `products/`, Alicorn, a CLAP implementation
(`adapters/clap` or any plugin implementation), and platform audio/graphics
libraries. The host loads plugin shared libraries at runtime; it does not link
or import them. `tools/check-boundary.ps1` enforces this in the `verification`
scope, with the explicit `third_party/clap` exception.

## Probe discipline

- Every probe creates its own plugin instance(s); no probe inherits another
  probe's processing state.
- Cross-process repeatability is the runner's job: two worker processes, same
  scenario, artifact hashes compared.
- Static partition invariance is a strict pass/fail class. Automation is
  labelled as a class (`automation_partition_sensitive_control_rate` or
  `automation_partition_invariant_observed`), never collapsed into pass/fail:
  block-start event application is a documented control-rate contract.
- Tail and perturbation probes report measured windows and applicability, not
  convergence claims.
- Deliberately defective specimens must fail exactly the probes they violate;
  the runner records expected specimen failures separately from laboratory
  failures.

## Evidence

Record artifact hashes, inputs, state, host configuration, event and block
schedules, and the numeric environment with every result. State observed
evidence separately from declared guarantees. Never claim universal
determinism, hermetic numerics, real-time safety or cross-platform equivalence
from a finite local run.
