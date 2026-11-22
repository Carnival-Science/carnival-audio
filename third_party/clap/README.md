# third_party/clap — neutral CLAP ABI package

This directory is the neutral home for **CLAP protocol declarations**: foreign
bindings for the official CLAP C headers (`clap/clap.h` and its entries), not a
CLAP implementation, adapter or DSP library.

Status: **implemented for Milestone 1.** The package declares CLAP 1.2.10
(`third_party/clap/abi`) and vendors the exact MIT header subset used to prove
those declarations (`vendor/`, provenance in `UPSTREAM.md`). The C layout and
calling-convention probes live in `tools/abi/`; tests in `abi/abi_test.odin`
and `abi/cc_test.odin` fail if the C headers and Odin declarations disagree.

## Why a neutral package

Both sides of the host/plugin boundary need the same protocol declaration:

- `adapters/clap` implements a plugin and must speak the ABI;
- `verification/` drives a plugin as an independent host and must speak the same
  ABI;
- `products/` may need CLAP-facing surface later.

Declarations are pure ABI. Sharing them cannot make verification agree with the
implementation it is testing. Sharing the DSP used to compute expected
measurements *would*, so that remains forbidden.

## Import rules

Allowed consumers: `adapters/`, `verification/`, `products/`.

This package itself must remain neutral:

- it may import Odin `core:` packages and its own subpackages only;
- it must not import `core/`, `adapters/`, `products/`, `verification/`,
  Alicorn, SDL3, miniaudio or a platform audio backend;
- it contains no measurement, analysis, FFT, window, filter or metering code.

`tools/check-boundary.ps1` enforces the `third_party` scope and the
`verification` exception for `third_party/clap`.

## Provenance and licensing

CLAP 1.2.10 headers are vendored under `vendor/` (MIT; tag and commit in
`UPSTREAM.md`, per-file SHA-256 in `vendor/VENDORED.sha256`). The Odin
declarations are hand-written against that subset. Do not hand-edit ABI layouts
without recording the source, and rerun the C layout/calling-convention probes
under `tools/abi/`.

## Future extraction

This is the intended candidate for a small standalone, open-source CLAP ABI
package. It must **not** be extracted just because it exists: extract it only
after it has been exercised by **both** a real plugin (`adapters/clap`) and an
independent host (`verification/`). Until then it stays inside this repository
so the ABI can move with its first two consumers.
