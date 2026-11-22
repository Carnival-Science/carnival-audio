# Verification

Independent behavioral verification laboratory for audio plugins
(Carnival-Science/Alicorn#236). Headless-first, CLAP-first, evidence-driven:
fresh-process repeatability, block-partition invariance, state round-tripping
and migration, instance isolation, tail and perturbation measurements,
performance and memory measurements, machine-readable evidence and reproducible
failure cases.

This module lives in the `carnival-audio` repository but is architecturally
independent of the products it verifies. It is the in-repo home of the prepared
`audio-verification` laboratory.

## A−1 thesis

The A−1 slice is the first verification deliverable. It verifies the Milestone 1
headless CLAP meter end to end from its **sample-timestamped canonical
measurement records**, not from rendered audio alone. A host drives the plugin
through recorded block schedules, captures the emitted records, and compares
them — field by field, with recorded tolerances — against references computed
independently of Pulse: sample peak, windowed RMS, dBFS, peak hold, correlation
and FFT magnitude.

A pass means the record is right for reasons stated in the report, not merely
that two copies of the same implementation agree. A mismatch is a reproducible
artifact (input, state, event and block schedule, environment) before it is a
bug report.

## Method stance

Observed evidence is separate from declared or structurally enforced
guarantees. Finite empirical tests do not prove universal determinism or
real-time safety; reports state applicability and nonconformance explicitly.
Artifact hashes, inputs, state, host configuration, event and block schedules,
and the observable numeric environment are recorded with every result.

## Independence rule (non-negotiable)

Verification must use **independent numerical references**: its own naive DFT,
external offline tools (for example numpy/SciPy, sox, or a recorded offline
analyzer), and closed-form values. It must not generate expected values with
the implementation under test.

If the verification tool uses the same FFT implementation as Pulse to generate
and validate results, the test proves little about either. Independence is
structural, not a convention:

- verification imports core **record formats** only;
- it never imports `core/dsp`, `adapters/` or `products/`, and never links
  Pulse DSP;
- it **may** import the neutral `third_party/clap` ABI declarations: a host
  must speak the same protocol as the plugin under test, but sharing a protocol
  declaration is not sharing the implementation;
- it does not share FFT, window, filter or measurement code with the thing it
  verifies;
- every report names its reference, the reference's version, and how the
  reference values were produced.

`tools/check-boundary.ps1` enforces the import side of this rule. Reviewers
enforce the numerical side: a reference that calls into Pulse to decide what
"correct" means is a violation even if it lives outside this directory.

## Relationship to Pulse

Verification depends on core record formats only and develops independently of
Pulse releases. Pulse's headless CLAP meter (Carnival-Science/Alicorn#237) is
the first real reference specimen — its sample-timestamped canonical
measurement records, not merely its unchanged audio output, are tested.

## Status

No implementation yet. Repository prepared; Milestone 2 (A−1 slice) follows
Pulse Milestone 1.
