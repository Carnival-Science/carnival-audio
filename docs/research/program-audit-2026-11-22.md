# Pulse program research audit — 2026-11-22

Status: completed research input to Milestone 0. Sources are listed at the end;
claims marked *(audit)* come from the completed audit record and were not
re-verified locally.

## Question

What is the smallest **source-independent** Odin analysis core that can carry a
headless CLAP meter, without pulling audio, plugin or platform code into
Alicorn?

## Findings

### CLAP ecosystem

- **No Odin CLAP bindings exist.** Milestone 1 therefore writes Odin `foreign`
  declarations against CLAP **1.2.10** (MIT, `github.com/free-audio/clap`).
  Bindings are hand-written against the pinned C headers; no generator or
  wrapper library is introduced.
- **clap-validator** (MIT, Rust) validates loading, factory, parameters, state,
  process and fuzzing, with multi-process crash isolation.
- **clap-trap** (MIT) provides headless render/state/benchmark/process-to-WAV
  workflows. **clap-info** (MIT) is a small inspection tool.
- All three are safe to pin by commit and invoke **externally** in CI.
- **pluginval is GPL-3.** It may only be used as an external binary; it is never
  linked, embedded or redistributed with Pulse.
- **FFTW is GPL** and is never used. The FFT is pure Odin for licence hygiene
  and deterministic build inputs.

### Desktop capture

- **miniaudio** (public domain, vendored at `C:\odin\vendor\miniaudio`) supports
  WASAPI loopback **including per-process loopback**
  (`loopbackProcessID` / `loopbackProcessExclude` in `device_io_types.odin`).
  Verified in the local Odin vendor tree. It is the recommended capture backend
  for the standalone meter.
- Raw WASAPI is not sufficient on its own: `vendor:windows:wasapi` in this Odin
  distribution does **not** declare `IAudioCaptureClient`, so a raw path would
  need a hand-written COM vtable. That work is not justified for Milestone 0.
- Loopback can deliver silence gaps when no application is rendering; the meter
  must not interpret those as a stopped clock. This is a capture-adapter
  concern, not a core-analysis concern.

### Alicorn embedding (#121)

Alicorn's host-embedded editor proof passed its Windows external-HWND gate:
child window surface, WebGPU rendering, 18/18 checks (merged `704f6f5`).

Open items:

- macOS and Linux embedding adapters are not implemented.
- IME composition and accessibility-tree validation in embedded mode.
- Real driver/device loss behaviour (the proof covers simulated loss).
- A **~191–211 MB process-private memory delta for a second editor**. This is an
  investigation target for Milestone 3, not evidence of GPU memory and not a
  universal per-plugin cost. Broad plugin support is gated on understanding it.

### Reuse versus build

| Area | Decision | Reason |
| --- | --- | --- |
| Desktop capture | **Reuse** miniaudio | Public domain, loopback incl. per-process, already vendored |
| CLAP validation/rendering | **Reuse** clap-validator, clap-trap, clap-info as external tools | MIT, mature, crash-isolated |
| Host plugin adapter / editor embedding | **Reuse** Alicorn (#121) at the editor edge | Already proven; keeps UI out of the DSP core |
| CLAP declarations | **Build** in Odin | No bindings exist |
| DSP (FFT, peak/RMS, correlation) | **Build** in pure Odin | Determinism, licence hygiene, no FFTW |
| Real-time transport | **Build** | Must be bounded and sample-complete by contract |
| WAV replay and fixtures | **Build** | Deterministic reference source, no third-party decoder |
| Verification probes | **Build** | Independent oracles and canonical records are Pulse deliverables |

## Architecture decision record

**ADR-1 — Three-project split.** Pulse owns the analysis core, standalone meter
and CLAP plugin. Alicorn remains a UI/rendering/accessibility library with no
audio, DSP or plugin-hosting code. Verification (`audio-verification`) is an
independent host and consumes Pulse artifacts.

**ADR-2 — Milestones are evidence-gated.** M0 source-independent core → M1
headless CLAP meter (#237) → M2 verification laboratory (#236) → M3 standalone
Mini + embedded editor (#131). Each milestone must produce evidence before the
next depends on it.

**ADR-3 — Deferred by default.** No WASM DSP, no new plugin format, no VST3
wrapper before real-host validation (#132), no DAW, no generic framework, and no
approximate caching ("implementation must be earned through evidence").

**ADR-4 — Sample-clock authority.** Analysis windows are defined by absolute
sample frames and an explicit epoch, never by wall-clock or UI frame cadence.
Dropped audio invalidates sample-complete measurements until an explicit reset.

**ADR-5 — Pure-Odin FFT.** Radix-2 with plan-time twiddles; no GPL library and
no runtime transcendental calls in per-sample paths.

## Risk register

| Risk | Impact | Mitigation / owner |
| --- | --- | --- |
| CLAP ABI declarations wrong (sizes, calling convention, version struct) | Meter fails to load or corrupts host state | Hand-check against 1.2.10 headers; clap-validator; M1 |
| FTZ/DAZ/FMA differences between build modes or hosts | Measurement drift across hosts | Documented M0 policy; host-side FTZ/DAZ is a #237 concern; tolerances and fingerprints |
| WASAPI loopback silence gaps | False "source stopped" or clock jumps | Capture adapter treats gaps as discontinuity events, keeps sample clock; M3 |
| Overrun reported as valid data | Wrong metering | Sticky overrun flag invalidates sample-complete accumulations until reset; M0 transport |
| Plugin state migration | Old sessions load wrong settings | Versioned authoring state, explicit migration; M1/M3 |
| Scope creep into Alicorn | Boundary violation, untestable coupling | AGENTS.md boundary + `tools/check-boundary.ps1` |
| Second-editor memory delta (~191–211 MB) | Poor multi-instance behaviour | Measure per-instance process-private memory in M3 before broad support |
| Golden values accidentally tied to one libm | False cross-platform failures | Closed-form literals with tolerances; per-platform plan-time trig accepted |

## Sources

- Carnival-Science/Alicorn #122 (program brief), #123 (stream/replay), #124
  (transport/snapshots), #126 (analysis), #237 (headless CLAP meter), #236
  (verification laboratory), #131 (embedded editor), #121 (embedding proof).
- CLAP: <https://github.com/free-audio/clap> (MIT), ABI 1.2.10.
- clap-validator, clap-trap, clap-info: MIT, pinned by commit when used.
- pluginval: GPL-3.0, external binary only.
- miniaudio: public domain, `C:\odin\vendor\miniaudio` (loopback and
  per-process loopback fields verified locally).
- FFTW: GPL-2.0+; deliberately unused.
