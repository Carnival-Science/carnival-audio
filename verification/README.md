# Verification

Independent behavioral verification laboratory for audio plugins
(Carnival-Science/Alicorn#236, Milestone 2 A−1 slice). Headless-first,
CLAP-first, evidence-driven: fresh-process repeatability, block-partition
invariance, state round-tripping and migration, instance isolation, tail and
perturbation measurements, machine-readable evidence and reproducible failure
cases.

The module lives in the `carnival-audio` repository but is architecturally
independent of the products it verifies.

## Run it

```powershell
.\tools\run_verification.ps1
```

The runner builds Pulse, the reference processors and the worker, runs every
specimen scenario twice in fresh worker processes, and writes a dated directory
under `verification/reports/`:

```
verification/reports/<timestamp>/
    report.md          human report + census table + findings
    census.json        machine-readable probe table
    census.csv         the same rows as CSV
    manifest.json      environment, tool/plugin/scenario hashes, runs, limits
    runs/<specimen>/run<N>/
        evidence.json  probes, metrics, applicability, environment, hashes
        input.wav      generated verification-local input
        output.wav     canonical static render
        records.csv    canonical records when the specimen has telemetry
        partition_*.wav, partition_*_records.csv
        worker.stdout.txt, worker.stderr.txt
```

Exit semantics:

| Exit | Meaning |
| --- | --- |
| 0 | every expectation held, including deliberately defective fixtures failing the probes they violate |
| 1 | an unexpected specimen outcome (real finding or regression) |
| 2 | laboratory/infrastructure failure (build, missing evidence, worker timeout/crash) |

`.\tools\run_verification.ps1 -SkipBuild` reuses existing binaries.
`-TimeoutSeconds 240` controls the per-worker watchdog.

`.\tools\test.ps1` runs the boundary gate, the C ABI probes and every package's
tests, including the host and laboratory unit tests. It builds the reference
gain plugin first so the host integration test has a specimen.

## A−1 thesis

A pass means the record is right for reasons stated in the report, not merely
that two copies of the same implementation agree. A mismatch is a reproducible
artifact (input, state, event and block schedule, environment) before it is a
bug report.

## Independence rule (non-negotiable)

Verification must use **independent numerical references**: its own naive DFT,
closed-form values, and (when added) external offline tools. It must not
generate expected values with the implementation under test.

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

## Architecture

### Independent host (`host/`)

A dynamic CLAP 1.2.10 host, independent of `adapters/clap` and every product:

- load any `.clap` shared library, resolve `clap_entry`, init/deinit;
- enumerate factory/descriptors, create/init/activate/start an instance;
- process variable block sizes with planar stereo buffers;
- deliver parameter events with sample timestamps and an optional transport
  event; always provide non-null empty in/out event lists (some plugins
  dereference them unconditionally);
- host extensions: audio-ports, params (rescan counter), state (memory
  streams), latency, tail, thread-check;
- query and drain the draft Carnival telemetry extension;
- query the draft processing-checkpoint capability (`supported`) and save/load a
  checkpoint through memory streams;
- authoring-state save/load through memory streams.

Thread discipline is observable: the host records its main thread, marks the
audio thread for the duration of each `process` call, and implements
`clap.thread-check`. Plugins that honor the extension therefore reject a
main-thread-only call made off-thread.

### Worker (`worker/`)

One executable, one scenario, one experiment, one evidence file. A fresh
process per run is the crash-isolation and fresh-state boundary. Exit codes are
`0` all probes pass, `1` a probe failed (a specimen finding), `2` laboratory
failure. A worker writes partial evidence before exiting on infrastructure
failure and the runner preserves stdout/stderr and any artifacts.

### Probes (`lab/`)

| Probe | What it establishes | Class |
| --- | --- | --- |
| `measurement` | Pulse canonical records vs independent full-window peak, first peak frame, f64 sum-of-squares RMS and running max hold | canonical measurement |
| `spectrum` | independent naive O(n²) DFT peak bin and amplitude on a bounded 1024-sample window | numerical reference |
| `nonfinite` | output NaN/Inf scan | output validity |
| `repeatability` | two fresh instances in-process produce byte-identical output and records | fresh instance |
| `partition` | same absolute input/static parameters across 64/128/256/512/997/irregular schedules produce byte-identical output and records; a difference is a specimen failure | strict static invariance |
| `automation` | sample-timestamped events under different partitions; labels the observed class instead of collapsing it into pass/fail | control-rate / observed class |
| `state` | authoring save/load and schema-1/2/3 fixture migration (parameter values + capture default); render equality with a current-schema parameter equivalent. It does **not** require output continuation after a restore | authoring state + migration |
| `checkpoint` | optional: skips unless `supported()` is true, then a prefix checkpoint restored into a fresh instance must continue the suffix bit-exactly | processing checkpoint |
| `isolation` | two instances with different parameters, interleaved, match solo runs | instance isolation |
| `reset` | reset then reprocess equals a fresh instance at the same partition | clean-state semantics |
| `tail` | post-input silence length above a documented threshold, declared-tail comparison | boundedness observation |
| `perturbation` | single-sample input delta propagation window | response observation |
| `capture_toggle` | enable/disable episodes (host stops processing around each switch), zero records while disabled, re-enable starts fresh | capture lifecycle |
| `capture_overflow` | 4096-record bounded queue overflow: delivered/dropped counters and capture-domain invalidity, recovery on a new episode | capture lifecycle |
| `gap` | host steady-clock skip: no window straddles the lost range, post-gap windows align and are audio-invalid, capture validity unaffected | discontinuity |

The runner adds `cross_process_repeatability` by comparing `output.wav` and
`records.csv` hashes from two fresh worker processes.

## Scenario format

`verification/scenarios/*.json` (`carnival.verification.scenario/1`). A
scenario names the specimen, input generator (`sine`, `dc`, `impulse`, `noise`,
`silence`, `sine_impulse`), sample rate, block partitions, static parameters,
telemetry mode, measurement settings, automation events, state fixtures, gaps,
tail and perturbation settings, and the probe list. The input generator, PRNG,
peak/RMS and DFT are verification-local; nothing here calls `core/dsp`.

The worker writes the scenario SHA-256, plugin SHA-256, input/output/records
hashes, and the observed numeric fingerprint into evidence.

## Evidence and honesty

Every evidence document carries:

- probe status, class, applicability statement, metrics and details;
- scenario and specimen hashes;
- platform/arch, observed denormal behavior, observed multiply/add
  contraction, CPU model, Odin version and git commit (runner supplies the last
  three);
- artifact hashes for inputs, outputs and canonical records.

The numeric environment is **observed, not hermetic**. Finite probes do not
prove universal determinism, real-time safety, cross-platform equality or
state convergence from silent output. CI is currently billing-blocked, so the
committed evidence is local Windows x64.

## Census

The census currently covers:

- **Pulse** (`products/pulse`, preserved/current build): canonical measurement
  verification, state migration, capture lifecycle and gaps;
- **good reference processors** (`products/reference/`): gain (stateless,
  exact), biquad (per-sample direct form I), feedback delay (persistent state,
  schema-3 authoring parameters plus a processing checkpoint);
- **defective reference processors** used to test the tester:
  block-boundary-resetting smoother (must fail static partition invariance),
  leaky delay (authoring state must pass; its processing checkpoint claims
  support but omits the delay line, so the checkpoint probe must fail), NaN
  trigger (must fail the non-finite probe);
- **small third-party census**: `baconpaul/clap-c99-distortion` (MIT), a pure C99
  stereo distortion. It observes a different, legitimate automation class:
  sample-offset event application is partition-invariant, unlike the Carnival
  adapter's block-start control-rate semantics.

## Relationship to Pulse

Verification depends on core record formats only and develops independently of
Pulse releases. Pulse's headless CLAP meter (Alicorn#237) is the first real
specimen: its sample-timestamped canonical measurement records, not merely its
unchanged audio output, are tested.

## Status

Milestone 2 (A−1 slice) implemented; see the dated reports. Still open:
cross-platform evidence, a larger pinned third-party corpus, performance
profiling on named hardware, and CI execution when billing is restored.

## Remaining work specific to measurement verification

- **Spectrum is not end-to-end yet (F3).** The `spectrum` probe currently
  validates the laboratory's independent naive DFT against the *generated
  input*. It does not compare against spectral measurements emitted by Pulse,
  because Pulse exports no spectrum data. The full comparison becomes possible
  when the Studio analyzer exposes spectrum data (M3.2). No pass in this probe
  is evidence about Pulse's FFT.
- **Migration tests should compare measurement records (F3).** The `state`
  fixture path currently compares rendered passthrough audio. For a measurement
  product the stronger assertion is canonical-record equality after a
  migration; this is wired as a follow-up once the fixture render path compares
  `records.csv` rather than `output.wav`.
