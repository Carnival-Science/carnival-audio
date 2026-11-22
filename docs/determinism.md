# Determinism policy

This document is normative for `core/`. Tests enforce the parts that can be
checked mechanically.

## Build and floating point

- Odin nightly `dev-2026-11-nightly:08539cd` (the toolchain used here) exposes
  **no `-fma` / `-no-fma` build flag** (`odin build -help` has no such option).
  There is therefore no compiler switch to select contraction behaviour.
  Policy: DSP code writes every multiply and add as an explicit, separate
  expression and never calls an FMA intrinsic. It does not *assume* that the
  backend will or will not contract a single expression. Tolerances and the
  golden fingerprints below absorb the difference between a contracted and a
  separately rounded multiply-add in the few places where it can occur.
- No `-ffast-math` equivalent is used. Builds use the default optimisation
  (`-o:minimal` in tests) and do not enable reassociation.
- Accumulators use `f64` for sums of squares and correlation moments. Outputs
  are narrowed to `f32` only at the record boundary.
- Sample storage and analysis buffers are `f32`. Plan-time trigonometry is
  evaluated in `f64` and stored as `f32`.

## Transcendental functions

Per-sample paths in `core/dsp` contain only loads, multiply, add and
compare. `sin`/`cos` are used only when building an FFT plan (twiddle and
window tables). `log10` is used only by reporting helpers that convert an
already-computed RMS to dBFS, never inside a sample loop.

Generated test signals are offline fixtures, not real-time analysis: the sine
and sweep generators may call `sin`, `exp` and `log` per sample. They are not
part of the analysis determinism guarantee; their *outputs* are checked against
closed-form values.

## Denormals

Milestone 0 contains no recursive feedback path that can generate subnormal
values. Peak hold decays toward zero by multiplication and is floored at zero;
windowed sums, FFT butterflies and correlation are feed-forward. FTZ/DAZ is
therefore not required for M0.

Host-dependent FTZ/DAZ control (and its effect on plugin DSP) is an explicit
#237 concern and is out of scope here.

## Measurements and partition invariance

Analysis is defined over **absolute sample frames** within an explicit epoch,
not over callback blocks. Two classes of behaviour are distinguished:

| Measurement | Invariance class | Why |
| --- | --- | --- |
| Sample peak (value, frame, channel) | **Exact** | Per-sample comparison and replacement; independent of grouping |
| Peak-hold envelope | **Exact** | Updated once per frame with precomputed constants |
| Windowed RMS (aligned windows) | **Tolerance** | `f64` sums are accumulated in sample order, but a different block split can change vectorised grouping |
| Windowed correlation (aligned windows) | **Tolerance** | Same reason |
| FFT spectrum for an aligned window | **Tolerance** | Block split may change `f32` window application grouping; plan tables are identical |

Tests process the same 10k-frame stream in 64/128/256/512/997-frame partitions.
Sample peak must be bit-equal. Windowed measures must agree within the
tolerances below. Windows that do not align are a different measurement by
definition. The analysis API never invents window boundaries from block
boundaries.

## Transport continuity

The transport ring enforces the absolute sample clock instead of treating queue
adjacency as stream adjacency. A producer jump records an explicit lost frame
range plus a continuity segment and advances the clock; a resubmitted or
backward range is rejected as a duplicate. Analysis may combine blocks only
while their continuity segment matches. A gap, a sticky overrun or a ledger
overflow invalidates sample-complete measurement windows until an explicit
reset or gap accounting, so a gap can never be rendered as a valid quiet
interval. Block sizes may vary (subject to the configured maximum) without
changing the absolute frame assignment of any sample.

## Numerical conventions

### Sample formats

WAV `u8` decodes as `(v - 128) / 128`; `s16` as `v / 32768`; `s24` as
`v / 8388608`; `s32` as `v / 2147483648`; `f32` as stored; `f64` narrowed to
`f32`. Full-scale negative codes map to exactly `-1.0`. Full-scale positive
codes map to just under `+1.0` except s32, whose `2147483647 / 2^31` is
indistinguishable from `1.0` in f32 (documented narrowing). Writing uses
saturating conversion (clamped to the representable code range), documented in
`wav.odin`.

### dBFS

dBFS is referenced to a **full-scale square wave**, whose RMS is `1.0`:

```
dBFS = 20 * log10(rms)
```

A full-scale sine (peak `1.0`) therefore reads **−3.010299956639812 dBFS**
(`1 / sqrt(2)` RMS). A full-scale square reads **0 dBFS**. Digital silence is
reported at the floor `-144.0 dBFS`, not `-inf`. Sample peak and RMS are never
called true peak or LUFS.

### Correlation

Pearson correlation over a window on the two channels. If either channel's
variance is below `1e-20` (including digital silence and DC), the result is
`value = 0` with `valid = false`. A valid result is clamped to `[-1, 1]` to
absorb rounding. No `NaN` is ever returned.

### FFT normalisation

Complex FFT is unnormalised forward; inverse divides by `N`. Real-FFT amplitude
uses the coherent gain of the window:

```
cg  = mean(window)
amp[0]   = |X[0]| / (N * cg)
amp[k]   = 2 |X[k]| / (N * cg),  0 < k < N/2
amp[N/2] = |X[N/2]| / (N * cg)
```

A bin-centred full-scale sine therefore reports amplitude `1.0` for Hann,
Hamming and Blackman-Harris windows to within scalloping/leakage tolerance.

## Tolerances used by tests

- FFT vs naive DFT (deterministic pseudo-random input, rectangular window):
  relative error `<= 1e-5`, absolute `<= 1e-5`.
- Windowed tone amplitude: `1e-3` (Blackman-Harris), `1e-3` (Hann/Hamming).
- Partition invariance for windowed RMS/correlation: `1e-6` relative.
- Partition invariance for FFT magnitude: `1e-5` relative.
- Closed-form sine RMS: `1e-6` absolute.
- Exact classes: bit equality (`transmute(u32)`).

## Repeatability

The same input and configuration must produce byte-identical measurement
records within a process. Tests run the pipeline twice and compare an FNV-1a
fingerprint over canonical field bytes (not struct padding). Cross-process
reruns are not required for M0; the golden literals plus the in-process rerun
provide the regression signal.

Milestone 1 CI (`.github/workflows/ci.yml`) runs these checks on Windows, Linux
and macOS, but it does **not** compare records across operating systems. No
cross-OS bit-identical claim is made.

## Memory

Initialisation may allocate (plans, ring storage, decoded WAV buffers).
After initialisation, per-block analysis makes no allocations. The memory
ceiling test wraps the heaviest analysis in a counting allocator; the documented
ceiling is **2 MiB** for a 4096-point real FFT plan plus the peak/RMS/correlation
accumulators, a 32-block transport ring and a short WAV encode/decode round
trip. FFT plans are capped at `FFT_MAX_SIZE` (2^20 points) so that a plan cannot
request unbounded storage accidentally.
