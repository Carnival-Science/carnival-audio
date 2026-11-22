// Bounded single-producer/single-consumer block transport.
//
// The ring owns `capacity_blocks` fixed slots, each `block_frames` frames of
// `channels` interleaved f32 samples. All storage is allocated in init; write
// and read paths never allocate, lock or call into a platform API.
//
// Memory ordering (SPSC):
//   - writer copies samples, then publishes `write_blocks` with Release;
//   - reader observes `write_blocks` with Acquire, copies samples, then
//     publishes `read_blocks` with Release;
//   - writer observes `read_blocks` with Acquire before reusing a slot.
//
// Overrun is explicit and sticky: a write that finds the ring full is dropped,
// increments `dropped_blocks`, and latches `overrun_seen`. Downstream analysis
// must treat sample-complete measurements as invalid until an explicit reset,
// even after the ring drains.
package transport

import "core:mem"
import "core:sync"

import audio "pulse:core/audio"

Audio_Ring :: struct {
	samples:          []f32,
	capacity_blocks:  int,
	block_frames:     int,
	channels:         int,
	first_frame:      i64,
	epoch:            u64,
	allocator:        mem.Allocator,

	// Atomic u64 counters. Read/write indices are monotonic block counts, not
	// wrapped offsets; the slot is always `index % capacity_blocks`.
	write_blocks:     u64,
	read_blocks:      u64,
	dropped_blocks:   u64,
	high_water_blocks: u64,
	overrun_latched:  u64, // 0 or 1
}

audio_ring_init :: proc(
	ring: ^Audio_Ring,
	capacity_blocks, block_frames, channels: int,
	first_frame: i64 = 0,
	epoch: u64 = 0,
	allocator := context.allocator,
) -> bool {
	if capacity_blocks < 1 || block_frames < 1 || channels < 1 || channels > audio.MAX_CHANNELS || first_frame < 0 {
		return false
	}
	count := capacity_blocks * block_frames * channels
	if count <= 0 || count > 0x7FFF_FFFF {
		return false
	}
	bytes, err := mem.alloc_bytes(count * size_of(f32), align_of(f32), allocator)
	if err != .None || bytes == nil {
		return false
	}
	ring^ = Audio_Ring{
		samples = mem.slice_data_cast([]f32, bytes),
		capacity_blocks = capacity_blocks,
		block_frames = block_frames,
		channels = channels,
		first_frame = first_frame,
		epoch = epoch,
		allocator = allocator,
	}
	return true
}

audio_ring_destroy :: proc(ring: ^Audio_Ring) {
	if ring.samples != nil {
		mem.free(raw_data(ring.samples), ring.allocator)
	}
	ring^ = {}
}

audio_ring_block_samples :: proc(ring: ^Audio_Ring) -> int {
	return ring.block_frames * ring.channels
}

// audio_ring_write enqueues exactly one full block. The block's `start_frame`
// must equal the ring's next sample-clock position. Partial blocks and clock
// mismatches are rejected (the producer decides how to pad, end or reset a
// stream). Returns false on overrun.
audio_ring_write :: proc(ring: ^Audio_Ring, block: audio.Audio_Block) -> bool {
	if !audio.audio_block_valid(block) {
		return false
	}
	if block.frames != ring.block_frames || block.channels != ring.channels {
		return false
	}
	write_index := sync.atomic_load_explicit(&ring.write_blocks, .Relaxed)
	expected_start := ring.first_frame + i64(write_index) * i64(ring.block_frames)
	if block.start_frame != expected_start {
		// A producer-side gap or clock mismatch must be explicit, not silently
		// rewritten into a contiguous stream.
		return false
	}
	read_index := sync.atomic_load_explicit(&ring.read_blocks, .Acquire)
	if write_index - read_index >= u64(ring.capacity_blocks) {
		sync.atomic_add_explicit(&ring.dropped_blocks, 1, .Relaxed)
		sync.atomic_store_explicit(&ring.overrun_latched, 1, .Release)
		return false
	}
	slot := int(write_index % u64(ring.capacity_blocks))
	destination := ring.samples[slot * ring.block_frames * ring.channels : (slot + 1) * ring.block_frames * ring.channels]
	copy(destination, block.interleaved)
	new_index := write_index + 1
	sync.atomic_store_explicit(&ring.write_blocks, new_index, .Release)
	depth := new_index - read_index
	high := sync.atomic_load_explicit(&ring.high_water_blocks, .Relaxed)
	if depth > high {
		sync.atomic_store_explicit(&ring.high_water_blocks, depth, .Relaxed)
	}
	return true
}

Audio_Ring_Read :: struct {
	frames:      int,
	start_frame: i64,
	epoch:       u64,
	ok:          bool,
}

// audio_ring_read copies one full block into `destination`, whose length must be
// at least block_frames * channels. Empty returns ok=false.
audio_ring_read :: proc(ring: ^Audio_Ring, destination: []f32) -> Audio_Ring_Read {
	required := audio_ring_block_samples(ring)
	if len(destination) < required {
		return {}
	}
	read_index := sync.atomic_load_explicit(&ring.read_blocks, .Relaxed)
	write_index := sync.atomic_load_explicit(&ring.write_blocks, .Acquire)
	if read_index == write_index {
		return {}
	}
	slot := int(read_index % u64(ring.capacity_blocks))
	source := ring.samples[slot * ring.block_frames * ring.channels : (slot + 1) * ring.block_frames * ring.channels]
	copy(destination[:required], source)
	result := Audio_Ring_Read{
		frames = ring.block_frames,
		start_frame = ring.first_frame + i64(read_index) * i64(ring.block_frames),
		epoch = ring.epoch,
		ok = true,
	}
	sync.atomic_store_explicit(&ring.read_blocks, read_index + 1, .Release)
	return result
}

audio_ring_overrun_seen :: proc(ring: ^Audio_Ring) -> bool {
	return sync.atomic_load_explicit(&ring.overrun_latched, .Acquire) != 0
}

audio_ring_dropped_blocks :: proc(ring: ^Audio_Ring) -> u64 {
	return sync.atomic_load_explicit(&ring.dropped_blocks, .Relaxed)
}

audio_ring_high_water :: proc(ring: ^Audio_Ring) -> u64 {
	return sync.atomic_load_explicit(&ring.high_water_blocks, .Relaxed)
}

audio_ring_depth :: proc(ring: ^Audio_Ring) -> u64 {
	write_index := sync.atomic_load_explicit(&ring.write_blocks, .Acquire)
	read_index := sync.atomic_load_explicit(&ring.read_blocks, .Acquire)
	return write_index - read_index
}

// audio_ring_reset clears both indices, the overrun latch and counters. It must
// only be called when producer and consumer are stopped. Reading resumes at the
// ring's configured `first_frame` and `epoch`.
audio_ring_reset :: proc(ring: ^Audio_Ring) {
	sync.atomic_store_explicit(&ring.write_blocks, 0, .Relaxed)
	sync.atomic_store_explicit(&ring.read_blocks, 0, .Relaxed)
	sync.atomic_store_explicit(&ring.dropped_blocks, 0, .Relaxed)
	sync.atomic_store_explicit(&ring.high_water_blocks, 0, .Relaxed)
	sync.atomic_store_explicit(&ring.overrun_latched, 0, .Release)
}
