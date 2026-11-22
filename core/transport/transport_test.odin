package transport

import "core:testing"
import "core:thread"

import "carnival:core/stream"

@(test)
test_ring_order_wrap_and_depth :: proc(t: ^testing.T) {
	ring: Audio_Ring
	testing.expect(t, audio_ring_init(&ring, 4, 2, 2, 1000, 3), "init")
	defer audio_ring_destroy(&ring)

	block_samples: [4]f32
	for block_index in 0 ..< 4 {
		for index in 0 ..< 4 {
			block_samples[index] = f32(block_index * 10 + index)
		}
		block := stream.Audio_Block{
			start_frame = i64(1000 + block_index * 2),
			frames = 2,
			channels = 2,
			interleaved = block_samples[:],
		}
		testing.expect(t, audio_ring_write(&ring, block), "write")
	}
	testing.expect_value(t, audio_ring_depth(&ring), u64(4))
	testing.expect_value(t, audio_ring_high_water(&ring), u64(4))

	buffer: [4]f32
	for block_index in 0 ..< 4 {
		result := audio_ring_read(&ring, buffer[:])
		testing.expect(t, result.ok, "read")
		testing.expect_value(t, result.start_frame, i64(1000 + block_index * 2))
		testing.expect_value(t, result.epoch, u64(3))
		for index in 0 ..< 4 {
			testing.expect_value(t, buffer[index], f32(block_index * 10 + index))
		}
	}
	testing.expect(t, !audio_ring_read(&ring, buffer[:]).ok, "empty")

	// Wrap: indices 4..7 reuse slots 0..3.
	for block_index in 4 ..< 8 {
		for index in 0 ..< 4 {
			block_samples[index] = f32(block_index * 10 + index)
		}
		block := stream.Audio_Block{
			start_frame = i64(1000 + block_index * 2),
			frames = 2,
			channels = 2,
			interleaved = block_samples[:],
		}
		testing.expect(t, audio_ring_write(&ring, block), "write after wrap")
	}
	result := audio_ring_read(&ring, buffer[:])
	testing.expect(t, result.ok && result.start_frame == 1008, "wrapped read starts at block 4")
	testing.expect_value(t, buffer[0], f32(40))

	// The sample clock is explicit: a mismatched start frame is rejected and is
	// not reported as an overrun.
	wrong_clock := stream.Audio_Block{start_frame = 9999, frames = 2, channels = 2, interleaved = block_samples[:]}
	testing.expect(t, !audio_ring_write(&ring, wrong_clock), "clock mismatch rejected")
	testing.expect(t, !audio_ring_overrun_seen(&ring), "clock mismatch is not an overrun")
	block := stream.Audio_Block{start_frame = 1016, frames = 2, channels = 2, interleaved = block_samples[:]}
	testing.expect(t, audio_ring_write(&ring, block), "correct clock accepted")
	testing.expect(t, !audio_ring_overrun_seen(&ring), "no overrun")
	testing.expect_value(t, audio_ring_dropped_blocks(&ring), u64(0))
}

@(test)
test_ring_overrun_is_sticky_until_reset :: proc(t: ^testing.T) {
	ring: Audio_Ring
	testing.expect(t, audio_ring_init(&ring, 2, 1, 1), "init")
	defer audio_ring_destroy(&ring)
	value := [1]f32{1}
	block := stream.Audio_Block{frames = 1, channels = 1, interleaved = value[:]}
	testing.expect(t, audio_ring_write(&ring, block), "write 1")
	block.start_frame = 1
	testing.expect(t, audio_ring_write(&ring, block), "write 2")
	block.start_frame = 2
	testing.expect(t, !audio_ring_write(&ring, block), "write 3 overruns")
	testing.expect(t, audio_ring_overrun_seen(&ring), "overrun latched")
	testing.expect_value(t, audio_ring_dropped_blocks(&ring), u64(1))

	buffer: [1]f32
	testing.expect(t, audio_ring_read(&ring, buffer[:]).ok, "drain one")
	testing.expect(t, audio_ring_write(&ring, block), "write after drain succeeds")
	testing.expect(t, audio_ring_overrun_seen(&ring), "latch remains after recovery")

	audio_ring_reset(&ring)
	testing.expect(t, !audio_ring_overrun_seen(&ring), "reset clears latch")
	testing.expect_value(t, audio_ring_dropped_blocks(&ring), u64(0))
	testing.expect_value(t, audio_ring_depth(&ring), u64(0))
	block.start_frame = 0
	testing.expect(t, audio_ring_write(&ring, block), "write after reset")
}

Ring_Thread_Context :: struct {
	ring:           ^Audio_Ring,
	expected_blocks: u64,
	received:       u64,
	mismatches:     int,
	buffer:         []f32,
}

