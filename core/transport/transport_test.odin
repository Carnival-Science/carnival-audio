package transport

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sync"
import "core:testing"
import "core:thread"

import "carnival:core/stream"

// stress_count reads a positive integer from `name`, falling back to `fallback`.
// The default keeps CI deterministic; a developer can enlarge the run with an
// environment variable without changing the test source.
stress_count :: proc(name: string, fallback: int) -> int {
	value := os.get_env(name, context.allocator)
	defer delete(value, context.allocator)
	if value == "" {
		return fallback
	}
	parsed, ok := strconv.parse_int(value)
	if !ok || parsed < 1 {
		return fallback
	}
	return parsed
}

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
		testing.expect_value(t, audio_ring_push(&ring, block, u64(1000 + block_index * 2)), Audio_Ring_Push_Status.Accepted)
	}
	testing.expect_value(t, audio_ring_depth(&ring), u64(4))
	testing.expect_value(t, audio_ring_high_water(&ring), u64(4))
	testing.expect_value(t, audio_ring_source_frame_pos(&ring), u64(1008))

	buffer: [4]f32
	for block_index in 0 ..< 4 {
		result := audio_ring_read(&ring, buffer[:])
		testing.expect(t, result.ok, "read")
		testing.expect_value(t, result.start_frame, i64(1000 + block_index * 2))
		testing.expect_value(t, result.frames, 2)
		testing.expect_value(t, result.epoch, u64(3))
		testing.expect_value(t, result.continuity_epoch, u64(0))
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
		source_index := u64(1000 + block_index * 2)
		block := stream.Audio_Block{
			start_frame = i64(source_index),
			frames = 2,
			channels = 2,
			interleaved = block_samples[:],
		}
		testing.expect_value(t, audio_ring_push(&ring, block, source_index), Audio_Ring_Push_Status.Accepted)
	}
	result := audio_ring_read(&ring, buffer[:])
	testing.expect(t, result.ok && result.start_frame == 1008, "wrapped read starts at block 4")
	testing.expect_value(t, buffer[0], f32(40))

	// The explicit source index and the block's start frame must agree.
	mismatched := stream.Audio_Block{start_frame = 1016, frames = 2, channels = 2, interleaved = block_samples[:]}
	testing.expect_value(t, audio_ring_push(&ring, mismatched, 9999), Audio_Ring_Push_Status.Rejected_Invalid)

	// A backward source index is a duplicate, not a clock mismatch and not an
	// overrun.
	backward := stream.Audio_Block{start_frame = 999, frames = 2, channels = 2, interleaved = block_samples[:]}
	testing.expect_value(t, audio_ring_push(&ring, backward, 999), Audio_Ring_Push_Status.Rejected_Duplicate)
	testing.expect_value(t, audio_ring_duplicate_blocks(&ring), u64(1))
	testing.expect(t, !audio_ring_overrun_seen(&ring), "duplicate is not an overrun")

	block := stream.Audio_Block{start_frame = 1016, frames = 2, channels = 2, interleaved = block_samples[:]}
	testing.expect_value(t, audio_ring_push(&ring, block, 1016), Audio_Ring_Push_Status.Accepted)
	testing.expect(t, !audio_ring_overrun_seen(&ring), "no overrun")
	testing.expect_value(t, audio_ring_dropped_blocks(&ring), u64(0))
}

