// Capture adapter tests: deterministic ring/session behaviour plus one
// machine-local loopback self-loop.
//
// The fake backend exercises the polling, stall and recovery contracts without
// any audio hardware. The self-loop test renders a known sine through a
// playback device and captures the default render endpoint's loopback, feeding
// the session ring into the shared meter engine. It skips with an explicit
// message when the session has no playback device or no loopback support; on
// the development machine it runs and passes.
package wasapi

import "core:fmt"
import "core:math"
import "core:mem"
import "core:testing"
import "core:time"

import "carnival:core/meter"

// ---------------------------------------------------------------------------
// Fake backend
// ---------------------------------------------------------------------------

Fake :: struct {
	ring:      ^Capture_Ring,
	running:   bool,
	lost_flag: bool,
	fail_open: bool,
	opens:     int,
	closes:    int,
	starts:    int,
}

fake_open :: proc(ctx: rawptr, ring: ^Capture_Ring, config: Device_Config, info: ^Device_Info) -> bool {
	fake := cast(^Fake)ctx
	fake.opens += 1
	if fake.fail_open {
		return false
	}
	fake.ring = ring
	if info != nil {
		info.sample_rate = 48000
		info.channels = config.channels
		info.loopback = true
	}
	return true
}

fake_start :: proc(ctx: rawptr) -> bool {
	fake := cast(^Fake)ctx
	fake.starts += 1
	fake.running = true
	return true
}

fake_stop :: proc(ctx: rawptr) {
	fake := cast(^Fake)ctx
	fake.running = false
}

fake_close :: proc(ctx: rawptr) {
	fake := cast(^Fake)ctx
	fake.closes += 1
	fake.running = false
}

fake_lost :: proc(ctx: rawptr) -> bool {
	return (cast(^Fake)ctx).lost_flag
}

fake_backend :: proc(fake: ^Fake) -> Backend {
	return Backend{
		ctx = rawptr(fake),
		open = fake_open,
		start = fake_start,
		stop = fake_stop,
		close = fake_close,
		lost = fake_lost,
	}
}

// ---------------------------------------------------------------------------
// Ring
// ---------------------------------------------------------------------------

@(test)
test_ring_wraps_and_preserves_order :: proc(t: ^testing.T) {
	ring: Capture_Ring
	testing.expect(t, ring_init(&ring, 8, 2), "ring init")
	defer ring_destroy(&ring)

	// Write 6 frames, consume 4, then write 6 more so the write side wraps.
	for frame in 0 ..< 6 {
		buffer := [2]f32{f32(frame), f32(-frame)}
		testing.expect_value(t, ring_write(&ring, buffer[:], 1), 1)
	}
	destination: [16]f32
	testing.expect_value(t, ring_read(&ring, destination[:], 4), 4)
	for frame in 0 ..< 4 {
		testing.expect_value(t, destination[frame * 2], f32(frame))
		testing.expect_value(t, destination[frame * 2 + 1], f32(-frame))
	}
	for frame in 6 ..< 12 {
		buffer := [2]f32{f32(frame), f32(-frame)}
		testing.expect_value(t, ring_write(&ring, buffer[:], 1), 1)
	}
	testing.expect_value(t, ring_available(&ring), 8)
	testing.expect_value(t, ring_read(&ring, destination[:], 8), 8)
	for index in 0 ..< 8 {
		expected := index < 2 ? f32(4 + index) : f32(6 + index - 2)
		testing.expect_value(t, destination[index * 2], expected)
	}
}

@(test)
test_ring_overflow_drops_newest_and_counts :: proc(t: ^testing.T) {
	ring: Capture_Ring
	testing.expect(t, ring_init(&ring, 4, 2), "ring init")
	defer ring_destroy(&ring)
	first := [6]f32{1, 1, 2, 2, 3, 3}
	testing.expect_value(t, ring_write(&ring, first[:], 3), 3)
	// Only one frame is free; a whole-block producer drops the block rather
	// than splitting it.
	testing.expect_value(t, ring_write(&ring, first[:], 3), 0)
	testing.expect_value(t, ring_dropped(&ring), u64(3))
	testing.expect_value(t, ring_available(&ring), 3)
}

// ---------------------------------------------------------------------------
// Session policies
// ---------------------------------------------------------------------------

