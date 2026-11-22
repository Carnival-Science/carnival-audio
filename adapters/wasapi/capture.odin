// Device capture session: bounded SPSC ring, polling model, stall and
// discontinuity policy.
//
// This file is deliberately device-agnostic: `Backend` is a small proc table
// the miniaudio WASAPI loopback implementation fills in `device.odin`, and the
// tests fill in a deterministic fake. The session owns:
//
//   - a preallocated interleaved f32 ring (producer = device callback,
//     consumer = the meter intake);
//   - the delivered-frame source clock (`delivered_frames` counts frames the
//     consumer actually received — it never advances silently);
//   - an explicit stall/discontinuity policy for idle loopback endpoints;
//   - an analysis epoch that advances on stalls, endpoint switches and
//     disconnects so pre/post records cannot be mistaken for one timeline.
//
// Idle policy (the known WASAPI loopback gap)
// -------------------------------------------
// A shared-mode loopback endpoint delivers NO callbacks while the endpoint is
// silent. Fabricating silence would invent samples that were never rendered
// and would make the source clock lie. Instead, if no frames arrive for
// `idle_threshold_ns`, `session_poll` reports `Idle` with `discontinuity = true`
// once, advances the session epoch, and leaves the clock alone. When delivery
// resumes the consumer is told the timeline broke and can start a new analysis
// epoch; the wall-clock duration of the silence is intentionally not converted
// to frames.
//
// Recovery
// --------
// On `Backend.lost` (endpoint switch, device removal, backend stop) the session
// stops and reopens the device, clears the ring, advances the epoch and reports
// `Recovered`/`Device_Lost` with `discontinuity = true`. If reopening fails the
// session stays `Lost` and every poll reports it; the consumer must show an
// explicit unavailable state, never a valid reading.
package wasapi

import "core:mem"
import "core:sync"
import "core:time"

DEFAULT_RING_SECONDS :: 2.0
DEFAULT_IDLE_THRESHOLD_NS :: i64(200 * time.Millisecond)

Capture_Ring :: struct {
	samples:         []f32,
	capacity_frames: int,
	channels:        int,
	write:           u64, // atomic; total frames appended by the producer
	read:            u64, // atomic; total frames consumed
	dropped:         u64, // atomic; frames rejected because the ring was full
}

ring_init :: proc(ring: ^Capture_Ring, capacity_frames, channels: int, allocator := context.allocator) -> bool {
	if ring == nil || capacity_frames < 1 || channels < 1 {
		return false
	}
	bytes, err := mem.alloc_bytes(capacity_frames * channels * size_of(f32), align_of(f32), allocator)
	if err != .None || bytes == nil {
		return false
	}
	ring^ = Capture_Ring{
		samples = mem.slice_data_cast([]f32, bytes),
		capacity_frames = capacity_frames,
		channels = channels,
	}
	return true
}

ring_destroy :: proc(ring: ^Capture_Ring, allocator := context.allocator) {
	if ring == nil {
		return
	}
	if ring.samples != nil {
		mem.free(raw_data(ring.samples), allocator)
	}
	ring^ = {}
}

ring_available :: proc(ring: ^Capture_Ring) -> int {
	write := sync.atomic_load_explicit(&ring.write, .Acquire)
	read := sync.atomic_load_explicit(&ring.read, .Acquire)
	return int(write - read)
}

ring_dropped :: proc(ring: ^Capture_Ring) -> u64 {
	return sync.atomic_load_explicit(&ring.dropped, .Acquire)
}

// ring_write is the producer side (device callback thread). It copies whole
// frames only, never allocates and never blocks. A full ring drops the newest
// block rather than overwriting unread audio.
ring_write :: proc(ring: ^Capture_Ring, interleaved: []f32, frames: int) -> int {
	if ring == nil || frames <= 0 || len(interleaved) < frames * ring.channels {
		return 0
	}
	write := sync.atomic_load_explicit(&ring.write, .Relaxed)
	read := sync.atomic_load_explicit(&ring.read, .Acquire)
	if write - read >= u64(ring.capacity_frames) {
		sync.atomic_add_explicit(&ring.dropped, u64(frames), .Relaxed)
		return 0
	}
	available := int(u64(ring.capacity_frames) - (write - read))
	if frames > available {
		sync.atomic_add_explicit(&ring.dropped, u64(frames), .Relaxed)
		return 0
	}
	start := int(write % u64(ring.capacity_frames))
	first := min(frames, ring.capacity_frames - start)
	copy(ring.samples[start * ring.channels:(start + first) * ring.channels],
		interleaved[:first * ring.channels])
	if first < frames {
		remaining := frames - first
		copy(ring.samples[:remaining * ring.channels],
			interleaved[first * ring.channels:frames * ring.channels])
	}
	sync.atomic_store_explicit(&ring.write, write + u64(frames), .Release)
	return frames
}