@(test)
test_ring_overrun_is_sticky_and_advances_source_clock :: proc(t: ^testing.T) {
	ring: Audio_Ring
	testing.expect(t, audio_ring_init(&ring, 2, 1, 1), "init")
	defer audio_ring_destroy(&ring)
	value := [1]f32{1}
	block := stream.Audio_Block{frames = 1, channels = 1, interleaved = value[:]}
	testing.expect_value(t, audio_ring_push(&ring, block, 0), Audio_Ring_Push_Status.Accepted)
	block.start_frame = 1
	testing.expect_value(t, audio_ring_push(&ring, block, 1), Audio_Ring_Push_Status.Accepted)
	block.start_frame = 2
	testing.expect_value(t, audio_ring_push(&ring, block, 2), Audio_Ring_Push_Status.Dropped_Overrun)
	testing.expect(t, audio_ring_overrun_seen(&ring), "overrun latched")
	testing.expect_value(t, audio_ring_dropped_blocks(&ring), u64(1))
	testing.expect_value(t, audio_ring_source_frame_pos(&ring), u64(3))

	// The dropped range is in the ledger; a live producer cannot resubmit it.
	gap: Discontinuity
	testing.expect(t, audio_ring_next_discontinuity(&ring, &gap), "overrun recorded as a gap")
	testing.expect_value(t, gap.start_frame, u64(2))
	testing.expect_value(t, gap.frames, u64(1))
	testing.expect_value(t, gap.reason, Discontinuity_Reason.Overrun_Drop)
	testing.expect_value(t, gap.continuity_epoch, u64(1))

	buffer: [1]f32
	testing.expect(t, audio_ring_read(&ring, buffer[:]).ok, "drain one")
	testing.expect_value(t, audio_ring_push(&ring, block, 2), Audio_Ring_Push_Status.Rejected_Duplicate)
	testing.expect_value(t, audio_ring_duplicate_blocks(&ring), u64(1))
	block.start_frame = 3
	testing.expect_value(t, audio_ring_push(&ring, block, 3), Audio_Ring_Push_Status.Accepted)

	// The queued pre-gap block still belongs to segment 0; the block produced
	// after the gap belongs to segment 1.
	pre_gap := audio_ring_read(&ring, buffer[:])
	testing.expect(t, pre_gap.ok && pre_gap.start_frame == 1, "pre-gap block remains readable")
	testing.expect_value(t, pre_gap.continuity_epoch, u64(0))
	testing.expect(t, audio_ring_overrun_seen(&ring), "latch remains after recovery")
	next := audio_ring_read(&ring, buffer[:])
	testing.expect(t, next.ok && next.start_frame == 3, "post-overrun block uses new segment")
	testing.expect_value(t, next.continuity_epoch, u64(1))

	audio_ring_reset(&ring)
	testing.expect(t, !audio_ring_overrun_seen(&ring), "reset clears latch")
	testing.expect_value(t, audio_ring_dropped_blocks(&ring), u64(0))
	testing.expect_value(t, audio_ring_duplicate_blocks(&ring), u64(0))
	testing.expect_value(t, audio_ring_depth(&ring), u64(0))
	testing.expect_value(t, audio_ring_source_frame_pos(&ring), u64(0))
	testing.expect_value(t, audio_ring_gaps_pending(&ring), u64(0))
	block.start_frame = 0
	testing.expect_value(t, audio_ring_push(&ring, block, 0), Audio_Ring_Push_Status.Accepted)
}

