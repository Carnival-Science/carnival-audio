# Pulse Mini: standalone meter (M3.2a)

`products/pulse-mini` is the first graphical Carnival product. Its default
presentation is a small native Alicorn window; `--headless` keeps the original
M3.1 console meter and its output.

```
WASAPI shared-mode loopback (adapters/wasapi)
    -> bounded SPSC capture ring
    -> meter.Engine (variable blocks, delivered-frame clock, explicit gaps)
    -> revisioned Measurement_Snapshot (schema 2, seqlock)
    -> console lines at a print cadence                      (--headless)
    -> presentation mapping -> Alicorn description          (default)
```

## Build and run

Alicorn is a **separate repository** (`Carnival-Science/Alicorn`); this
repository does not vendor it. The graphical product therefore builds with an
`alicorn` collection:

```powershell
# Resolves -AlicornRoot, PULSE_ALICORN_ROOT, then ..\alicorn
.\tools\pulse-mini.ps1 -AlicornRoot C:\Users\saman\dev\alicorn

.\out\pulse-mini.exe --self-loop
.\out\pulse-mini.exe --self-loop --duration=10
.\out\pulse-mini.exe --headless --input=loopback --self-loop --duration=2
```

`tools/build.ps1` builds the graphical product when it can resolve an Alicorn
checkout and prints a skip notice otherwise, so the headless CI path is
unaffected. `tools/test.ps1` runs the pure `products/pulse-mini/presentation`
package without Alicorn.

### Alicorn pin

The window options used here (`Application.always_on_top` and
`Application.on_renderable_changed`) were added on Alicorn branch
`pulse-mini-host-options`. The product was developed against:

| Repository | Revision |
| --- | --- |
| carnival-audio | this milestone's commit |
| Alicorn | `92cb620` (`feat(host): generic always-on-top and renderable transitions`) |

A newer Alicorn master containing that commit is also fine. The build script
checks for both symbols and fails with the pin instead of silently accepting a
stale checkout.

| Flag | Meaning |
| --- | --- |
| `--input=loopback` | required; shared-mode loopback on the default render endpoint |
| `--headless` | console presentation (M3.1 behavior and output) |
| `--duration=N` | seconds to run (console default 5; graphical default 0 = until closed) |
| `--print-cadence=Hz` | console snapshot print rate (default 10); ignored by the graphical window |
| `--window=FRAMES` | RMS window (default 1024) |
| `--self-loop` | also render a 400 Hz, amplitude 0.5 sine so the loopback has a known signal |
| `--always-on-top` / `--no-always-on-top` | primary-window topmost option (graphical default on) |
| `--diagnostics --capture-after=N --capture-dir=PATH` | Alicorn native-host diagnostics bundle (screenshot, JSON, timeline) |

## Threading and cadence independence

The graphical mode has exactly two relevant threads:

- **Capture worker.** Owns the WASAPI session and the meter engine. It polls
  the ring, pushes delivered blocks, notes discontinuities and lets the engine
  publish a seqlock snapshot. It wakes the UI only when the engine published a
  new generation and the window is renderable.
- **UI thread (Alicorn).** Reads the latest snapshot with `engine_snapshot` (a
  bounded lock-free read), maps it with the pure `presentation` package, and
  invalidates only when the mapped visual state changes beyond the epsilon.

Analysis therefore runs on the capture cadence; the UI runs only when a frame
would differ. The window prints and logs these independent counters:

| Counter | Meaning |
| --- | --- |
| `snapshots_published` | engine seqlock publications (one per intake block/discontinuity) |
| `snapshots_consumed` | UI snapshots offered to the presentation tracker |
| `frames` | Alicorn description/paint requests that produced content |
| `renders_skipped` | observations coalesced by the epsilon or elided while hidden |
| `hidden_wakes_suppressed` | capture publications whose UI wake was elided while hidden |
| `wakes` | host wake callbacks delivered to the UI |

The counter line inside the window is coalesced to at most one refresh per
second (so it can show live totals). Meter levels still invalidate on the
epsilon; a hidden or stalled meter has no wake to coalesce and therefore
performs zero UI work.

## Presentation contract (seed)

`products/pulse-mini/presentation` is a small, pure mapping layer:

