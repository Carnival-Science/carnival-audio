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
| Meter engine (`core/meter`) | shared analysis engine (two consumers already: CLAP and capture) |
| Stream and transport (`core/stream`, `core/transport`) | DAW engine foundations |
| Semantic state (future) | shared plugin/project serialization |
| CLAP adapter (`adapters/clap`, future) | reusable plugin-authoring infrastructure |
| CLAP ABI (`third_party/clap`, future) | standalone open-source ABI package — only after a real plugin and an independent host both use it |
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
  - `core/meter` (`meter`) — source-independent meter engine: windowed analysis,
    source clock/epochs, capture-domain records and snapshot publication. Its
    two consumers are the CLAP binding and the standalone capture meter.

  `core/` may import Odin `core:` packages and its sibling core packages only.
  It **must not import alicorn, SDL, miniaudio, WASAPI/ALSA/CoreAudio, CLAP,
  `third_party/`, `adapters/`, `products/` or `verification/`.**
- `verification/` — independent A−1 laboratory. It holds the independent CLAP
  host (`host/`), verification-local references and probes (`lab/`), the
  fresh-process worker (`worker/`), deterministic scenarios, and dated evidence
  reports. It may import core record formats and the neutral `third_party/clap`
  ABI declarations but **must not import `core/dsp`, `adapters/` or
  `products/`**, and its numerical references must not share Pulse's DSP
  implementation. Sharing the CLAP protocol declaration is fine; sharing the
  DSP that computes expected results is not. Run
  `.\tools\run_verification.ps1` for the census. See `verification/AGENTS.md`.
- `third_party/` — neutral protocol/ABI surface. `third_party/clap` holds the
  CLAP 1.2.10 foreign declarations, the vendored MIT header subset, the C
  ABI proof probes, and clearly marked private draft extensions for
  Carnival-internal telemetry capture and processing checkpoints (not CLAP
  standard proposals). `third_party/miniaudio` vendors the single-file
  miniaudio 0.11.26 header (public domain) with provenance. `third_party/` may
  import Odin `core:` packages and its own subpackages only; it **must not
  import `core/`, `adapters/`, `products/`, `verification/`, Alicorn or platform
  audio/UI libraries.** `adapters/`, `verification/` and `products/` may import
  `third_party/clap`. It is the future open-source extraction candidate, but is
  extracted only after **both** a real plugin (`adapters/clap`) and an
  independent host (`verification/`) exercise it.
- `tests/` — integration tests (package `tests`) across the core packages.
- `tools/` — build, test, ABI-probe and boundary harness.
- `adapters/` — platform and host adapters. `adapters/clap` (Milestone 1)
  implements the generic CLAP lifecycle/params/state adapter and the draft
  telemetry/checkpoint forwarding; `adapters/wasapi` (Milestone 3.1) implements
  shared-mode loopback capture, a bounded ring and explicit stall/recovery
  discontinuities. May import `core/`, `third_party/clap` and (only
  `adapters/wasapi`) `vendor:miniaudio`; never imported by core/ or
  products-owned code except through the documented direction.
- `products/` — `products/pulse` is the headless CLAP meter binding over
  `core/meter`; `products/pulse-mini` (Milestone 3.2a) is the standalone
  capture meter: a native Alicorn window by default and the M3.1 console meter
  under `--headless`. Its `products/pulse-mini/presentation` subpackage is a
  pure snapshot-to-visual mapping (core/transport only). The Alicorn
  standalone/editor gradient follows from this product.
  `products/reference/` holds gain, biquad and feedback-delay reference
  processors plus deliberately defective test-the-tester fixtures, built from
  the same adapter. `products/` may import `adapters/`, `core/` and
  `third_party/clap`; only `products/pulse-mini` may import Alicorn
  (`alicorn:ui`, `alicorn:runtime`) and it must never import `verification/` or
  a platform audio/UI backend directly. `core/meter` remains Alicorn-free.
- `research/` — **architectural destination, not created yet.** Isolated
  execution research; no product or adapter imports.

`tools/check-boundary.ps1` enforces the `core/`, `verification/`,
`third_party/`, `adapters/` and `products/` import boundaries. See
`docs/architecture.md` for the full map and the extraction table.

## Checks

Run `.\tools\test.ps1` before proposing changes, and
`.\tools\run_verification.ps1` when a behavioral or state change should produce
fresh laboratory evidence. Keep the real-time callback free of allocation,
locking, I/O, and rendering work; analysis overrun must produce explicit
invalid state, never silently valid readings.

## Conventions

Match Alicorn's Odin style (tabs, `Pascal_Snake` naming, `@(test)` procedures).
Determinism: fixed block sizes, documented FTZ/DAZ and FMA policy, explicit
rounding; golden literals and tolerances in `tests/`.