@(test)
test_ring_source_gap_ledger_and_resubmission :: proc(t: ^testing.T) {
	ring: Audio_Ring
	testing.expect(t, audio_ring_init(&ring, 8, 64, 2, 0, 7), "init")
	defer audio_ring_destroy(&ring)

	samples := make([]f32, 64 * 2)
	defer delete(samples)
	buffer := make([]f32, 64 * 2)
	defer delete(buffer)

	first := stream.Audio_Block{start_frame = 0, frames = 32, channels = 2, interleaved = samples[:64]}
	testing.expect_value(t, audio_ring_push(&ring, first, 0), Audio_Ring_Push_Status.Accepted)
	second := stream.Audio_Block{start_frame = 32, frames = 32, channels = 2, interleaved = samples[:64]}
	testing.expect_value(t, audio_ring_push(&ring, second, 32), Audio_Ring_Push_Status.Accepted)
	testing.expect(t, audio_ring_read(&ring, buffer).ok, "read first")
	testing.expect(t, audio_ring_read(&ring, buffer).ok, "read second")
	testing.expect_value(t, audio_ring_gaps_pending(&ring), u64(0))

	// A real dropped range: 64..95 never reached the ring.
	gapped := stream.Audio_Block{start_frame = 96, frames = 16, channels = 2, interleaved = samples[:32]}
	testing.expect_value(t, audio_ring_push(&ring, gapped, 96), Audio_Ring_Push_Status.Accepted_With_Gap)
	testing.expect_value(t, audio_ring_source_frame_pos(&ring), u64(112))

	gap: Discontinuity
	testing.expect(t, audio_ring_next_discontinuity(&ring, &gap), "gap recorded")
	testing.expect_value(t, gap.epoch, u64(7))
	testing.expect_value(t, gap.continuity_epoch, u64(1))
	testing.expect_value(t, gap.start_frame, u64(64))
	testing.expect_value(t, gap.frames, u64(32))
	testing.expect_value(t, gap.reason, Discontinuity_Reason.Source_Gap)

	read := audio_ring_read(&ring, buffer)
	testing.expect(t, read.ok, "post-gap read")
	testing.expect_value(t, read.start_frame, i64(96))
	testing.expect_value(t, read.frames, 16)
	testing.expect_value(t, read.continuity_epoch, u64(1))

	// Resubmitting the missing range, or an already-consumed block, is a
	// duplicate: the source clock advanced exactly once.
	missing := stream.Audio_Block{start_frame = 64, frames = 32, channels = 2, interleaved = samples[:64]}
	testing.expect_value(t, audio_ring_push(&ring, missing, 64), Audio_Ring_Push_Status.Rejected_Duplicate)
	testing.expect_value(t, audio_ring_push(&ring, gapped, 96), Audio_Ring_Push_Status.Rejected_Duplicate)
	testing.expect_value(t, audio_ring_duplicate_blocks(&ring), u64(2))

	after_gap := stream.Audio_Block{start_frame = 112, frames = 8, channels = 2, interleaved = samples[:16]}
	testing.expect_value(t, audio_ring_push(&ring, after_gap, 112), Audio_Ring_Push_Status.Accepted)
	testing.expect_value(t, audio_ring_read(&ring, buffer).continuity_epoch, u64(1))

	// A second forward jump records its own absolute range.
	later := stream.Audio_Block{start_frame = 200, frames = 8, channels = 2, interleaved = samples[:16]}
	testing.expect_value(t, audio_ring_push(&ring, later, 200), Audio_Ring_Push_Status.Accepted_With_Gap)
	testing.expect(t, audio_ring_next_discontinuity(&ring, &gap), "second gap recorded")
	testing.expect_value(t, gap.start_frame, u64(120))
	testing.expect_value(t, gap.frames, u64(80))
	testing.expect_value(t, gap.continuity_epoch, u64(2))
	testing.expect_value(t, audio_ring_gaps_recorded(&ring), u64(2))
	testing.expect_value(t, audio_ring_gaps_pending(&ring), u64(0))
}

