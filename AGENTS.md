# AGENTS.md — carnival-audio

`carnival-audio` is Carnival Science's single repository for the audio
foundations behind Pulse: the source-independent Odin analysis core, the
verification laboratory that checks it independently, and the adapters and
products built on top. It is **one repository with strict internal module
boundaries, not a monolithic application**.

Alicorn is a separate repository and stays a UI/rendering/accessibility
library: no audio, DSP or plugin-hosting code may be added to Alicorn
(Carnival-Science/Alicorn#122 is a non-negotiable boundary).

## Founder directives

- **One repository, strict internal boundaries.** Modules have explicit,
  enforced dependencies; they do not become a monolithic application just
  because they share a repository.
- **No premature library split.** Early splitting into independently versioned
  libraries is rejected: do not stabilize an abstraction that has not survived
  real plugins.
- **Dependency direction is explicit:** `core ← adapters ← products` — products
  may import adapters, adapters may import core, and imports never point the
  other way. Verification depends on core **record formats** only and must
  never import product or adapter code. Execution research is isolated.
- **Verification independence (critical).** Verification must use independent
  numerical references — its own naive DFT, external offline tools, published
  closed-form values. If the verification tool uses the same FFT
  implementation as Pulse to generate and validate results, the test proves
  little. Independence is enforced structurally: `verification/` must not
  import `core/dsp`, `adapters/` or `products/`.
- **Extraction criteria (future).** Extract a module into its own package or
  repository only when it has all four: **at least two genuine consumers**, a
  **reasonably stable interface**, **independent tests**, and a **concrete
  reason for its own release cycle**.

### Future-extraction table

Recorded now so today's boundaries point at tomorrow's destinations. Nothing
here is extracted yet.

| Module | Future destination |
| --- | --- |
| DSP primitives (`core/dsp`) | shared DSP library |
| Stream and transport (`core/stream`, `core/transport`) | DAW engine foundations |
| Semantic state (future) | shared plugin/project serialization |
| CLAP adapter (`adapters/clap`, future) | reusable plugin-authoring infrastructure |
| Verification (`verification/`) | independent developer-facing product |
| Render capsules (future) | reproducibility / incremental rendering |
| Pulse (`products/pulse`, future) | standalone product |

## Layout scopes

- `core/` — the stable center. Packages:
  - `core/stream` (`stream`) — stream descriptor, sample clock, WAV replay,
    generated signals; the stream/replay layer.
  - `core/dsp` (`dsp`) — sample peak, windowed RMS, peak hold, FFT, stereo
    correlation.
  - `core/transport` (`transport`) — bounded SPSC block ring, revisioned
    measurement snapshots.

  `core/` may import Odin `core:` packages and its sibling core packages only.
  It **must not import alicorn, SDL, miniaudio, WASAPI/ALSA/CoreAudio, CLAP,
  `adapters/`, `products/` or `verification/`.**
- `verification/` — independent verification laboratory. No implementation
  yet; Milestone 2 follows Milestone 1. It may import core record formats but
  **must not import `core/dsp`, `adapters/` or `products/`**, and its numerical
  references must not share Pulse's DSP implementation. See
  `verification/AGENTS.md`.
- `tests/` — integration tests (package `tests`) across the core packages.
- `tools/` — build, test and boundary harness.
- `adapters/` — **architectural destination, not created yet.** Platform and
  host adapters: `adapters/wasapi` capture when Milestone 3 starts,
  `adapters/clap` for Milestone 1. May import `core/`; never imported by it.
- `products/` — **architectural destination, not created yet.**
  `products/pulse` is the standalone application and the only place that
  imports Alicorn.
- `research/` — **architectural destination, not created yet.** Isolated
  execution research; no product or adapter imports.

`tools/check-boundary.ps1` enforces the `core/` and `verification/` import
boundaries. See `docs/architecture.md` for the full map and the extraction
table.

## Checks

Run `.\tools\test.ps1` before proposing changes. Keep the real-time callback
free of allocation, locking, I/O, and rendering work; analysis overrun must
produce explicit invalid state, never silently valid readings.

## Conventions

Match Alicorn's Odin style (tabs, `Pascal_Snake` naming, `@(test)` procedures).
Determinism: fixed block sizes, documented FTZ/DAZ and FMA policy, explicit
rounding; golden literals and tolerances in `tests/`.
