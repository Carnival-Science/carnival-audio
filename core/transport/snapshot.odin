// Revisioned measurement snapshots.
//
// A `Measurement_Snapshot` is a small, immutable-by-convention record of the
// latest scalar measurements. The publisher keeps two buffers: the writer fills
// the inactive one and then publishes an even generation with Release. Readers
// copy one buffer by value and verify the generation did not change. This is
// latest-wins and bounded: a reader that cannot obtain a stable copy within a
// few attempts gets `valid = false` rather than blocking or borrowing mutable
// state.
//
// Only one writer is assumed (the analysis worker). Any number of readers may
// copy concurrently. `snapshot_publisher_reset` is writer-only and must not run
// while readers are active.
package transport

import "core:sync"

// Measurement_Snapshot is the seam consumed by the standalone meter, the CLAP
// canonical export and the verification laboratory. Field order is part of the
// canonical fingerprint; do not reorder without updating snapshot_fingerprint
// and its repeatability test.
Measurement_Snapshot :: struct {
	generation:          u64,
	valid:               bool,
	overrun:             bool,
	epoch:               u64,
	frame:               i64,
	sample_rate:         int,
	channels:            int,
	peak:                [2]f32,
	peak_frame:          [2]i64,
	peak_db:             [2]f32,
	rms:                 [2]f32,
	rms_db:              [2]f32,
	hold:                [2]f32,
	hold_db:             [2]f32,
	correlation:         f32,
	correlation_valid:   bool,
}

Snapshot_Publisher :: struct {
	buffers:    [2]Measurement_Snapshot,
	generation: u64, // atomic; even when stable, zero before first publish
}

// snapshot_publish stores `snapshot` as the latest value, assigns its
// generation and returns that generation. Writer-only.
snapshot_publish :: proc(publisher: ^Snapshot_Publisher, snapshot: Measurement_Snapshot) -> u64 {
	generation := sync.atomic_load_explicit(&publisher.generation, .Relaxed)
	index := int((generation / 2) & 1)
	next_generation := generation + 2
	record := snapshot
	record.generation = next_generation
	publisher.buffers[index] = record
	sync.atomic_store_explicit(&publisher.generation, next_generation, .Release)
	return next_generation
}

// snapshot_read returns a stable copy, or a zero/invalid snapshot if no value
// has been published or no stable copy was available within the retry bound.
snapshot_read :: proc(publisher: ^Snapshot_Publisher) -> Measurement_Snapshot {
	for _ in 0 ..< 8 {
		first := sync.atomic_load_explicit(&publisher.generation, .Acquire)
		if first == 0 {
			return {}
		}
		index := int(((first / 2) + 1) & 1)
		snapshot := publisher.buffers[index]
		second := sync.atomic_load_explicit(&publisher.generation, .Acquire)
		if first == second && snapshot.generation == first {
			return snapshot
		}
	}
	return Measurement_Snapshot{valid = false}
}

snapshot_publisher_reset :: proc(publisher: ^Snapshot_Publisher) {
	publisher.buffers = {}
	sync.atomic_store_explicit(&publisher.generation, 0, .Release)
}

snapshot_generation :: proc(publisher: ^Snapshot_Publisher) -> u64 {
	return sync.atomic_load_explicit(&publisher.generation, .Acquire)
}

// snapshot_fingerprint hashes the canonical scalar fields in declaration order
// (FNV-1a over the bit patterns). It ignores struct padding, so it is stable
// across compilers and runs; it is the regression signal for repeatability.
snapshot_fingerprint :: proc(snapshot: Measurement_Snapshot) -> u64 {
	hash: u64 = 0xcbf29ce484222325
	snapshot_hash_u64(&hash, snapshot.generation)
	snapshot_hash_bool(&hash, snapshot.valid)
	snapshot_hash_bool(&hash, snapshot.overrun)
	snapshot_hash_u64(&hash, snapshot.epoch)
	snapshot_hash_u64(&hash, u64(snapshot.frame))
	snapshot_hash_u64(&hash, u64(snapshot.sample_rate))
	snapshot_hash_u64(&hash, u64(snapshot.channels))
	for index in 0 ..< 2 {
		snapshot_hash_f32(&hash, snapshot.peak[index])
		snapshot_hash_u64(&hash, u64(snapshot.peak_frame[index]))
		snapshot_hash_f32(&hash, snapshot.peak_db[index])
		snapshot_hash_f32(&hash, snapshot.rms[index])
		snapshot_hash_f32(&hash, snapshot.rms_db[index])
		snapshot_hash_f32(&hash, snapshot.hold[index])
		snapshot_hash_f32(&hash, snapshot.hold_db[index])
	}
	snapshot_hash_f32(&hash, snapshot.correlation)
	snapshot_hash_bool(&hash, snapshot.correlation_valid)
	return hash
}

@(private = "file")
snapshot_hash_f32 :: proc(hash: ^u64, value: f32) {
	snapshot_hash_u64(hash, u64(transmute(u32)value))
}

@(private = "file")
snapshot_hash_bool :: proc(hash: ^u64, value: bool) {
	snapshot_hash_u64(hash, u64(value))
}

@(private = "file")
snapshot_hash_u64 :: proc(hash: ^u64, value: u64) {
	for shift in 0 ..< 8 {
		hash^ ~= u64(byte(value >> (8 * u64(shift))))
		hash^ *= 0x100000001b3
	}
}
