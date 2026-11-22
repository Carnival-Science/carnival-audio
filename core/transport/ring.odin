// Bounded single-producer/single-consumer block transport with an explicit
// source sample clock.
//
// The ring owns `capacity_blocks` slots, each preallocated for up to
// `max_block_frames` frames of `channels` interleaved f32 samples. A slot also
// records its actual frame count and continuity segment, so a producer may
// push variable-length host callbacks (for example 32..4096 frames) without
// allocating after init. All storage is allocated in init; push and read never
// allocate, lock or call into a platform API.
//
// Source clock vs queue storage
// -----------------------------
// Queue indices are storage positions and wrap with `capacity_blocks`. The
// source clock is independent: `source_frame_pos` is the absolute frame index
// of the next frame the source should produce. `audio_ring_push` takes that
// absolute index explicitly and verifies it against the clock.
//
//   - A contiguous block starts exactly at `source_frame_pos` and advances it
//     by the block's frame count.
//   - A forward jump (`source_frame_index > source_frame_pos`) means the source
//     lost frames. The lost absolute range is appended to the discontinuity
//     ledger, `continuity_epoch` advances, and the clock jumps to the new
//     index. The block is still transportable, but it belongs to a new segment.
//   - A backward index (`source_frame_index < source_frame_pos`) is rejected as
//     a duplicate/stale submission and counted in `duplicate_blocks`. The
//     source clock never moves backwards, and an already-consumed or lost range
//     is never accepted a second time. A live producer must not retry a block
//     after a drop; it continues at the next source frame.
//   - A dropped block (ring full) advances the clock by the block's frame count
//     and records that range as an overrun discontinuity. The overrun latch is
//     sticky until reset.
//
// Memory ordering (SPSC):
//   - writer copies samples, writes slot metadata, then publishes
//     `write_blocks` with Release;
//   - reader observes `write_blocks` with Acquire, copies samples, then
//     publishes `read_blocks` with Release;
//   - writer observes `read_blocks` with Acquire before reusing a slot;
//   - gap records are published through `gap_write` with Release and consumed
//     through `gap_read` with Release/Acquire.
//
// Continuity contract for analysis
// --------------------------------
// A single block never contains lost frames: losses are gaps *between* blocks.
// Every read result and every discontinuity carries `epoch` (the stream epoch)
// and `continuity_epoch` (a segment counter). Analysis that assembles a window
// from more than one block must invalidate that window when the segment changes
// or when it dequeues a discontinuity that overlaps the window. There is no
// implicit gap accounting: recovery requires an explicit reset (or a higher
// layer that explicitly accounts for the lost range). A sticky overrun or
// ledger-overflow latch independently invalidates sample-complete measurements.
package transport

import "core:mem"
import "core:sync"

import "carnival:core/stream"

// Discontinuity_Reason distinguishes how the lost range arose.
Discontinuity_Reason :: enum u8 {
	Source_Gap,   // the producer skipped frames (source clock jump)
	Overrun_Drop, // the ring was full and the produced block could not be stored
}

// Discontinuity is one absolute lost-frame range in the source clock. Ranges
// are half-open: [start_frame, start_frame + frames).
Discontinuity :: struct {
	epoch:             u64, // stream epoch
	continuity_epoch:  u64, // segment counter after this loss
	start_frame:       u64, // absolute frame index of the first lost frame
	frames:            u64, // number of lost frames
	reason:            Discontinuity_Reason,
}

Audio_Ring_Push_Status :: enum u8 {
	Accepted,            // contiguous block enqueued
	Accepted_With_Gap,   // enqueued after one or more lost frames were recorded
	Rejected_Duplicate,  // source index is older than the source clock
	Rejected_Invalid,    // invalid/oversized/mismatched block
	Dropped_Overrun,     // ring full; range advanced and recorded as lost
}

