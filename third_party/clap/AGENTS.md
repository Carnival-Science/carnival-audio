# AGENTS.md — third_party/clap

`third_party/clap` is **neutral CLAP ABI surface**, not an implementation.

- It holds foreign declarations for the official CLAP headers, plus one clearly
  marked private draft extension (`abi/ext_carnival.odin`,
  `draft/carnival-telemetry-capture.h`) for Carnival-internal verification. The
  draft is not a CLAP standard proposal. No DSP, no measurement code, no plugin
  implementation, no host implementation.
- It may import Odin `core:` packages and its own subpackages. It must never
  import `core/`, `adapters/`, `products/`, `verification/`, Alicorn, SDL3,
  miniaudio or a platform audio backend.
- `adapters/`, `verification/` and `products/` may import it. Verification may
  therefore share the protocol declaration with the plugin under test; it still
  must not share `core/dsp`, `adapters/` or `products/`.

Milestone 1 added the declarations from the official CLAP 1.2.10 headers, the
vendored header subset, and independent C layout/calling-convention probes.
Preserve the upstream version, commit/tag and MIT license notice with them
(`UPSTREAM.md`, `vendor/`).

Extraction into a standalone open-source package is allowed only after **both**
a real plugin (`adapters/clap`) and an independent host (`verification/`) use
it. It is a future candidate, not a current commitment.

`tools/check-boundary.ps1` enforces the `third_party` scope and the
`verification` exception for `third_party/clap`.
