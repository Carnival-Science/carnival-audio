# Preserved Milestone 1 plugin artifact

This directory keeps the **exact** plugin binary that the Milestone 1 external
validation was run against. Odin DLL builds are not byte-reproducible, so the
binary — not a recipe — is the historical artifact. Do not replace, rebuild over
or strip it. Later migration research compares behaviour against this file.

| Item | Value |
| --- | --- |
| File | `pulse-meter-m1.clap` |
| Plugin ID | `com.carnival-science.pulse.meter` |
| Size | 608,768 bytes |
| SHA-256 | `cbc7b516210257519bb05787f32d5a6e70c51b470bf037b0e71b73a3eea5afd7` |
| Source revision | `14041ad` (`ci: record hosted-runner billing block in workflow and validation notes`), clean working tree |
| Source tree | `github.com/Carnival-Science/carnival-audio` at `master` = `14041ad` |
| Artifact role | Milestone 1 validated Windows x64 CLAP DLL (`.clap`) |

The recorded SHA-256 in `../plugin.sha256` and in `../README.md` is the same
hash; it was re-verified after copying this file.

## Build environment

| Tool | Version |
| --- | --- |
| OS | Windows 11 x64 (10.0.19045) |
| Odin | `dev-2026-11-nightly:08539cd` (`C:\odin\odin.exe`) |
| MSVC | 19.51.36248.0 |
| CMake | 4.4.4 |
| rustc / cargo | 1.98.1 |

Build command (run from the repository root at `14041ad`):

```powershell
C:\odin\odin.exe build products/pulse -collection:carnival=C:\Users\saman\dev\pulse `
  -build-mode:dll -define:PULSE_PLUGIN_BUILD=true -out:out\pulse.clap -o:minimal
```

`dumpbin /exports` on the validated file reported exactly one export,
`clap_entry` (ordinal 1, RVA 0x89A40).

## Reproducibility warning

Two consecutive builds of the same source at the same commit produced different
PE bytes (same size and behaviour; PE timestamps differ). This file therefore
identifies one observed artifact, not a reproducible-build guarantee. See
`../README.md` and `docs/architecture.md` ("Reproducible plugin artifacts
unproven").

## Provenance and licensing

The binary is a build of this repository's own source (MIT, see the repository
`LICENSE`); it contains no third-party plugin code. It is committed solely so
that the validated artifact remains available for verification research. It is
not a released product binary.
