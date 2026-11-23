// Capture-lifecycle integration tests: stall, device loss and capture-ring
// overrun with a synthetic source (no audio hardware).
//
// These pin the three-contract split from docs/architecture.md: the historical
// loss ledger is append-only, current validity is per window/epoch, and the
// presentation snapshot never shows a stale reading as live. A valid new epoch
// resumes without an explicit reset.
package tests

import "core:testing"

import "carnival:core/meter"

LIFECYCLE_WINDOW :: 512

lifecycle_engine :: proc(t: ^testing.T) -> ^meter.Engine {
	engine := meter.engine_create()
	if engine == nil {
		testing.fail_now(t, "engine_create")
	}
	if !meter.engine_activate(engine, 48000, 1024) {
		testing.fail_now(t, "engine_activate")
	}
	parameters := meter.default_parameters()
	parameters.window_frames = LIFECYCLE_WINDOW
	parameters.hold_frames = 0
	parameters.hold_decay_enabled = false
	meter.engine_set_parameters(engine, parameters)
	_ = meter.engine_capture_set_enabled(engine, true)
	return engine
}

lifecycle_push :: proc(engine: ^meter.Engine, samples: []f32, frames: int) {
	offset := 0
	for offset < frames {
		count := min(1024, frames - offset)
		_ = meter.engine_push_interleaved(engine,
			samples[offset * meter.CHANNELS:(offset + count) * meter.CHANNELS], count, -1)
		offset += count
	}
}

lifecycle_signal :: proc(frames: int, amplitude: f32) -> []f32 {
	samples := make([]f32, frames * meter.CHANNELS)
	for frame in 0 ..< frames {
		samples[frame * meter.CHANNELS + 0] = amplitude
		samples[frame * meter.CHANNELS + 1] = -amplitude * 0.5
	}
	return samples
}

lifecycle_drain :: proc(engine: ^meter.Engine) -> [dynamic]meter.Measurement_Record {
	records: [dynamic]meter.Measurement_Record
	buffer: [16]meter.Measurement_Record
	for {
		count := meter.engine_measurement_drain(engine, buffer[:])
		if count <= 0 {
			break
		}
		append(&records, ..buffer[:count])
	}
	return records
}

@(test)
test_capture_lifecycle_stall_then_valid_resume :: proc(t: ^testing.T) {
	engine := lifecycle_engine(t)
	defer meter.engine_destroy(engine)
	signal := lifecycle_signal(2048, 0.5)
	defer delete(signal)

	lifecycle_push(engine, signal, 2048)
	before := lifecycle_drain(engine)
	defer delete(before)
	testing.expect_value(t, len(before), 4)
	for record in before {
		testing.expect(t, record.valid, "pre-stall windows are valid")
	}
	old_epoch := before[0].epoch

	meter.engine_note_discontinuity(engine, 0, .Stall)
	noted := meter.engine_snapshot(engine)
	testing.expect(t, noted.epoch > old_epoch, "stall publishes the new epoch")
	testing.expect(t, !noted.valid && noted.overrun && !noted.window_valid,
		"stall immediately invalidates presentation")
	testing.expect_value(t, meter.engine_discontinuity_count(engine), 1)

	lifecycle_push(engine, signal, 2048)
	after := lifecycle_drain(engine)
	defer delete(after)
	testing.expect_value(t, len(after), 4)
	testing.expect(t, !after[0].valid && after[0].overrun,
		"the boundary window spanning the resume is invalid")
	for record in after[1:] {
		testing.expect(t, record.valid, "later contiguous windows are valid")
	}
	testing.expect(t, meter.engine_snapshot(engine).valid,
		"presentation resumes without a reset")
	ledger, ok := meter.engine_discontinuity_at(engine, 0)
	testing.expect(t, ok && ledger.event == .Stall && ledger.frames == 0,
		"historical stall ledger survives the new epoch")
}

@(test)
test_capture_lifecycle_device_loss_recovery :: proc(t: ^testing.T) {
	engine := lifecycle_engine(t)
	defer meter.engine_destroy(engine)
	signal := lifecycle_signal(2048, 0.25)
	defer delete(signal)

	lifecycle_push(engine, signal, 2048)
	initial := lifecycle_drain(engine)
	defer delete(initial)
	live := meter.engine_snapshot(engine)
	testing.expect(t, live.valid, "live snapshot before loss")
	epoch_before := live.epoch

	meter.engine_note_discontinuity(engine, 0, .Device_Lost)
	offline := meter.engine_snapshot(engine)
	testing.expect(t, offline.epoch > epoch_before, "device loss bumps the epoch")
	testing.expect(t, !offline.valid && offline.overrun,
		"device loss cannot present the old reading as live")
	testing.expect_value(t, offline.session_max[0], f32(0))

	meter.engine_note_discontinuity(engine, 0, .Device_Recovered)
	recovery_epoch := meter.engine_snapshot(engine).epoch
	testing.expect(t, recovery_epoch > offline.epoch, "recovery starts another epoch")

	lifecycle_push(engine, signal, 2048)
	after := lifecycle_drain(engine)
	defer delete(after)
	testing.expect_value(t, len(after), 4)
	testing.expect(t, !after[0].valid, "first post-recovery window is affected")
	testing.expect(t, after[1].valid, "new-epoch data becomes valid")
	testing.expect_value(t, after[1].epoch, recovery_epoch)
	testing.expect(t, meter.engine_snapshot(engine).valid, "presentation resumes")
}

@(test)
test_capture_lifecycle_overrun_records_dropped_range :: proc(t: ^testing.T) {
	engine := lifecycle_engine(t)
	defer meter.engine_destroy(engine)
	signal := lifecycle_signal(2048, 0.15)
	defer delete(signal)

	lifecycle_push(engine, signal, 2048)
	initial := lifecycle_drain(engine)
	defer delete(initial)
	before := meter.engine_snapshot(engine)

	// A capture-ring overrun advanced the source clock by 300 frames that the
	// engine never received.
	meter.engine_note_discontinuity(engine, 300, .Capture_Overrun)
	noted := meter.engine_snapshot(engine)
	testing.expect(t, noted.epoch > before.epoch, "overrun starts a new epoch")
	testing.expect(t, !noted.valid && noted.overrun, "overrun invalidates presentation")
	ledger, ok := meter.engine_discontinuity_at(engine, 0)
	testing.expect(t, ok && ledger.event == .Capture_Overrun && ledger.frames == 300,
		"the dropped range is in the historical ledger")

	// Post-gap data starts 300 frames later, not at the previous delivered end.
	lifecycle_push(engine, signal, 2048)
	after := lifecycle_drain(engine)
	defer delete(after)
	testing.expect_value(t, len(after), 4)
	testing.expect_value(t, after[0].start_frame, i64(2048 + 300))
	testing.expect(t, !after[0].valid, "the affected window is invalid")
	for record in after[1:] {
		testing.expect(t, record.valid, "next window is valid without a reset")
	}
	testing.expect(t, meter.engine_snapshot(engine).valid, "measurement resumes")
}
