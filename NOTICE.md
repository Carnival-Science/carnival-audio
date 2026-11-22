# Third-party notices for carnival-audio

- **CLAP** (Milestone 1): MIT — https://github.com/free-audio/clap
  Headers pinned at tag 1.2.10, commit `195b42a004144fab0b3cf95e9c067187d15365b7`;
  vendored header subset and checksums in `third_party/clap/vendor/`.
- **clap-validator** (external tool, Milestone 1): MIT — pinned by commit,
  invoked in CI/evidence runs, never linked into Pulse artifacts.
- **clap-trap** (external tool): MIT — https://github.com/dfl/clap-trap,
  pinned by commit, never linked into Pulse artifacts.
- **clap-info** (external tool): MIT — pinned by commit, never linked into
  Pulse artifacts.
- **pluginval** (reference only): GPL-3.0 — external CI binary only; never
  linked, embedded, or redistributed with Pulse. CLAP coverage comes from
  clap-validator and clap-trap instead.
- **miniaudio** (Milestone 3 capture): public domain (Unlicense) or MIT No
  Attribution, at the user's choice �?" https://github.com/mackron/miniaudio.
  Version 0.11.26; the single-file header is vendored (verbatim, with its
  license statement) in `third_party/miniaudio/`, provenance and SHA-256 in
  `third_party/miniaudio/UPSTREAM.md`.
- **FFTW**: GPL — deliberately NOT used anywhere in Pulse. The analysis FFT is
  implemented in pure Odin; independent verification uses external offline
  references (e.g. numpy) that are never distributed with Pulse.