ring_consumer :: proc(data: rawptr) {
	ctx := cast(^Ring_Thread_Context)data
	for ctx.received < ctx.expected_blocks {
		result := audio_ring_read(ctx.ring, ctx.buffer)
		if !result.ok {
			thread.yield()
			continue
		}
		if result.start_frame != i64(ctx.received * u64(ctx.ring.block_frames)) {
			ctx.mismatches += 1
		}
		expected := f32(ctx.received)
		for sample in ctx.buffer[:result.frames * ctx.ring.channels] {
			if sample != expected {
				ctx.mismatches += 1
			}
		}
		ctx.received += 1
	}
}

@(test)
test_ring_spsc_threaded :: proc(t: ^testing.T) {
	ring: Audio_Ring
	block_frames := 64
	channels := 2
	total_blocks := u64(500)
	testing.expect(t, audio_ring_init(&ring, 8, block_frames, channels, 0, 0), "init")
	defer audio_ring_destroy(&ring)

	ctx := Ring_Thread_Context{
		ring = &ring,
		expected_blocks = total_blocks,
		buffer = make([]f32, block_frames * channels),
	}
	defer delete(ctx.buffer)
	worker := thread.create_and_start_with_data(&ctx, ring_consumer)
	testing.expect(t, worker != nil, "consumer thread started")

	block_samples := make([]f32, block_frames * channels)
	defer delete(block_samples)
	for block_index in 0 ..< total_blocks {
		for index in 0 ..< len(block_samples) {
			block_samples[index] = f32(block_index)
		}
		block := stream.Audio_Block{
			start_frame = i64(block_index * u64(block_frames)),
			frames = block_frames,
			channels = channels,
			interleaved = block_samples,
		}
		for {
			if audio_ring_depth(&ring) < u64(ring.capacity_blocks) && audio_ring_write(&ring, block) {
				break
			}
			thread.yield()
		}
	}
	thread.join(worker)
	thread.destroy(worker)

	testing.expect_value(t, ctx.received, total_blocks)
	testing.expect_value(t, ctx.mismatches, 0)
	testing.expect_value(t, audio_ring_dropped_blocks(&ring), u64(0))
	testing.expect(t, !audio_ring_overrun_seen(&ring), "no overrun in threaded run")
	testing.expect_value(t, audio_ring_depth(&ring), u64(0))
}

@(test)
test_snapshot_latest_wins_and_copies :: proc(t: ^testing.T) {
	publisher: Snapshot_Publisher
	initial := snapshot_read(&publisher)
	testing.expect(t, !initial.valid && initial.generation == 0, "empty publisher reads invalid")

	first := Measurement_Snapshot{
		valid = true,
		epoch = 1,
		frame = 480,
		sample_rate = 48000,
		channels = 2,
		peak = {0.5, 0.25},
		peak_frame = {479, 478},
		rms = {0.35, 0.1},
		correlation = -0.5,
		correlation_valid = true,
	}
	generation := snapshot_publish(&publisher, first)
	testing.expect_value(t, generation, u64(2))
	read := snapshot_read(&publisher)
	testing.expect_value(t, read.generation, u64(2))
	testing.expect(t, read.valid && read.frame == 480, "first snapshot read")
	testing.expect_value(t, read.peak[1], f32(0.25))
	testing.expect_value(t, snapshot_generation(&publisher), u64(2))

	second := first
	second.frame = 960
	second.peak = {0.75, 0.5}
	generation = snapshot_publish(&publisher, second)
	testing.expect_value(t, generation, u64(4))
	read = snapshot_read(&publisher)
	testing.expect(t, read.frame == 960, "latest wins")
	testing.expect_value(t, read.peak[0], f32(0.75))

	// A returned snapshot is a value copy, not a borrowed buffer.
	read.frame = -1
	again := snapshot_read(&publisher)
	testing.expect_value(t, again.frame, i64(960))

	snapshot_publisher_reset(&publisher)
	testing.expect_value(t, snapshot_generation(&publisher), u64(0))
	testing.expect(t, !snapshot_read(&publisher).valid, "reset reads invalid")
}

@(test)
test_snapshot_fingerprint_repeatable :: proc(t: ^testing.T) {
	snapshot := Measurement_Snapshot{
		generation = 8,
		valid = true,
		epoch = 2,
		frame = 1024,
		sample_rate = 48000,
		channels = 2,
		peak = {0.5, 0.25},
		peak_frame = {1000, 1001},
		peak_db = {-6.0206, -12.0412},
		rms = {0.35355338, 0.17677669},
		rms_db = {-9.0309, -15.0512},
		hold = {0.6, 0.3},
		hold_db = {-4.4369, -10.4574},
		correlation = 0.25,
		correlation_valid = true,
	}
	first := snapshot_fingerprint(snapshot)
	second := snapshot_fingerprint(snapshot)
	testing.expect_value(t, first, second)
	changed := snapshot
	changed.correlation = -0.25
	testing.expect(t, snapshot_fingerprint(changed) != first, "fingerprint changes with a field")
	// Padding must not participate.
	with_padding := snapshot
	with_padding.valid = true
	testing.expect_value(t, snapshot_fingerprint(with_padding), first)
}