@(test)
test_ring_variable_block_lengths :: proc(t: ^testing.T) {
	ring: Audio_Ring
	testing.expect(t, audio_ring_init(&ring, 3, 4096, 2, 0, 1), "init")
	defer audio_ring_destroy(&ring)

	sizes := [?]int{32, 64, 33, 1024, 4096, 1, 4095, 128, 2048, 17}
	buffer := make([]f32, 4096 * 2)
	defer delete(buffer)
	source := make([]f32, 4096 * 2)
	defer delete(source)

	position := u64(0)
	for size, iteration in sizes {
		for frame in 0 ..< size {
			for channel in 0 ..< 2 {
				source[frame * 2 + channel] = f32((position + u64(frame)) % 4096)
			}
		}
		block := stream.Audio_Block{
			start_frame = i64(position),
			frames = size,
			channels = 2,
			interleaved = source[:size * 2],
		}
		testing.expect_value(t, audio_ring_push(&ring, block, position), Audio_Ring_Push_Status.Accepted)
		position += u64(size)

		// A too-small destination reports the required size and leaves the
		// block queued.
		small: [8]f32
		if size * 2 > len(small) {
			short := audio_ring_read(&ring, small[:])
			testing.expect(t, !short.ok, "small destination rejected")
			testing.expect_value(t, short.frames, size)
		}
		read := audio_ring_read(&ring, buffer)
		testing.expect(t, read.ok, "variable read")
		testing.expect_value(t, read.frames, size)
		testing.expect_value(t, read.start_frame, i64(position - u64(size)))
		for sample_index in 0 ..< size * 2 {
			testing.expect_value(t, buffer[sample_index], source[sample_index])
		}
		_ = iteration
	}
	testing.expect_value(t, audio_ring_source_frame_pos(&ring), position)
	testing.expect(t, !audio_ring_read(&ring, buffer).ok, "drained")
	testing.expect_value(t, audio_ring_duplicate_blocks(&ring), u64(0))
	testing.expect(t, !audio_ring_overrun_seen(&ring), "no overrun")
	testing.expect_value(t, audio_ring_gaps_pending(&ring), u64(0))
}