Audio_Ring :: struct {
	samples:          []f32,
	slot_frames:      []u32, // actual frame count per slot
	slot_start_frames: []u64, // absolute source frame index per slot
	slot_segments:    []u64, // continuity segment per slot
	gaps:             []Discontinuity,
	capacity_blocks:  int,
	max_block_frames: int,
	channels:         int,
	first_frame:      i64,
	epoch:            u64,
	allocator:        mem.Allocator,

	// Atomic u64 counters. Read/write indices are monotonic block counts, not
	// wrapped offsets; the slot is always `index % capacity_blocks`.
	write_blocks:     u64,
	read_blocks:      u64,
	dropped_blocks:   u64,
	duplicate_blocks: u64,
	high_water_blocks: u64,
	overrun_latched:  u64, // 0 or 1
	ledger_overflow_latched: u64, // 0 or 1

	// Discontinuity ledger, also SPSC.
	gap_capacity:     int,
	gap_write:        u64, // atomic; total records appended
	gap_read:         u64, // atomic; total records consumed

	// Writer-owned source clock. Never read by the consumer directly; slot and
	// gap records carry the published views.
	source_frame_pos: u64,
	continuity_epoch: u64,
}

// audio_ring_init preallocates every sample and metadata buffer. `gap_capacity`
// defaults to four records per ring slot when zero, which is ample for the
// expected one-gap-per-slot-loss rate; callers with a different loss pattern
// may pass an explicit capacity.
audio_ring_init :: proc(
	ring: ^Audio_Ring,
	capacity_blocks, max_block_frames, channels: int,
	first_frame: i64 = 0,
	epoch: u64 = 0,
	allocator := context.allocator,
	gap_capacity: int = 0,
) -> bool {
	if capacity_blocks < 1 || max_block_frames < 1 || channels < 1 || channels > stream.MAX_CHANNELS || first_frame < 0 {
		return false
	}
	if max_block_frames > 0x7FFF_FFFF || capacity_blocks > 0x7FFF_FFFF {
		return false
	}
	if channels > 0x7FFF_FFFF / max_block_frames ||
		capacity_blocks > (0x7FFF_FFFF / max_block_frames) / channels {
		return false
	}
	count := capacity_blocks * max_block_frames * channels
	if count <= 0 {
		return false
	}
	ledger_capacity := gap_capacity
	if ledger_capacity <= 0 {
		ledger_capacity = capacity_blocks * 4
	}
	if ledger_capacity < 1 {
		return false
	}
	sample_bytes, sample_err := mem.alloc_bytes(count * size_of(f32), align_of(f32), allocator)
	if sample_err != .None || sample_bytes == nil {
		return false
	}
	frame_bytes, frame_err := mem.alloc_bytes(capacity_blocks * size_of(u32), align_of(u32), allocator)
	if frame_err != .None || frame_bytes == nil {
		mem.free(raw_data(sample_bytes), allocator)
		return false
	}
	start_bytes, start_err := mem.alloc_bytes(capacity_blocks * size_of(u64), align_of(u64), allocator)
	if start_err != .None || start_bytes == nil {
		mem.free(raw_data(frame_bytes), allocator)
		mem.free(raw_data(sample_bytes), allocator)
		return false
	}
	segment_bytes, segment_err := mem.alloc_bytes(capacity_blocks * size_of(u64), align_of(u64), allocator)
	if segment_err != .None || segment_bytes == nil {
		mem.free(raw_data(start_bytes), allocator)
		mem.free(raw_data(frame_bytes), allocator)
		mem.free(raw_data(sample_bytes), allocator)
		return false
	}
	gap_bytes, gap_err := mem.alloc_bytes(ledger_capacity * size_of(Discontinuity), align_of(Discontinuity), allocator)
	if gap_err != .None || gap_bytes == nil {
		mem.free(raw_data(segment_bytes), allocator)
		mem.free(raw_data(start_bytes), allocator)
		mem.free(raw_data(frame_bytes), allocator)
		mem.free(raw_data(sample_bytes), allocator)
		return false
	}

	ring^ = Audio_Ring{
		samples = mem.slice_data_cast([]f32, sample_bytes),
		slot_frames = mem.slice_data_cast([]u32, frame_bytes),
		slot_start_frames = mem.slice_data_cast([]u64, start_bytes),
		slot_segments = mem.slice_data_cast([]u64, segment_bytes),
		gaps = mem.slice_data_cast([]Discontinuity, gap_bytes),
		capacity_blocks = capacity_blocks,
		max_block_frames = max_block_frames,
		channels = channels,
		first_frame = first_frame,
		epoch = epoch,
		allocator = allocator,
		gap_capacity = ledger_capacity,
		source_frame_pos = u64(first_frame),
	}
	return true
}