```odin
snapshot_to_visual(snapshot, source_state) -> Visual
```

It imports only `core/transport` and performs no audio analysis. Its inputs are
the schema-2 presentation fields (`window_peak_db`, `rms_db`, `peak_hold_db`,
`session_max_db`, `valid`, `window_valid`, `overrun`, `epoch`) plus a capture
lifecycle enum (`Starting`, `Live`, `Stalled`, `Device_Lost`) that the adapter
reports separately. Its outputs are bounded visual values:

- bar fractions over the documented -60..0 dBFS display window;
- level zones/colors (silent, safe, warn, hot) derived only from published
  dBFS values;
- one explicit state: `Starting`, `Live`, `Idle`, `Disconnected` or
  `Invalid_Window`;
- the epoch and sample rate for the status line.

This is a **seed, not a standard**. It is deliberately not exported from
`core`, not versioned as an API, and will be revisited when a second graphical
product exists. What is fixed now is the direction: presentation never computes
a measurement, and `core/meter` remains Alicorn-free.

The mapping chooses states in this order:

1. `Device_Lost` -> **DISCONNECTED** (the last reading is never shown as live).
2. No publication yet -> **STARTING**.
3. Adapter stall -> **STALLED**; silence is not fabricated as a valid
   quiet reading.
4. With data flowing, `valid` -> **LIVE**.
5. Invalid completed window with `overrun` -> **INVALID GAP**: the
   boundary window after a gap/overrun, while later contiguous windows become
   valid again.

## Hidden and idle behavior

The native host calls `Application.on_renderable_changed` on primary-window
visibility transitions. Pulse Mini:

- sets its renderable word to false and stops requesting frames;
- suppresses capture wakeups while hidden (publication continues);
- on restore, forces exactly one frame from the latest snapshot and resumes.

A stalled or silent loopback endpoint delivers no callbacks, so the UI shows the
idle state and then sleeps; it does not redraw an animation. The evidence run in
`docs/benchmarks/pulse-mini-gui-2026-11-22/` records a hidden interval with zero
frames while `snapshots_published` kept increasing.

## Self-loop measurement (development machine)

`--self-loop` plays 400 Hz at amplitude 0.5 (nominal -6.02 dBFS peak, -9.03
dBFS RMS). The console output is unchanged from M3.1:

```
pulse-mini: loopback 48000 Hz, window 1024 frames, print 4.0 Hz, duration 1.2s, self-loop tone 400 Hz
t=  0.26s frm=12000     epoch=1 L[win -6.0 hold -6.0 max -6.0 rms -9.0 dBFS] ...
pulse-mini: done: 57120 frames (1.190s), epoch 1, 0 stall break(s), 0 recover(ies), 0 overrun(s), 0 dropped, session max -6.0/-6.0 dBFS, final valid
```

The packaged self-loop test (adapters/wasapi) remains stricter: it discards the
pre-playback silence, resets the engine, captures 24,000 frames, and compares
the engine snapshot with closed form (about +0.001% on this machine against a
1% tolerance).

## Boundedness

The capture ring is preallocated at session open (2 s at the requested rate).
`capture_session_poll`, `ring_write`, `ring_read` and `engine_push_interleaved`
perform no allocation or locking; the UI thread only performs seqlock reads.
The graphical snapshot and counter state is a fixed-size value; no per-frame
history is retained.

## Tests

- `products/pulse-mini/presentation`: bounded mapping tests (display range,
  zones, state selection including `Invalid_Window`/`Disconnected`, channel
  colors, epsilon coalescing, hidden elision, restore catch-up).
- `adapters/wasapi`: self-loop level and discontinuity tests (M3.1).
- `tests`: capture lifecycle end-to-end (stall, device loss, overrun recovery).
- Evidence: `docs/benchmarks/pulse-mini-gui-2026-11-22/`.

## Limits

- Windows x64 (WASAPI) for loopback; the package compiles elsewhere and the
  test skips when the session has no loopback-capable endpoint.
- One stereo stream, one default render endpoint, no device picker.
- No spectrum display, no recording, no settings persistence at this gate.
- The window's counter line is a diagnostic view of the last frame, not a
  benchmark claim; the exit log carries the authoritative totals.
- Shared-mode loopback level evidence is machine-local (M3.1 note unchanged).
