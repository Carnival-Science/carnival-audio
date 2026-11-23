# Pulse Mini: standalone meter (M3.1)

`products/pulse-mini` is the first standalone consumer of `core/meter`:

```
WASAPI shared-mode loopback (adapters/wasapi)
    -> bounded SPSC capture ring
    -> meter.Engine (variable blocks, delivered-frame clock, explicit gaps)
    -> revisioned Measurement_Snapshot
    -> console lines at an independent print cadence
```

It is headless and console-only at this gate. The Alicorn UI, hidden/idle work
elision and presentation profiling are M3.2 concerns.

## Build and run

```powershell
.\tools\build.ps1                 # also writes out\pulse-mini.exe
.\out\pulse-mini.exe --input=loopback
.\out\pulse-mini.exe --input=loopback --duration=5 --print-cadence=10
.\out\pulse-mini.exe --input=loopback --duration=2 --print-cadence=4 --self-loop
```

| Flag | Meaning |
| --- | --- |
| `--input=loopback` | required; shared-mode loopback on the default render endpoint |
| `--duration=N` | seconds to run (default 5; `0` runs until the process is stopped) |
| `--print-cadence=Hz` | snapshot print rate (default 10); independent of analysis |
| `--window=FRAMES` | RMS window (default 1024) |
| `--self-loop` | also render a 400 Hz, amplitude 0.5 sine so the loopback has a known signal |

Each line reports `frm` (delivered source frames), the analysis epoch, and four
per-channel values in dBFS: `win` (last completed window peak), `hold` (the
hold/decay envelope), `max` (session maximum since the epoch began) and `rms`.
It also prints `valid` / `INVALID`, an audio-discontinuity marker and, while a
device is lost, `(device unavailable)`. `win`, `hold` and `max` are distinct:
the first two fall with the input, the third keeps the epoch's maximum.

## What "no data" means

A shared-mode loopback endpoint emits **no callbacks while it is silent**. Pulse
Mini does not invent silence:

- before the stall threshold it prints `INVALID` (nothing measured);
- when the threshold is crossed it prints
  `stalled (no loopback data; source clock does not advance)` and starts a new
  analysis epoch;
- when data resumes it prints a timeline discontinuity and continues. The
  silence duration is not converted to frames.

If the capture ring overruns, the frames the producer dropped are reported as a
`dropped_delta` range. Pulse Mini pushes the delivered block that precedes the
loss, then calls `engine_note_discontinuity` with the dropped frame count. The
affected boundary window is invalid, the next contiguous window is valid again,
and no manual reset is involved. Device loss is treated the same way
immediately: the engine publishes an invalid snapshot and pulse-mini prints
`(device unavailable)` until recovery starts a new epoch and fresh data
arrives.

## Self-loop measurement (development machine)

`--self-loop` plays 400 Hz at amplitude 0.5 (nominal −6.02 dBFS peak, −9.03
dBFS RMS). A 1.2 s run produced:

```
pulse-mini: loopback 48000 Hz, window 1024 frames, print 4.0 Hz, duration 1.2s, self-loop tone 400 Hz
t=  0.26s frm=12000     epoch=1 L[win -6.0 hold -6.0 max -6.0 rms -9.0 dBFS] ...
t=  1.01s frm=48000     epoch=1 L[win -6.0 hold -6.0 max -6.0 rms -9.0 dBFS] ...
pulse-mini: done: 57120 frames (1.190s), epoch 1, 0 stall break(s), 0 recover(ies), 0 overrun(s), 0 dropped, session max -6.0/-6.0 dBFS, final valid
```

The packaged self-loop test (adapters/wasapi) is stricter: it discards the
pre-playback silence, resets the engine, captures 24,000 frames, and compares
the engine snapshot with closed form:

| Measure | Expected | Observed | Deviation |
| --- | --- | --- | --- |
| sample peak | 0.5 | 0.500004 | **+0.001%** |
| RMS | 0.5/√2 = 0.353553 | 0.353555 | **+0.001%** |

### Tolerance rationale

The test asserts **1% level accuracy**, not bit equality. Shared-mode loopback
is not bit-transparent: the endpoint mix includes other processes, the audio
engine may convert sample formats and resample between the endpoint rate and
48 kHz, and miniaudio's playback/loopback pair is not guaranteed sample-aligned.
1% (≈ 0.086 dB) is comfortably above those level-preserving operations while
still tight enough to catch a missing channel, a 2× gain or a −6 dB error. The
observed +0.001% is endpoint-specific evidence on the development machine, not a
universal bound.

## Boundedness

The capture ring is preallocated at session open (2 s at the requested rate).
`ring_write`, `ring_read` and `engine_push_interleaved` perform no allocation;
a tracking-allocator test asserts zero allocations across 32 block round trips.
A full ring drops the newest block and counts the dropped frames; it never
wraps over unread audio.

## Limits

- Windows x64 (WASAPI) for loopback; the package compiles elsewhere and the
  test skips when the session has no loopback-capable endpoint.
- One stereo stream, one default render endpoint, no device picker.
- Console output only; no Alicorn UI at this gate.
- Live capture episode switching while audio runs is not implemented (capture
  episodes require quiescent processing).