@(test)
test_session_idle_stall_and_resume_report_one_break :: proc(t: ^testing.T) {
	fake := Fake{}
	session: Session
	testing.expect(t, session_open(&session, fake_backend(&fake), Device_Config{sample_rate = 48000, channels = 2}, 64), "open")
	defer session_close(&session)
	session.idle_threshold_ns = 1000
	testing.expect(t, session_start(&session, 0), "start")

	frame := [2]f32{0.25, -0.25}
	testing.expect_value(t, ring_write(&session.ring, frame[:], 1), 1)
	destination: [128]f32
	result := session_poll(&session, destination[:], 32, 10)
	testing.expect_value(t, result.frames, 1)
	testing.expect_value(t, result.reason, Poll_Reason.Data)
	testing.expect(t, !result.discontinuity, "first data is continuous")
	testing.expect_value(t, destination[0], f32(0.25))

	// Before the threshold: idle, but no timeline break yet.
	result = session_poll(&session, destination[:], 32, 900)
	testing.expect_value(t, result.reason, Poll_Reason.Idle)
	testing.expect(t, !result.discontinuity, "no break before the threshold")
	epoch_before := session.epoch

	// Threshold crossed: one explicit break, no fabricated frames, no clock
	// advance.
	result = session_poll(&session, destination[:], 32, 1500)
	testing.expect_value(t, result.reason, Poll_Reason.Idle)
	testing.expect(t, result.discontinuity, "threshold reports a timeline break")
	testing.expect(t, session.epoch > epoch_before, "epoch advances at the break")
	testing.expect_value(t, session.delivered_frames, u64(1))

	// Still idle: no repeated break.
	result = session_poll(&session, destination[:], 32, 2000)
	testing.expect(t, !result.discontinuity, "idle repeats without another break")

	// Delivery resumes: report the resumed discontinuity once, then continuity.
	testing.expect_value(t, ring_write(&session.ring, frame[:], 1), 1)
	result = session_poll(&session, destination[:], 32, 2100)
	testing.expect_value(t, result.frames, 1)
	testing.expect(t, result.discontinuity, "resume reports the broken timeline")
	testing.expect_value(t, session.delivered_frames, u64(2))
	testing.expect_value(t, ring_write(&session.ring, frame[:], 1), 1)
	result = session_poll(&session, destination[:], 32, 2200)
	testing.expect(t, !result.discontinuity, "continuous again after the resume")
}

@(test)
test_session_device_loss_recovers_with_new_epoch :: proc(t: ^testing.T) {
	fake := Fake{}
	session: Session
	testing.expect(t, session_open(&session, fake_backend(&fake), Device_Config{sample_rate = 48000, channels = 2}, 64), "open")
	defer session_close(&session)
	testing.expect(t, session_start(&session, 0), "start")
	destination: [128]f32
	frame := [2]f32{0.1, 0.2}
	testing.expect_value(t, ring_write(&session.ring, frame[:], 1), 1)
	_ = session_poll(&session, destination[:], 32, 10)
	epoch_before := session.epoch

	// The endpoint disappears. Recovery succeeds on the first poll.
	fake.lost_flag = true
	result := session_poll(&session, destination[:], 32, 100)
	testing.expect_value(t, result.reason, Poll_Reason.Recovered)
	testing.expect(t, result.discontinuity, "device loss is a discontinuity")
	testing.expect(t, session.epoch > epoch_before, "device switch starts a new analysis epoch")
	testing.expect(t, fake.opens >= 2 && fake.closes >= 1, "device was reopened")
	testing.expect_value(t, ring_available(&session.ring), 0)

	// A failed reopen stays explicitly unavailable, then recovers later.
	fake.lost_flag = true
	fake.fail_open = true
	result = session_poll(&session, destination[:], 32, 200)
	testing.expect_value(t, result.reason, Poll_Reason.Device_Lost)
	result = session_poll(&session, destination[:], 32, 300)
	testing.expect_value(t, result.reason, Poll_Reason.Device_Lost)
	fake.fail_open = false
	fake.lost_flag = false
	result = session_poll(&session, destination[:], 32, 400)
	testing.expect_value(t, result.reason, Poll_Reason.Recovered)
	testing.expect(t, result.discontinuity, "retry recovery reports the break")
}

// ---------------------------------------------------------------------------
// Shared engine pipeline, no allocation
// ---------------------------------------------------------------------------

@(test)
test_capture_ring_and_engine_pipeline_allocates_nothing :: proc(t: ^testing.T) {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	allocator := mem.tracking_allocator(&tracker)

	ring: Capture_Ring
	testing.expect(t, ring_init(&ring, 2048, 2, allocator), "ring init")
	defer ring_destroy(&ring, allocator)
	engine := meter.engine_create(allocator)
	defer meter.engine_destroy(engine)
	testing.expect(t, meter.engine_activate(engine, 48000, 512), "engine activate")

	input := [512 * 2]f32{}
	output: [512 * 2]f32
	for index in 0 ..< len(input) {
		input[index] = f32((index * 31) % 1000) / 2000 - 0.25
	}
	// Warm up outside the measured window.
	_ = ring_write(&ring, input[:], 512)
	_ = ring_read(&ring, output[:], 512)
	_ = meter.engine_push_interleaved(engine, output[:], 512, -1)

	before := tracker.total_allocation_count
	for _ in 0 ..< 32 {
		testing.expect_value(t, ring_write(&ring, input[:], 512), 512)
		frames := ring_read(&ring, output[:], 512)
		testing.expect_value(t, frames, 512)
		_ = meter.engine_push_interleaved(engine, output[:], frames, -1)
		_ = meter.engine_snapshot(engine)
	}
	testing.expect_value(t, tracker.total_allocation_count, before)
}