Ring_Thread_Context :: struct {
	ring:           ^Audio_Ring,
	block_frames:   int,
	channels:       int,
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
		if result.start_frame != i64(ctx.received * u64(ctx.block_frames)) {
			ctx.mismatches += 1
		}
		if result.frames != ctx.block_frames || result.continuity_epoch != 0 {
			ctx.mismatches += 1
		}
		expected := f32(ctx.received)
		for sample in ctx.buffer[:result.frames * ctx.channels] {
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
		block_frames = block_frames,
		channels = channels,
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
		source_index := block_index * u64(block_frames)
		block := stream.Audio_Block{
			start_frame = i64(source_index),
			frames = block_frames,
			channels = channels,
			interleaved = block_samples,
		}
		for {
			if audio_ring_depth(&ring) < u64(ring.capacity_blocks) &&
				audio_ring_push(&ring, block, source_index) == .Accepted {
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

// Ring stress: a producer emits irregular block sizes 1..4096 with occasional
// source skips; a consumer validates block data, absolute positions, segments
// and every ledger record.
Ring_Stress_Event_Kind :: enum u8 {
	Block,
	Gap,
}

Ring_Stress_Event :: struct {
	kind:        Ring_Stress_Event_Kind,
	start_frame: u64,
	frames:      u64,
	segment:     u64,
}

Ring_Stress_Producer :: struct {
	ring:        ^Audio_Ring,
	events:      []Ring_Stress_Event,
	done:        u64, // atomic
	channels:    int,
	buffer:      []f32,
	unexpected:  int, // writer-owned; read after join
}

Ring_Stress_Consumer :: struct {
	ring:        ^Audio_Ring,
	events:      []Ring_Stress_Event,
	done:        ^u64,
	channels:    int,
	buffer:      []f32,
	blocks:      int,
	gaps:        int,
	mismatches:  int,
	missing:     int,
}

ring_stress_fill :: proc(buffer: []f32, start_frame: u64, frames, channels: int) {
	for frame in 0 ..< frames {
		value := f32((start_frame + u64(frame)) % 4096)
		for channel in 0 ..< channels {
			buffer[frame * channels + channel] = value
		}
	}
}

ring_stress_producer_thread :: proc(data: rawptr) {
	ctx := cast(^Ring_Stress_Producer)data
	for event in ctx.events {
		if event.kind != .Block {
			continue
		}
		ring_stress_fill(ctx.buffer, event.start_frame, int(event.frames), ctx.channels)
		block := stream.Audio_Block{
			start_frame = i64(event.start_frame),
			frames = int(event.frames),
			channels = ctx.channels,
			interleaved = ctx.buffer[:int(event.frames) * ctx.channels],
		}
		for {
			if audio_ring_depth(ctx.ring) < u64(ctx.ring.capacity_blocks) {
				status := audio_ring_push(ctx.ring, block, event.start_frame)
				if status == .Accepted || status == .Accepted_With_Gap {
					break
				}
				ctx.unexpected += 1
				break
			}
			thread.yield()
		}
	}
	sync.atomic_store_explicit(&ctx.done, 1, .Release)
}

ring_stress_wait_gap :: proc(ctx: ^Ring_Stress_Consumer, discontinuity: ^Discontinuity) -> bool {
	for {
		if audio_ring_next_discontinuity(ctx.ring, discontinuity) {
			return true
		}
		if sync.atomic_load_explicit(ctx.done, .Acquire) != 0 &&
			audio_ring_gaps_pending(ctx.ring) == 0 {
			return false
		}
		thread.yield()
	}
}

ring_stress_wait_block :: proc(ctx: ^Ring_Stress_Consumer, result: ^Audio_Ring_Read) -> bool {
	for {
		result^ = audio_ring_read(ctx.ring, ctx.buffer)
		if result.ok {
			return true
		}
		if sync.atomic_load_explicit(ctx.done, .Acquire) != 0 &&
			audio_ring_depth(ctx.ring) == 0 {
			return false
		}
		thread.yield()
	}
}

ring_stress_consumer_thread :: proc(data: rawptr) {
	ctx := cast(^Ring_Stress_Consumer)data
	result: Audio_Ring_Read
	discontinuity: Discontinuity
	for event in ctx.events {
		switch event.kind {
		case .Gap:
			if !ring_stress_wait_gap(ctx, &discontinuity) {
				ctx.missing += 1
				return
			}
			ctx.gaps += 1
			if discontinuity.start_frame != event.start_frame ||
				discontinuity.frames != event.frames ||
				discontinuity.continuity_epoch != event.segment ||
				discontinuity.epoch != 5 ||
				discontinuity.reason != .Source_Gap {
				ctx.mismatches += 1
			}
		case .Block:
			if !ring_stress_wait_block(ctx, &result) {
				ctx.missing += 1
				return
			}
			ctx.blocks += 1
			if result.start_frame != i64(event.start_frame) ||
				result.frames != int(event.frames) ||
				result.continuity_epoch != event.segment ||
				result.epoch != 5 {
				ctx.mismatches += 1
			}
			for frame in 0 ..< result.frames {
				expected := f32((event.start_frame + u64(frame)) % 4096)
				for channel in 0 ..< ctx.channels {
					if ctx.buffer[frame * ctx.channels + channel] != expected {
						ctx.mismatches += 1
					}
				}
			}
		}
	}
}

ring_stress_build_events :: proc(target_blocks: int) -> [dynamic]Ring_Stress_Event {
	sizes := [?]int{32, 48, 64, 127, 256, 511, 1024, 2048, 4096, 1, 17, 33}
	events := make([dynamic]Ring_Stress_Event, 0, target_blocks * 2)
	position := u64(0)
	segment := u64(0)
	block_count := 0
	iteration := 0
	for block_count < target_blocks {
		if iteration % 53 == 52 {
			skip := u64(1 + (iteration * 37) % 300)
			segment += 1
			append(&events, Ring_Stress_Event{
				kind = .Gap,
				start_frame = position,
				frames = skip,
				segment = segment,
			})
			position += skip
		}
		frames := sizes[(iteration * 7) % len(sizes)]
		append(&events, Ring_Stress_Event{
			kind = .Block,
			start_frame = position,
			frames = u64(frames),
			segment = segment,
		})
		position += u64(frames)
		block_count += 1
		iteration += 1
	}
	return events
}

@(test)
test_ring_spsc_variable_blocks_and_discontinuities :: proc(t: ^testing.T) {
	target_blocks := stress_count("CARNIVAL_STRESS_RING_BLOCKS", 100000)
	events := ring_stress_build_events(target_blocks)
	defer delete(events)

	expected_gaps := 0
	for event in events {
		if event.kind == .Gap {
			expected_gaps += 1
		}
	}

	ring: Audio_Ring
	testing.expect(t, audio_ring_init(&ring, 8, 4096, 2, 0, 5), "init")
	defer audio_ring_destroy(&ring)

	producer_ctx := Ring_Stress_Producer{
		ring = &ring,
		events = events[:],
		channels = 2,
		buffer = make([]f32, 4096 * 2),
	}
	defer delete(producer_ctx.buffer)
	consumer_ctx := Ring_Stress_Consumer{
		ring = &ring,
		events = events[:],
		done = &producer_ctx.done,
		channels = 2,
		buffer = make([]f32, 4096 * 2),
	}
	defer delete(consumer_ctx.buffer)

	consumer_thread := thread.create_and_start_with_data(&consumer_ctx, ring_stress_consumer_thread)
	testing.expect(t, consumer_thread != nil, "consumer thread started")
	producer_ctx.done = 0
	producer_thread := thread.create_and_start_with_data(&producer_ctx, ring_stress_producer_thread)
	testing.expect(t, producer_thread != nil, "producer thread started")

	thread.join(producer_thread)
	thread.destroy(producer_thread)
	thread.join(consumer_thread)
	thread.destroy(consumer_thread)

	testing.expect_value(t, producer_ctx.unexpected, 0)
	testing.expect_value(t, consumer_ctx.missing, 0)
	testing.expect_value(t, consumer_ctx.mismatches, 0)
	testing.expect_value(t, consumer_ctx.blocks, target_blocks)
	testing.expect_value(t, consumer_ctx.gaps, expected_gaps)
	testing.expect_value(t, audio_ring_gaps_recorded(&ring), u64(expected_gaps))
	testing.expect_value(t, audio_ring_gaps_pending(&ring), u64(0))
	testing.expect_value(t, audio_ring_depth(&ring), u64(0))
	testing.expect_value(t, audio_ring_duplicate_blocks(&ring), u64(0))
	testing.expect_value(t, audio_ring_dropped_blocks(&ring), u64(0))
	testing.expect(t, !audio_ring_overrun_seen(&ring), "no overrun")
	testing.expect(t, !audio_ring_ledger_overflow_seen(&ring), "ledger did not overflow")
	fmt.printf("ring stress: %d blocks, %d gaps, %d frames\n",
		consumer_ctx.blocks, consumer_ctx.gaps, audio_ring_source_frame_pos(&ring))
}

@(test)
test_snapshot_latest_wins_and_copies :: proc(t: ^testing.T) {
	publisher: Snapshot_Publisher
	initial := snapshot_read(&publisher)
	testing.expect(t, !initial.valid && initial.generation == 0, "empty publisher reads invalid")

	first := Measurement_Snapshot{
		schema_version = SNAPSHOT_SCHEMA_VERSION,
		valid = true,
		window_valid = true,
		epoch = 1,
		frame = 480,
		sample_rate = 48000,
		channels = 2,
		window_peak = {0.5, 0.25},
		window_peak_frame = {479, 478},
		rms = {0.35, 0.1},
		correlation = -0.5,
		correlation_valid = true,
	}
	generation := snapshot_publish(&publisher, first)
	testing.expect_value(t, generation, u64(2))
	read := snapshot_read(&publisher)
	testing.expect_value(t, read.generation, u64(2))
	testing.expect(t, read.valid && read.frame == 480, "first snapshot read")
	testing.expect_value(t, read.window_peak[1], f32(0.25))
	testing.expect_value(t, snapshot_generation(&publisher), u64(2))

	second := first
	second.frame = 960
	second.window_peak = {0.75, 0.5}
	generation = snapshot_publish(&publisher, second)
	testing.expect_value(t, generation, u64(4))
	read = snapshot_read(&publisher)
	testing.expect(t, read.frame == 960, "latest wins")
	testing.expect_value(t, read.window_peak[0], f32(0.75))

	// A returned snapshot is a value copy, not a borrowed buffer.
	read.frame = -1
	again := snapshot_read(&publisher)
	testing.expect_value(t, again.frame, i64(960))

	snapshot_publisher_reset(&publisher)
	testing.expect_value(t, snapshot_generation(&publisher), u64(0))
	testing.expect(t, !snapshot_read(&publisher).valid, "reset reads invalid")
}

// Snapshot stress: one writer publishes continuously while four readers copy
// concurrently. Every accepted snapshot must be internally consistent with its
// generation (no torn mix), generations observed by a reader must be monotonic,
// and every read must finish within the documented retry bound.
Snapshot_Stress_Writer :: struct {
	publisher:       ^Snapshot_Publisher,
	publishes:       int,
	done:            u64, // atomic
	readers_ready:   u64, // atomic
	expected_readers: u64,
	generation_errors: int,
}

Snapshot_Stress_Reader :: struct {
	publisher:       ^Snapshot_Publisher,
	done:            ^u64,
	readers_ready:   ^u64,
	valid_reads:     u64,
	invalid_reads:   u64,
	torn:            u64,
	nonmonotonic:    u64,
	max_attempts:    int,
	last_generation: u64,
}

// snapshot_stress_record derives every field from `generation`. A reader can
// therefore detect any mixed-generation copy by recomputing it.
snapshot_stress_record :: proc(generation: u64) -> Measurement_Snapshot {
	return Measurement_Snapshot{
		generation = generation,
		schema_version = SNAPSHOT_SCHEMA_VERSION,
		valid = true,
		overrun = generation % 7 == 0,
		window_valid = generation % 5 != 0,
		epoch = generation,
		frame = i64(generation),
		sample_rate = 48000,
		channels = 2,
		window_peak = {f32(generation % 1024), f32((generation * 3) % 1024)},
		window_peak_frame = {i64(generation * 2), i64(generation * 2 + 1)},
		window_peak_db = {f32(generation % 512), f32((generation * 5) % 512)},
		rms = {f32(generation % 256), f32((generation * 7) % 256)},
		rms_db = {f32(generation % 128), f32((generation * 11) % 128)},
		peak_hold = {f32(generation % 64), f32((generation * 13) % 64)},
		peak_hold_db = {f32(generation % 32), f32((generation * 17) % 32)},
		session_max = {f32(generation % 16), f32((generation * 19) % 16)},
		session_max_db = {f32(generation % 8), f32((generation * 23) % 8)},
		correlation = f32(generation % 2000) - 1000,
		correlation_valid = generation % 3 == 0,
	}
}

snapshot_stress_matches :: proc(snapshot: Measurement_Snapshot, generation: u64) -> bool {
	expected := snapshot_stress_record(generation)
	return snapshot == expected
}

snapshot_stress_writer_thread :: proc(data: rawptr) {
	ctx := cast(^Snapshot_Stress_Writer)data
	for sync.atomic_load_explicit(&ctx.readers_ready, .Acquire) < ctx.expected_readers {
		thread.yield()
	}
	for index in 0 ..< ctx.publishes {
		generation := u64(index + 1) * 2
		published := snapshot_publish(ctx.publisher, snapshot_stress_record(generation))
		if published != generation {
			ctx.generation_errors += 1
		}
	}
	sync.atomic_store_explicit(&ctx.done, 1, .Release)
}

snapshot_stress_reader_thread :: proc(data: rawptr) {
	ctx := cast(^Snapshot_Stress_Reader)data
	sync.atomic_add_explicit(ctx.readers_ready, 1, .Release)
	for sync.atomic_load_explicit(ctx.done, .Acquire) == 0 {
		attempts := 0
		snapshot := snapshot_read(ctx.publisher, &attempts)
		ctx.max_attempts = max(ctx.max_attempts, attempts)
		if !snapshot.valid {
			ctx.invalid_reads += 1
			continue
		}
		ctx.valid_reads += 1
		generation := snapshot.generation
		if generation & 1 != 0 {
			ctx.torn += 1
		}
		if generation < ctx.last_generation {
			ctx.nonmonotonic += 1
		}
		ctx.last_generation = generation
		if !snapshot_stress_matches(snapshot, generation) {
			ctx.torn += 1
		}
	}
	// The final publication is stable: this read also guarantees each reader
	// observes at least one complete value even if it started late.
	attempts := 0
	snapshot := snapshot_read(ctx.publisher, &attempts)
	ctx.max_attempts = max(ctx.max_attempts, attempts)
	if snapshot.valid {
		ctx.valid_reads += 1
		if snapshot.generation < ctx.last_generation {
			ctx.nonmonotonic += 1
		}
		ctx.last_generation = snapshot.generation
		if !snapshot_stress_matches(snapshot, snapshot.generation) {
			ctx.torn += 1
		}
	} else {
		ctx.invalid_reads += 1
	}
}

@(test)
test_snapshot_concurrent_publication_stress :: proc(t: ^testing.T) {
	READERS :: 4
	publishes := stress_count("CARNIVAL_STRESS_SNAPSHOT_PUBLISHES", 1000000)
	publisher: Snapshot_Publisher
	writer := Snapshot_Stress_Writer{
		publisher = &publisher,
		publishes = publishes,
		expected_readers = READERS,
	}
	readers: [READERS]Snapshot_Stress_Reader
	threads: [READERS]^thread.Thread
	for index in 0 ..< READERS {
		readers[index] = Snapshot_Stress_Reader{
			publisher = &publisher,
			done = &writer.done,
			readers_ready = &writer.readers_ready,
		}
		threads[index] = thread.create_and_start_with_data(&readers[index], snapshot_stress_reader_thread)
		testing.expect(t, threads[index] != nil, "reader thread started")
	}

	snapshot_stress_writer_thread(&writer)

	total_valid := u64(0)
	total_invalid := u64(0)
	total_torn := u64(0)
	total_nonmonotonic := u64(0)
	max_attempts := 0
	for index in 0 ..< READERS {
		thread.join(threads[index])
		thread.destroy(threads[index])
		total_valid += readers[index].valid_reads
		total_invalid += readers[index].invalid_reads
		total_torn += readers[index].torn
		total_nonmonotonic += readers[index].nonmonotonic
		max_attempts = max(max_attempts, readers[index].max_attempts)
		testing.expectf(t, readers[index].max_attempts <= SNAPSHOT_READ_RETRIES,
			"reader %d exceeded the retry bound: %d", index, readers[index].max_attempts)
	}

	testing.expect_value(t, writer.generation_errors, 0)
	testing.expect_value(t, total_torn, u64(0))
	testing.expect_value(t, total_nonmonotonic, u64(0))
	testing.expect(t, total_valid > 0, "readers observed complete snapshots")
	testing.expect_value(t, snapshot_generation(&publisher), u64(publishes) * 2)
	fmt.printf("snapshot stress: %d publications, %d readers, %d valid reads, %d invalid (retry-bound) reads, max attempts %d\n",
		publishes, READERS, total_valid, total_invalid, max_attempts)
}

@(test)
test_snapshot_fingerprint_repeatable :: proc(t: ^testing.T) {
	snapshot := Measurement_Snapshot{
		generation = 8,
		schema_version = SNAPSHOT_SCHEMA_VERSION,
		valid = true,
		window_valid = true,
		epoch = 2,
		frame = 1024,
		sample_rate = 48000,
		channels = 2,
		window_peak = {0.5, 0.25},
		window_peak_frame = {1000, 1001},
		window_peak_db = {-6.0206, -12.0412},
		rms = {0.35355338, 0.17677669},
		rms_db = {-9.0309, -15.0512},
		peak_hold = {0.6, 0.3},
		peak_hold_db = {-4.4369, -10.4574},
		session_max = {0.75, 0.5},
		session_max_db = {-2.4988, -6.0206},
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
