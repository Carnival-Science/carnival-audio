# Artifact retention note

This committed snapshot keeps the machine-readable evidence for both worker
runs (`runs/<specimen>/run1` and `run2`) and the WAV/CSV artifacts for:

- Pulse (the first real specimen);
- the three deliberately defective processors (the failures are the finding);
- the pinned third-party census specimen.

WAVs for the good reference processors (`gain`, `biquad`, `delay`) and all
`run2` WAVs were removed from the committed tree to keep it small. Their
SHA-256 values remain in each `evidence.json` and in `manifest.json`, and every
artifact is reproducible by rerunning:

```powershell
.\tools\run_verification.ps1
```

`cross_process_repeatability` was evaluated from those hashes before pruning;
the runner regenerates and compares them on every run.