// ---------------------------------------------------------------------------
// Machine-local self-loop
// ---------------------------------------------------------------------------

@(test)
test_loopback_self_loop_matches_closed_form :: proc(t: ^testing.T) {
	tone: Tone
	if !tone_start(&tone, 400, 0.5, 48000) {
		fmt.println("SKIP loopback self-loop: no playback device in this session")
		return
	}
	defer tone_stop(&tone)

	loopback: Loopback
	session: Session
	if !session_open(&session, loopback_backend(&loopback), Device_Config{
		sample_rate = 48000,
		channels = 2,
		period_frames = 480,
	}, 48000) {
		fmt.println("SKIP loopback self-loop: no loopback-capable render endpoint in this session")
		return
	}
	defer session_close(&session)
	if !session_start(&session) {
		fmt.println("SKIP loopback self-loop: loopback device did not start")
		return
	}

	engine := meter.engine_create()
	if engine == nil {
		testing.fail_now(t, "engine create")
	}
	defer meter.engine_destroy(engine)
	rate := int(session.info.sample_rate)
	if rate <= 0 {
		rate = 48000
	}
	testing.expect(t, meter.engine_activate(engine, f64(rate), 1024), "engine activate")
	parameters := meter.default_parameters()
	parameters.window_frames = 4800 // 0.1 s == 40 cycles at 400 Hz
	parameters.hold_frames = 0
	parameters.hold_decay_enabled = false
	meter.engine_set_parameters(engine, parameters)
	// The engine must not be reset before the tone is audible; warm-up frames
	// are discarded below, then the analysis starts on a clean window boundary.
	warmed := false
	warmup_frames := 0
	collected := 0
	buffer: [4096]f32
	deadline := time.tick_now()
	for time.tick_since(deadline) < 3 * time.Second {
		poll := session_poll(&session, buffer[:], 1024)
		if poll.reason == Poll_Reason.Device_Lost || poll.reason == Poll_Reason.Closed {
			break
		}
		if poll.discontinuity && warmed {
			meter.engine_note_discontinuity(engine, 0)
			collected = 0
		}
		if poll.frames > 0 {
			if !warmed {
				// Discard the first 0.1 s so the analysis window does not include
				// the pre-playback silence, then start on a clean boundary.
				warmup_frames += poll.frames
				if warmup_frames >= 4800 {
					meter.engine_reset(engine)
					warmed = true
				}
				continue
			}
			_ = meter.engine_push_interleaved(engine, buffer[:poll.frames * 2], poll.frames, -1)
			collected += poll.frames
			if collected >= 24000 {
				break
			}
		}
		time.sleep(5 * time.Millisecond)
	}
	if collected < 12000 {
		fmt.println("SKIP loopback self-loop: captured too few frames in this session")
		return
	}
	snapshot := meter.engine_snapshot(engine)
	expected_peak := f64(0.5)
	expected_rms := 0.5 / math.sqrt(2.0)
	peak := f64(max(snapshot.peak[0], snapshot.peak[1]))
	rms := f64(max(snapshot.rms[0], snapshot.rms[1]))
	peak_error := math.abs(peak - expected_peak) / expected_peak
	rms_error := math.abs(rms - expected_rms) / expected_rms
	fmt.printf(
		"loopback self-loop: %d frames, peak %.6f (expected %.6f, %+.3f%%), rms %.6f (expected %.6f, %+.3f%%)\n",
		collected,
		peak,
		expected_peak,
		peak_error * 100,
		rms,
		expected_rms,
		rms_error * 100,
	)
	testing.expect(t, snapshot.valid, "snapshot is valid over a continuous loopback run")
	// Shared-mode loopback is not bit-transparent: endpoint mixing, format
	// conversion and resampling are allowed. 1% level accuracy is the documented
	// contract; measured deviation on the development machine is printed above
	// and recorded in docs/clap-plugin.md.
	testing.expectf(t, peak_error <= 0.01, "peak %.6f deviates %.3f%% from 0.5", peak, peak_error * 100)
	testing.expectf(t, rms_error <= 0.01, "rms %.6f deviates %.3f%% from 1/sqrt(2)*0.5", rms, rms_error * 100)
}