// ring_read is the consumer side. It copies at most max_frames whole frames and
// advances the read cursor only after the copy.
ring_read :: proc(ring: ^Capture_Ring, destination: []f32, max_frames: int) -> int {
	if ring == nil || max_frames <= 0 {
		return 0
	}
	write := sync.atomic_load_explicit(&ring.write, .Acquire)
	read := sync.atomic_load_explicit(&ring.read, .Relaxed)
	available := int(write - read)
	frames := min(available, max_frames)
	if frames <= 0 {
		return 0
	}
	start := int(read % u64(ring.capacity_frames))
	first := min(frames, ring.capacity_frames - start)
	copy(destination[:first * ring.channels], ring.samples[start * ring.channels:(start + first) * ring.channels])
	if first < frames {
		remaining := frames - first
		copy(destination[first * ring.channels:frames * ring.channels],
			ring.samples[:remaining * ring.channels])
	}
	sync.atomic_store_explicit(&ring.read, read + u64(frames), .Release)
	return frames
}

// ring_reset is valid only while the producer is stopped (session start, stop,
// loss or recovery).
ring_reset :: proc(ring: ^Capture_Ring) {
	if ring == nil {
		return
	}
	sync.atomic_store_explicit(&ring.write, 0, .Release)
	sync.atomic_store_explicit(&ring.read, 0, .Release)
	sync.atomic_store_explicit(&ring.dropped, 0, .Release)
}

// ---------------------------------------------------------------------------
// Device backend seam
// ---------------------------------------------------------------------------

Device_Config :: struct {
	sample_rate:     u32, // 0 = backend default
	channels:        u32, // 2 for Pulse
	period_frames:   u32, // 0 = backend default
	include_process: u32, // loopback process filter; 0 = every process
}

Device_Info :: struct {
	sample_rate: u32,
	channels:    u32,
	loopback:    bool,
}

Backend :: struct {
	ctx:   rawptr,
	open:  proc(ctx: rawptr, ring: ^Capture_Ring, config: Device_Config, info: ^Device_Info) -> bool,
	start: proc(ctx: rawptr) -> bool,
	stop:  proc(ctx: rawptr),
	close: proc(ctx: rawptr),
	lost:  proc(ctx: rawptr) -> bool,
}

Session_State :: enum u8 {
	Closed,
	Running,
	Lost,
	Stopped,
}

Poll_Reason :: enum u8 {
	Data,
	Idle,
	Device_Lost,
	Recovered,
	Closed,
}

Poll_Result :: struct {
	frames:         int,
	reason:         Poll_Reason,
	discontinuity:  bool,
	dropped_frames: u64,
}

Session :: struct {
	allocator:         mem.Allocator,
	ring:              Capture_Ring,
	backend:           Backend,
	config:            Device_Config,
	info:              Device_Info,
	state:             Session_State,
	epoch:             u64,
	delivered_frames:  u64,
	idle_threshold_ns: i64,
	last_data_ns:      i64,
	stalled:           bool,
	open_attempts:     u64,
	recoveries:        u64,
}

session_open :: proc(
	session: ^Session,
	backend: Backend,
	config: Device_Config,
	capacity_frames: int = 0,
	allocator := context.allocator,
) -> bool {
	if session == nil || backend.open == nil || backend.start == nil ||
		backend.stop == nil || backend.close == nil || backend.lost == nil {
		return false
	}
	session^ = Session{
		allocator = allocator,
		backend = backend,
		config = config,
		state = Session_State.Closed,
		epoch = 1,
		idle_threshold_ns = DEFAULT_IDLE_THRESHOLD_NS,
	}
	frames := capacity_frames
	if frames <= 0 {
		rate := int(config.sample_rate)
		if rate <= 0 {
			rate = 48000
		}
		frames = int(f64(rate) * DEFAULT_RING_SECONDS)
	}
	if !ring_init(&session.ring, frames, int(config.channels), allocator) {
		return false
	}
	if !backend.open(backend.ctx, &session.ring, config, &session.info) {
		// The backend may have initialized a context before failing (for
		// example a platform without loopback support). Let it release.
		backend.close(backend.ctx)
		ring_destroy(&session.ring, allocator)
		return false
	}
	session.open_attempts = 1
	session.state = Session_State.Stopped
	return true
}

