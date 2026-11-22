# AGENTS.md — third_party/clap

`third_party/clap` is **neutral CLAP ABI surface**, not an implementation.

- It holds foreign declarations for the official CLAP headers only. No DSP, no
  measurement code, no plugin implementation, no host implementation.
- It may import Odin `core:` packages and its own subpackages. It must never
  import `core/`, `adapters/`, `products/`, `verification/`, Alicorn, SDL3,
  miniaudio or a platform audio backend.
- `adapters/`, `verification/` and `products/` may import it. Verification may
  therefore share the protocol declaration with the plugin under test; it still
  must not share `core/dsp`, `adapters/` or `products/`.

Milestone 1 adds the declarations from the official CLAP headers. Preserve the
upstream version, commit/tag and MIT license notice with them.

Extraction into a standalone open-source package is allowed only after **both**
a real plugin (`adapters/clap`) and an independent host (`verification/`) use
it. It is a future candidate, not a current commitment.

`tools/check-boundary.ps1` enforces the `third_party` scope and the
`verification` exception for `third_party/clap`.
