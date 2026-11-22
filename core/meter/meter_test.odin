// Engine-level tests shared by both consumers.
//
// These tests do not instantiate a CLAP plugin: they pin the partition/epoch
// semantics and the capture-domain contracts that the CLAP census and the
// standalone meter both rely on.
package meter

import "core:math"
import "core:mem"
import "core:testing"

SINE_FRAMES :: 10000

sine_interleaved :: proc(frames: int, rate: int = 48000, frequency: f64 = 750) -> []f32 {
	samples := make([]f32, frames * CHANNELS)
	for frame in 0 ..< frames {
		value := f32(0.5 * math.sin(2 * math.PI * frequency * f64(frame) / f64(rate)))
		samples[frame * CHANNELS + 0] = value
		samples[frame * CHANNELS + 1] = value * 0.5
	}
	return samples
}

records_equal :: proc(a, b: Measurement_Record) -> bool {
	if a.schema_version != b.schema_version || a.epoch != b.epoch ||
		a.generation != b.generation || a.start_frame != b.start_frame ||
		a.frames != b.frames || a.channels != b.channels ||
		a.sample_rate != b.sample_rate || a.valid != b.valid ||
		a.overrun != b.overrun || a.capture_valid != b.capture_valid {
		return false
	}
	for channel in 0 ..< CHANNELS {
		if transmute(u32)a.peak[channel] != transmute(u32)b.peak[channel] ||
			a.peak_frame[channel] != b.peak_frame[channel] ||
			transmute(u32)a.rms[channel] != transmute(u32)b.rms[channel] ||
			transmute(u32)a.hold[channel] != transmute(u32)b.hold[channel] {
			return false
		}
	}
	return true
}

drain_all :: proc(engine: ^Engine, allocator := context.allocator) -> []Measurement_Record {
	result := make([dynamic]Measurement_Record, 0, 64, allocator)
	buffer: [64]Measurement_Record
	for {
		count := engine_measurement_drain(engine, buffer[:])
		if count <= 0 {
			break
		}
		append(&result, ..buffer[:count])
	}
	return result[:]
}

partition_render :: proc(block_sizes: []int) -> []Measurement_Record {
	engine := engine_create()
	if engine == nil {
		return nil
	}
	defer engine_destroy(engine)
	if !engine_activate(engine, 48000, 1024) {
		return nil
	}
	_ = engine_capture_set_enabled(engine, true)
	parameters := default_parameters()
	parameters.window_frames = 512
	parameters.hold_frames = 96000
	parameters.hold_decay_enabled = false
	engine_set_parameters(engine, parameters)

	samples := sine_interleaved(SINE_FRAMES)
	defer delete(samples)
	offset := 0
	index := 0
	for offset < SINE_FRAMES {
		size := block_sizes[index % len(block_sizes)]
		size = min(size, SINE_FRAMES - offset)
		_ = engine_push_interleaved(engine, samples[offset * CHANNELS:], size, -1)
		offset += size
		index += 1
	}
	return drain_all(engine)
}

@(test)
test_partition_invariance_of_canonical_records :: proc(t: ^testing.T) {
	partitions := [][]int{
		{64},
		{128},
		{256},
		{512},
		{997},
		{64, 512, 128, 1024, 384},
	}
	reference := partition_render(partitions[0])
	defer delete(reference)
	testing.expect(t, len(reference) == SINE_FRAMES / 512, "reference record count")
	for partition in partitions[1:] {
		other := partition_render(partition)
		defer delete(other)
		testing.expect_value(t, len(other), len(reference))
		for index in 0 ..< min(len(reference), len(other)) {
			testing.expectf(t, records_equal(reference[index], other[index]),
				"record %d differs for partition %v", index, partition)
		}
	}
	// Presentation cadence is independent: reading a snapshot between pushes is
	// not part of the canonical result.
	snapshot := engine_snapshot(nil)
	_ = snapshot
}

@(test)
test_explicit_discontinuity_starts_new_epoch_and_window :: proc(t: ^testing.T) {
	engine := engine_create()
	defer engine_destroy(engine)
	testing.expect(t, engine_activate(engine, 48000, 1024), "activate")
	_ = engine_capture_set_enabled(engine, true)
	parameters := default_parameters()
	parameters.window_frames = 512
	parameters.hold_decay_enabled = false
	engine_set_parameters(engine, parameters)

	samples := sine_interleaved(4096)
	defer delete(samples)
	offset := 0
	for offset < 3000 {
		size := min(512, 3000 - offset)
		_ = engine_push_interleaved(engine, samples[offset * CHANNELS:], size, -1)
		offset += size
	}
	before := drain_all(engine)
	defer delete(before)
	testing.expect_value(t, len(before), 5)
	old_epoch := before[0].epoch
	testing.expect(t, before[0].valid, "pre-discontinuity records are audio-valid")

	// An idle device/endpoint switch: no frames are known lost, so the clock
	// stays put. The analysis epoch advances and the partial window is dropped.
	engine_note_discontinuity(engine, 0)
	_ = engine_push_interleaved(engine, samples[3000 * CHANNELS:], 1024, -1)
	after := drain_all(engine)
	defer delete(after)
	testing.expect_value(t, len(after), 2)
	testing.expect_value(t, after[0].start_frame, i64(3000))
	testing.expect(t, after[0].epoch > old_epoch, "epoch advanced across the discontinuity")
	testing.expect(t, !after[0].valid && after[0].overrun, "post-discontinuity audio is invalid")
	testing.expect(t, after[0].capture_valid, "audio loss does not invalidate capture")

	// No window straddles the boundary: the partial window at 2560..3000 is
	// discarded rather than completed with post-gap samples.
	for record in after {
		testing.expect(t, record.start_frame >= 3000, "post-discontinuity window starts at the boundary")
	}
}

@(test)
test_capture_episode_switch_requires_quiescence :: proc(t: ^testing.T) {
	engine := engine_create()
	defer engine_destroy(engine)
	testing.expect(t, engine_activate(engine, 48000, 1024), "activate")
	testing.expect_value(t, engine_capture_set_enabled(engine, true), Capture_Set_Result.Ok)
	engine_set_processing(engine, true)
	testing.expect_value(t, engine_capture_set_enabled(engine, false), Capture_Set_Result.Busy)
	testing.expect(t, engine_capture_enabled(engine), "busy toggle kept the episode")
	engine_set_processing(engine, false)
	testing.expect_value(t, engine_capture_set_enabled(engine, false), Capture_Set_Result.Ok)
	testing.expect(t, !engine_capture_enabled(engine), "disabled after quiescence")
}

@(test)
test_push_and_drain_allocate_nothing :: proc(t: ^testing.T) {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	allocator := mem.tracking_allocator(&tracker)

	engine := engine_create(allocator)
	defer engine_destroy(engine)
	testing.expect(t, engine_activate(engine, 48000, 1024), "activate")
	_ = engine_capture_set_enabled(engine, true)

	samples := sine_interleaved(64 * 512)
	defer delete(samples)
	// Warm up caches/tracking outside the measured window.
	_ = engine_push_interleaved(engine, samples, 512, -1)
	before := tracker.total_allocation_count
	for block in 1 ..< 64 {
		_ = engine_push_interleaved(engine, samples[block * 512 * CHANNELS:], 512, -1)
		buffer: [8]Measurement_Record
		_ = engine_measurement_drain(engine, buffer[:])
		_ = engine_snapshot(engine)
	}
	testing.expect_value(t, tracker.total_allocation_count, before)
}