audio_ring_destroy :: proc(ring: ^Audio_Ring) {
	if ring.samples != nil {
		mem.free(raw_data(ring.samples), ring.allocator)
	}
	if ring.slot_frames != nil {
		mem.free(raw_data(ring.slot_frames), ring.allocator)
	}
	if ring.slot_segments != nil {
		mem.free(raw_data(ring.slot_segments), ring.allocator)
	}
	if ring.slot_start_frames != nil {
		mem.free(raw_data(ring.slot_start_frames), ring.allocator)
	}
	if ring.gaps != nil {
		mem.free(raw_data(ring.gaps), ring.allocator)
	}
	ring^ = {}
}

// audio_ring_block_samples is the capacity, in samples, of one slot. It is the
// smallest destination audio_ring_read accepts.
audio_ring_block_samples :: proc(ring: ^Audio_Ring) -> int {
	return ring.max_block_frames * ring.channels
}

audio_ring_max_block_frames :: proc(ring: ^Audio_Ring) -> int {
	return ring.max_block_frames
}

audio_ring_source_frame_pos :: proc(ring: ^Audio_Ring) -> u64 {
	// Advisory observation of a writer-owned counter. It is atomic so a
	// concurrent observer cannot race the writer, but it is not a
	// synchronization edge; callers that need a consistent data view use
	// audio_ring_read instead.
	return sync.atomic_load_explicit(&ring.source_frame_pos, .Relaxed)
}

// audio_ring_push enqueues one variable-length block at an explicit absolute
// source frame index. See the package comment for gap, duplicate and overrun
// semantics. `block.start_frame` must agree with `source_frame_index`.
audio_ring_push :: proc(ring: ^Audio_Ring, block: stream.Audio_Block, source_frame_index: u64) -> Audio_Ring_Push_Status {
	if !stream.audio_block_valid(block) {
		return .Rejected_Invalid
	}
	if block.frames < 1 || block.frames > ring.max_block_frames || block.channels != ring.channels {
		return .Rejected_Invalid
	}
	if block.start_frame < 0 || u64(block.start_frame) != source_frame_index {
		return .Rejected_Invalid
	}

	expected := sync.atomic_load_explicit(&ring.source_frame_pos, .Relaxed)
	if source_frame_index < expected {
		// Already consumed or already lost. Never rewind the source clock and
		// never enqueue overlapping data.
		sync.atomic_add_explicit(&ring.duplicate_blocks, 1, .Relaxed)
		return .Rejected_Duplicate
	}

	had_gap := false
	if source_frame_index > expected {
		// The source produced frames we never saw. Advance the absolute clock
		// and publish the lost range as its own segment.
		ring.continuity_epoch += 1
		ring_record_gap(ring, expected, source_frame_index - expected, ring.continuity_epoch, .Source_Gap)
		sync.atomic_store_explicit(&ring.source_frame_pos, source_frame_index, .Relaxed)
		had_gap = true
	}

	frames := u64(block.frames)
	write_index := sync.atomic_load_explicit(&ring.write_blocks, .Relaxed)
	read_index := sync.atomic_load_explicit(&ring.read_blocks, .Acquire)
	if write_index - read_index >= u64(ring.capacity_blocks) {
		// The block existed at the source but cannot be stored. Record the lost
		// range and advance the clock: a live producer cannot resubmit it.
		ring.continuity_epoch += 1
		ring_record_gap(ring, source_frame_index, frames, ring.continuity_epoch, .Overrun_Drop)
		sync.atomic_store_explicit(&ring.source_frame_pos, source_frame_index + frames, .Relaxed)
		sync.atomic_add_explicit(&ring.dropped_blocks, 1, .Relaxed)
		sync.atomic_store_explicit(&ring.overrun_latched, 1, .Release)
		return .Dropped_Overrun
	}

	slot := int(write_index % u64(ring.capacity_blocks))
	sample_base := slot * ring.max_block_frames * ring.channels
	sample_count := block.frames * ring.channels
	copy(ring.samples[sample_base : sample_base + sample_count], block.interleaved[:sample_count])
	ring.slot_frames[slot] = u32(block.frames)
	ring.slot_start_frames[slot] = source_frame_index
	ring.slot_segments[slot] = ring.continuity_epoch

	new_index := write_index + 1
	sync.atomic_store_explicit(&ring.write_blocks, new_index, .Release)
	sync.atomic_store_explicit(&ring.source_frame_pos, source_frame_index + frames, .Relaxed)

	depth := new_index - read_index
	high := sync.atomic_load_explicit(&ring.high_water_blocks, .Relaxed)
	if depth > high {
		sync.atomic_store_explicit(&ring.high_water_blocks, depth, .Relaxed)
	}
	if had_gap {
		return .Accepted_With_Gap
	}
	return .Accepted
}

