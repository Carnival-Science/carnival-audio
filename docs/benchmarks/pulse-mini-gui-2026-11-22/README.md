# Pulse Mini GUI evidence (M3.2a), 2026-11-22

Graphical product: `products/pulse-mini` (native Alicorn window), pinned
Alicorn `92cb620` (`feat(host): generic always-on-top and renderable
transitions`). Development machine: Windows x64, SDL3 3.4.20, Direct3D 12,
48 kHz shared-mode loopback.

## What was run

```powershell
# Live meter with the documented self-loop signal (400 Hz, amplitude 0.5).
.\out\pulse-mini.exe --self-loop --duration=8 --diagnostics `
    --capture-after=5 --capture-dir=<tmp>\pulse-gui-final-live

# Idle/stalled presentation: no tone, loopback silent. A minimize/restore is
# used only to give the event-driven app a wake after the capture deadline.
.\out\pulse-mini.exe --duration=8 --diagnostics `
    --capture-after=3 --capture-dir=<tmp>\pulse-gui-final-idle2

# Hidden-idle counters: same live run, minimized for 6 s and restored.
.\out\pulse-mini.exe --self-loop --duration=16 --diagnostics `
    --capture-after=12 --capture-dir=<tmp>\pulse-gui-final-hidden
```

The hidden run found the real SDL window by enumerating visible top-level
windows whose title is `Pulse Mini` (`EnumWindows` / `GetWindowTextW`), then
called `ShowWindowAsync(hwnd, SW_MINIMIZE)` and `SW_RESTORE`. A process
`MainWindowHandle` was not reliable here because SDL owns more than one window.

The diagnostics screenshot is the Alicorn native-host capture
(`alicorn_diagnostics screenshot .../screenshot.ppm`, written for a native app).
PPM was converted to PNG for the repository; no other pixels were changed.

## Screenshots

| File | What it shows |
| --- | --- |
| `live-self-loop.png` | 560x460 live window, both channels at `PEAK ≈ HOLD ≈ MAX −6.0 dBFS`, `RMS −9.0 dBFS`, green `LIVE` badge, epoch 1, 48.0 kHz, window 1024 |
| `idle-stalled.png` | same window with no tone and no loopback data: gray `STALLED` badge, empty bars, `-- dBFS`, no fabricated reading |

`windows-live.json` is the host's primary-window diagnostics record from the
live run. It reports `"always_on_top": true` and the expected 560x460 logical
size, which is the always-on-top check for the native host option added in
Alicorn `92cb620`.

## Counters

### Live run (8 s)

```
pulse-mini: gui counters: snapshots_published=819 snapshots_consumed=785
  frames=10 renders_skipped=783 hidden_wakes_suppressed=0 wakes=785
  epoch=1 elapsed_ms=8381 final_state=LIVE
```

The window rebuilt 10 times for 785 consumed snapshots. The steady 400 Hz tone
is inside the 0.25% (0.15 dB) presentation epsilon; the only rebuilds are the
initial frame, state transitions and the once-per-second diagnostic counter
line.

### Hidden-idle run

```
pulse-mini: window hidden at 2484ms: frames=6 published=237 consumed=220 hidden_wakes_suppressed=0
pulse-mini: window visible at 8432ms: frames=6 published=832 consumed=238 hidden_wakes_suppressed=595
pulse-mini: gui counters: snapshots_published=1599 snapshots_consumed=995
  frames=15 renders_skipped=991 hidden_wakes_suppressed=595 wakes=994
  epoch=1 elapsed_ms=16143 final_state=LIVE
```

During the ~5.9 s hidden interval:

- engine publications advanced `237 -> 832` (capture and analysis continued);
- the frame count stayed at `6` (zero UI frames while hidden);
- `hidden_wakes_suppressed=595` records the capture wakeups that were elided;
- restoring forced one frame from the latest snapshot and left the window live.

### Idle run

```
pulse-mini: window hidden at 4091ms: frames=2 published=1 consumed=1 hidden_wakes_suppressed=0
pulse-mini: window visible at 4498ms: frames=2 published=1 consumed=2 hidden_wakes_suppressed=0
pulse-mini: gui counters: snapshots_published=1 snapshots_consumed=2 frames=3
  renders_skipped=0 hidden_wakes_suppressed=0 wakes=1 epoch=2 elapsed_ms=8150 final_state=STALLED
```

With no loopback callbacks the engine published one explicit discontinuity
snapshot and then the app slept. There is no animation loop and no repeated
invalidation while stalled; the forced frame at restore is the only extra
description.

### Counter display caveat

The counter line inside the window is the last frame's view and is coalesced to
at most 1 Hz. The authoritative cumulative totals are in the process exit log
(the `pulse-mini: gui counters:` line). Screenshots therefore show the values of
the frame that produced them, not the final totals.

## Bounded tests (laboratory)

`products/pulse-mini/presentation` (8 tests, no Alicorn dependency) covers:

- the `-60..0 dBFS` display mapping, including NaN/±inf and clamping;
- zone boundaries (`Silent`, `Safe`, `Warn`, `Hot`) and colors;
- every state selection order: `Starting`, `Live`, `Stalled`, `Disconnected`,
  `Invalid_Window` (gap/overrun);
- epsilon coalescing (0.1 dB coalesced, 0.2 dB rebuilt);
- hidden elision with continuous publication, and one forced frame on restore.

Run from the repository root:

```powershell
& C:\odin\odin.exe test products\pulse-mini\presentation -collection:carnival=.
```

## Limits

- Shared-mode loopback is not bit-transparent; the levels above are the
  documented 400 Hz self-loop signal, not a calibrated reference.
- The hidden interval was induced with the OS minimize operation on the real
  window. Occlusion follows the same host predicate but was not separately
  captured here.
- The graphical product requires the separate Alicorn checkout and its pin; see
  `docs/pulse-mini.md`.