session_start :: proc(session: ^Session, now_ns: i64 = -1) -> bool {
	if session == nil || session.state == Session_State.Closed {
		return false
	}
	if session.state == Session_State.Running {
		return true
	}
	ring_reset(&session.ring)
	if !session.backend.start(session.backend.ctx) {
		session.state = Session_State.Lost
		return false
	}
	session.state = Session_State.Running
	session.stalled = false
	session.last_data_ns = resolve_now(now_ns)
	return true
}

session_stop :: proc(session: ^Session) {
	if session == nil || session.state == Session_State.Closed {
		return
	}
	session.backend.stop(session.backend.ctx)
	session.state = Session_State.Stopped
	session.stalled = false
}

session_close :: proc(session: ^Session) {
	if session == nil {
		return
	}
	if session.state == Session_State.Running {
		session.backend.stop(session.backend.ctx)
	}
	if session.state != Session_State.Closed {
		session.backend.close(session.backend.ctx)
	}
	ring_destroy(&session.ring, session.allocator)
	session.state = Session_State.Closed
}

resolve_now :: proc(now_ns: i64) -> i64 {
	if now_ns >= 0 {
		return now_ns
	}
	return time.duration_nanoseconds(time.tick_since({}))
}

// session_poll drains delivered frames into `destination` (interleaved) and
// reports the timeline. Pass `now_ns` only in deterministic tests; the default
// reads the monotonic clock.
session_poll :: proc(
	session: ^Session,
	destination: []f32,
	max_frames: int,
	now_ns: i64 = -1,
) -> Poll_Result {
	if session == nil || session.state == Session_State.Closed {
		return Poll_Result{reason = .Closed}
	}
	now := resolve_now(now_ns)
	if session.state == Session_State.Running && session.backend.lost(session.backend.ctx) {
		// Endpoint switch, removal or backend stop. Tear the device down and
		// try one reopen. The ring is cleared: audio from before the switch does
		// not belong to the new endpoint's timeline.
		session.backend.stop(session.backend.ctx)
		session.backend.close(session.backend.ctx)
		session.state = Session_State.Lost
		session.stalled = false
		session.epoch += 1
		ring_reset(&session.ring)
		session.open_attempts += 1
		reopened := session.backend.open(session.backend.ctx, &session.ring, session.config, &session.info) &&
			session.backend.start(session.backend.ctx)
		if reopened {
			session.state = Session_State.Running
			session.recoveries += 1
			session.last_data_ns = now
			return Poll_Result{reason = .Recovered, discontinuity = true}
		}
		return Poll_Result{reason = .Device_Lost, discontinuity = true}
	}
	if session.state == Session_State.Lost {
		// Retry the endpoint on every poll: devices come back (docking,
		// headphone switch, driver restart) and the consumer should see the
		// explicit recovery rather than a permanently stale meter.
		session.backend.close(session.backend.ctx)
		session.open_attempts += 1
		ring_reset(&session.ring)
		if session.backend.open(session.backend.ctx, &session.ring, session.config, &session.info) &&
			session.backend.start(session.backend.ctx) {
			session.state = Session_State.Running
			session.recoveries += 1
			session.stalled = false
			session.last_data_ns = now
			return Poll_Result{reason = .Recovered, discontinuity = true}
		}
		return Poll_Result{reason = .Device_Lost}
	}
	if session.state != Session_State.Running {
		return Poll_Result{reason = .Closed}
	}

	frames := ring_read(&session.ring, destination, max_frames)
	dropped := ring_dropped(&session.ring)
	if frames > 0 {
		resumed := session.stalled
		session.stalled = false
		session.last_data_ns = now
		session.delivered_frames += u64(frames)
		return Poll_Result{
			frames = frames,
			reason = .Data,
			discontinuity = resumed,
			dropped_frames = dropped,
		}
	}
	if !session.stalled && now - session.last_data_ns >= session.idle_threshold_ns {
		// No data arrived for the threshold. Do not advance the clock and do not
		// inject silence: report one explicit timeline break.
		session.stalled = true
		session.epoch += 1
		return Poll_Result{reason = .Idle, discontinuity = true, dropped_frames = dropped}
	}
	return Poll_Result{reason = .Idle, dropped_frames = dropped}
}