// audio_ring_record_gap appends one lost range to the ledger. The last-resort
// overflow latch makes an incomplete ledger explicit rather than silently
// stitching a window across unrecorded loss.
@(private = "file")
ring_record_gap :: proc(
	ring: ^Audio_Ring,
	start_frame, frames, continuity_epoch: u64,
	reason: Discontinuity_Reason,
) {
	if frames == 0 {
		return
	}
	write_index := sync.atomic_load_explicit(&ring.gap_write, .Relaxed)
	read_index := sync.atomic_load_explicit(&ring.gap_read, .Acquire)
	if write_index - read_index >= u64(ring.gap_capacity) {
		sync.atomic_store_explicit(&ring.ledger_overflow_latched, 1, .Release)
		return
	}
	slot := int(write_index % u64(ring.gap_capacity))
	ring.gaps[slot] = Discontinuity{
		epoch = ring.epoch,
		continuity_epoch = continuity_epoch,
		start_frame = start_frame,
		frames = frames,
		reason = reason,
	}
	sync.atomic_store_explicit(&ring.gap_write, write_index + 1, .Release)
}

Audio_Ring_Read :: struct {
	frames:            int,
	start_frame:       i64,
	epoch:             u64,
	continuity_epoch:  u64,
	ok:                bool,
}

// audio_ring_read copies one variable-length block into `destination`.
// Allocating `audio_ring_block_samples` elements (the configured maximum) is
// always sufficient. Empty returns ok=false. If `destination` cannot hold this
// block, the block is left queued and `frames` reports the required frame
// count, so the caller can retry with a larger buffer.
audio_ring_read :: proc(ring: ^Audio_Ring, destination: []f32) -> Audio_Ring_Read {
	read_index := sync.atomic_load_explicit(&ring.read_blocks, .Relaxed)
	write_index := sync.atomic_load_explicit(&ring.write_blocks, .Acquire)
	if read_index == write_index {
		return {}
	}
	slot := int(read_index % u64(ring.capacity_blocks))
	frames := int(ring.slot_frames[slot])
	required := frames * ring.channels
	if len(destination) < required {
		return Audio_Ring_Read{frames = frames}
	}
	source_base := slot * ring.max_block_frames * ring.channels
	copy(destination[:required], ring.samples[source_base : source_base + required])
	result := Audio_Ring_Read{
		frames = frames,
		start_frame = i64(ring.slot_start_frames[slot]),
		epoch = ring.epoch,
		continuity_epoch = ring.slot_segments[slot],
		ok = true,
	}
	sync.atomic_store_explicit(&ring.read_blocks, read_index + 1, .Release)
	return result
}

