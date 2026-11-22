# Third-party notices for Pulse

- **CLAP** (planned, Milestone 1): MIT — https://github.com/free-audio/clap
  Headers/bindings pinned at the official repository; ABI 1.2.x.
- **clap-validator** (external tool, Milestone 1): MIT — pinned by commit,
  invoked in CI, never linked into Pulse artifacts.
- **clap-trap / clap-info** (external tools): MIT — same policy.
- **pluginval** (reference only): GPL-3.0 — external CI binary only; never
  linked, embedded, or redistributed with Pulse. CLAP coverage comes from
  clap-validator and clap-trap instead.
- **miniaudio** (planned, standalone capture): public domain.
- **FFTW**: GPL — deliberately NOT used anywhere in Pulse. The analysis FFT is
  implemented in pure Odin; independent verification uses external offline
  references (e.g. numpy) that are never distributed with Pulse.
