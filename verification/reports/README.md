# Verification reports

Each timestamped directory is one local laboratory run: `manifest.json`
(environment, tool/plugin/scenario hashes, limitations), `census.json` and
`census.csv` (probe table with class labels and expected/unexpected
classification), `report.md` (human report) and `runs/<specimen>/run<N>/` raw
evidence, WAVs and canonical records.

Regenerate with:

```powershell
.\tools\run_verification.ps1
```

Committed snapshots may prune reproducible WAVs for passing specimens to keep
the repository small; their hashes remain in evidence and the manifest. See the
per-run `ARTIFACTS.md` note.

Reports are observations on the named machine/date, not universal guarantees.
CI is billing-blocked, so current evidence is local Windows x64.
