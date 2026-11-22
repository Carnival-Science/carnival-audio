# AGENTS.md — verification

`verification/` is the independent verification laboratory. It will be
implemented in Milestone 2 (A−1 slice), after the Milestone 1 headless CLAP
meter exists.

## Non-negotiable: independent numerical references

Verification must obtain expected values from **independent numerical
references**, never from the implementation under test:

- a hand-written naive DFT or other reference transform written here;
- external offline tools (numpy/SciPy, sox, a recorded analyzer) invoked as
  tools, with version and provenance recorded;
- published closed-form values and literals.

Do not import `core/dsp`, do not call into Pulse DSP, and do not reuse its FFT,
window, filter or measurement code to generate expectations. If verification
and Pulse share the FFT implementation, the comparison proves little. See
`README.md` for the full rule.

## Import boundary

Allowed: core record-format declarations (measurement records, descriptors) and
Odin `core:` packages.

Forbidden: `core/dsp`, `adapters/`, `products/`, Alicorn, CLAP, and platform
audio/graphics libraries. `tools/check-boundary.ps1` enforces this in the
`verification` scope.

## Evidence

Record artifact hashes, inputs, state, host configuration, event and block
schedules, and the numeric environment with every result. State observed
evidence separately from declared guarantees.