// audio_ring_next_discontinuity dequeues one ledger record. Ranges are
// absolute and remain valid even when read after newer data blocks have been
// dequeued; pair the record's continuity_epoch with each read result.
audio_ring_next_discontinuity :: proc(ring: ^Audio_Ring, discontinuity: ^Discontinuity) -> bool {
	read_index := sync.atomic_load_explicit(&ring.gap_read, .Relaxed)
	write_index := sync.atomic_load_explicit(&ring.gap_write, .Acquire)
	if read_index == write_index {
		return false
	}
	slot := int(read_index % u64(ring.gap_capacity))
	discontinuity^ = ring.gaps[slot]
	sync.atomic_store_explicit(&ring.gap_read, read_index + 1, .Release)
	return true
}

audio_ring_overrun_seen :: proc(ring: ^Audio_Ring) -> bool {
	return sync.atomic_load_explicit(&ring.overrun_latched, .Acquire) != 0
}

audio_ring_ledger_overflow_seen :: proc(ring: ^Audio_Ring) -> bool {
	return sync.atomic_load_explicit(&ring.ledger_overflow_latched, .Acquire) != 0
}

audio_ring_dropped_blocks :: proc(ring: ^Audio_Ring) -> u64 {
	return sync.atomic_load_explicit(&ring.dropped_blocks, .Relaxed)
}

audio_ring_duplicate_blocks :: proc(ring: ^Audio_Ring) -> u64 {
	return sync.atomic_load_explicit(&ring.duplicate_blocks, .Relaxed)
}

audio_ring_high_water :: proc(ring: ^Audio_Ring) -> u64 {
	return sync.atomic_load_explicit(&ring.high_water_blocks, .Relaxed)
}

audio_ring_depth :: proc(ring: ^Audio_Ring) -> u64 {
	write_index := sync.atomic_load_explicit(&ring.write_blocks, .Acquire)
	read_index := sync.atomic_load_explicit(&ring.read_blocks, .Acquire)
	return write_index - read_index
}

audio_ring_gaps_recorded :: proc(ring: ^Audio_Ring) -> u64 {
	return sync.atomic_load_explicit(&ring.gap_write, .Acquire)
}

audio_ring_gaps_pending :: proc(ring: ^Audio_Ring) -> u64 {
	write_index := sync.atomic_load_explicit(&ring.gap_write, .Acquire)
	read_index := sync.atomic_load_explicit(&ring.gap_read, .Acquire)
	return write_index - read_index
}

// audio_ring_reset clears both indices, the source clock, the segment counter,
// the discontinuity ledger, the overrun/ledger latches and counters. It must
// only be called when producer and consumer are stopped. Reading resumes at the
// ring's configured `first_frame` and `epoch`.
audio_ring_reset :: proc(ring: ^Audio_Ring) {
	sync.atomic_store_explicit(&ring.write_blocks, 0, .Relaxed)
	sync.atomic_store_explicit(&ring.read_blocks, 0, .Relaxed)
	sync.atomic_store_explicit(&ring.dropped_blocks, 0, .Relaxed)
	sync.atomic_store_explicit(&ring.duplicate_blocks, 0, .Relaxed)
	sync.atomic_store_explicit(&ring.high_water_blocks, 0, .Relaxed)
	sync.atomic_store_explicit(&ring.gap_write, 0, .Relaxed)
	sync.atomic_store_explicit(&ring.gap_read, 0, .Relaxed)
	sync.atomic_store_explicit(&ring.overrun_latched, 0, .Release)
	sync.atomic_store_explicit(&ring.ledger_overflow_latched, 0, .Release)
	sync.atomic_store_explicit(&ring.source_frame_pos, u64(ring.first_frame), .Relaxed)
	ring.continuity_epoch = 0
}
