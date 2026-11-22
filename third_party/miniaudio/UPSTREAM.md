# third_party/miniaudio

Vendored copy of **miniaudio 0.11.26**, the single-file C audio library used by
`adapters/wasapi` for shared-mode WASAPI loopback capture and the self-loop
verification tone.

## Provenance

| Item | Value |
| --- | --- |
| Upstream | https://github.com/mackron/miniaudio |
| Version | `0.11.26` (`MA_VERSION_MAJOR/MINOR/REVISION = 0/11/26`) |
| File | `miniaudio.h`, copied verbatim from the Odin `dev-2026-11-nightly:08539cd` installation (`vendor/miniaudio/src/miniaudio.h`) |
| SHA-256 | `5b325f7d1a6fd72f94294963a441e2442887bc43f63df796a12c4a75f38b22c6` |
| Size | 4,258,867 bytes |
| License | Public domain (Unlicense) or MIT No Attribution, at the user's choice; the full dual statement is at the top of `miniaudio.h` |

## Why vendored

The repository's builds stay self-contained and the exact implementation that
was verified is pinned with a hash. `miniaudio.h` is public domain and
single-file, so vendoring is the whole dependency.

The Odin bindings (`vendor:miniaudio`, version-checked against the same
`0.11.26`) provide the declarations and link the Odin distribution's build of
this header. The vendored header is the provenance/audit copy: an
`adapters/`-local static library built from it is a possible later change, but
this milestone uses the compiler-shipped library of the identical version and
fails its own `@(init)` version check on any mismatch.

## Boundary

`adapters/wasapi` may import `vendor:miniaudio`. **`core/` must not**, and
neither may `third_party/clap`. `tools/check-boundary.ps1` allows miniaudio in
`adapters/` only (SDL/Alicorn and other UI/audio backends stay forbidden).
