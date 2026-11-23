// Revisioned measurement snapshots.
//
// A `Measurement_Snapshot` is a small, immutable-by-convention record of the
// latest scalar measurements. Publication is a single-writer, multi-reader
// seqlock over atomic 64-bit words:
//
//   writer: sequence++ (odd)  -> publish full record -> sequence++ (even)
//   reader: read even seq, copy record, re-read seq; accept iff unchanged
//
// Why a seqlock rather than a rotating buffer: the record is a fixed-size
// scalar record, so a stable copy needs only a handful of word loads and the
// sequence re-check proves the writer did not touch the storage during that
// copy. It is latest-wins, lock-free and bounded: a reader that loses the race
// `SNAPSHOT_READ_RETRIES` times returns `valid = false` instead of blocking or
// borrowing mutable state.
//
// Correctness argument
// --------------------
// The record storage is copied one `u64` at a time with atomic loads/stores.
// There is therefore no concurrent non-atomic access to the storage: a reader
// never performs a data race even while the writer is publishing. The sequence
// counter is the publication edge:
//
//   - The writer stores `odd` with Seq_Cst, then emits a Seq_Cst fence before
//     touching the words. A reader that observes `odd` knows a publication is
//     in progress and does not attempt to use the record.
//   - The writer stores `even` with Seq_Cst after all word stores. That store
//     is the publication: a reader whose first sequence load observed this
//     value is guaranteed (Acquire/Seq_Cst) to see the complete record.
//   - The reader loads the sequence, copies the words, executes a Seq_Cst
//     fence, then re-loads the sequence. A full fence prevents the word loads
//     from moving past the second sequence load. If the two sequence values
//     are equal and even, the writer never entered its odd phase during the
//     copy: any publication in that window would have changed the counter.
//     A successful read is consequently a complete value, not a torn mix.
//   - If the sequence changed (or is odd), the copy is discarded. No torn
//     value is ever returned; the only failure mode is a bounded-retry
//     `valid = false`.
//
// Generations increase by two per publication (the even sequence value), so
// `generation == 0` still means "nothing published". `snapshot_generation`
// masks the transient odd phase and never exposes it to callers.
//
// Only one writer is assumed (the analysis worker). Any number of readers may
// copy concurrently. `snapshot_publisher_reset` is writer-only and must not run
// while readers are active.
package transport

import "core:sync"

// SNAPSHOT_READ_RETRIES bounds how many stable-copy attempts a reader makes
// before returning an invalid snapshot. It is a liveness bound, not a
// correctness one: a snapshot returned as valid has always passed the
// sequence re-check.
SNAPSHOT_READ_RETRIES :: 64

// SNAPSHOT_SCHEMA_VERSION documents the presentation record layout. It is
// separate from the canonical Measurement_Record schema (core/meter): snapshots
// are latest-wins presentation state, not the verification wire format.
//
// Schema 2 separates the three peak presentation values:
//   - `window_peak`: the current analysis window;
//   - `peak_hold`: the existing hold/decay envelope;
//   - `session_max`: the maximum since the current analysis epoch began.
SNAPSHOT_SCHEMA_VERSION :: u32(2)

// Measurement_Snapshot is the seam consumed by the standalone meter, the CLAP
// canonical export and the verification laboratory. Field order is part of the
// canonical fingerprint; do not reorder without updating snapshot_fingerprint
// and its repeatability test.
Measurement_Snapshot :: struct {
	generation:          u64,
	schema_version:      u32,
	valid:               bool,
	overrun:             bool,
	window_valid:        bool,
	epoch:               u64,
	frame:               i64,
	sample_rate:         int,
	channels:            int,
	window_peak:         [2]f32,
	window_peak_frame:   [2]i64,
	window_peak_db:      [2]f32,
	rms:                 [2]f32,
	rms_db:              [2]f32,
	peak_hold:           [2]f32,
	peak_hold_db:        [2]f32,
	session_max:         [2]f32,
	session_max_db:      [2]f32,
	correlation:         f32,
	correlation_valid:   bool,
}

// The seqlock copies whole u64 words from the record. The assertion keeps the
// word count exact rather than silently dropping a trailing partial word.
SNAPSHOT_WORD_COUNT :: size_of(Measurement_Snapshot) / size_of(u64)
#assert(size_of(Measurement_Snapshot) % size_of(u64) == 0)

Snapshot_Publisher :: struct {
	// Atomic seqlock counter: odd while a publication is in flight, even with
	// the latest generation otherwise, zero before the first publication.
	sequence: u64,
	// Atomic u64 words holding one Measurement_Snapshot. Words are the only
	// permitted access path to this storage after the publisher is shared.
	storage:  [SNAPSHOT_WORD_COUNT]u64,
}

// snapshot_publish stores `snapshot` as the latest value, assigns its
// generation and returns that generation. Writer-only.
snapshot_publish :: proc(publisher: ^Snapshot_Publisher, snapshot: Measurement_Snapshot) -> u64 {
	previous := sync.atomic_load_explicit(&publisher.sequence, .Relaxed)
	next_generation := previous + 2
	record := snapshot
	record.generation = next_generation

	// Enter the odd phase. The fence keeps the record stores below from moving
	// before readers can observe the odd sequence value.
	sync.atomic_store_explicit(&publisher.sequence, previous + 1, .Seq_Cst)
	sync.atomic_thread_fence(.Seq_Cst)

	source := cast([^]u64)(&record)
	for index in 0 ..< SNAPSHOT_WORD_COUNT {
		sync.atomic_store_explicit(&publisher.storage[index], source[index], .Relaxed)
	}

	// Leave the odd phase. This store is the publication edge: it orders every
	// word store above it and gives readers a stable even value to re-check.
	sync.atomic_store_explicit(&publisher.sequence, next_generation, .Seq_Cst)
	return next_generation
}

// snapshot_read returns a stable copy, or a zero/invalid snapshot if no value
// has been published or no stable copy was available within the retry bound.
// The returned value is a private copy; the publisher may publish again
// immediately. `attempts`, when non-nil, reports how many stable-copy attempts
// were made, which makes the retry bound observable to stress tests.
snapshot_read :: proc(publisher: ^Snapshot_Publisher, attempts: ^int = nil) -> Measurement_Snapshot {
	for attempt in 0 ..< SNAPSHOT_READ_RETRIES {
		first := sync.atomic_load_explicit(&publisher.sequence, .Seq_Cst)
		if first == 0 {
			if attempts != nil {
				attempts^ = attempt + 1
			}
			return {}
		}
		if first & 1 != 0 {
			// A publication is in flight. Let the writer finish rather than
			// copying half a record and immediately retrying.
			sync.cpu_relax()
			continue
		}

		record: Measurement_Snapshot
		destination := cast([^]u64)(&record)
		for index in 0 ..< SNAPSHOT_WORD_COUNT {
			destination[index] = sync.atomic_load_explicit(&publisher.storage[index], .Relaxed)
		}
		sync.atomic_thread_fence(.Seq_Cst)

		second := sync.atomic_load_explicit(&publisher.sequence, .Seq_Cst)
		if first == second && second & 1 == 0 && record.generation == second {
			if attempts != nil {
				attempts^ = attempt + 1
			}
			return record
		}
		sync.cpu_relax()
	}
	if attempts != nil {
		attempts^ = SNAPSHOT_READ_RETRIES
	}
	return Measurement_Snapshot{valid = false}
}

snapshot_publisher_reset :: proc(publisher: ^Snapshot_Publisher) {
	publisher^ = {}
}

// snapshot_generation returns the latest complete generation. The transient odd
// phase of an in-flight publication is never exposed.
snapshot_generation :: proc(publisher: ^Snapshot_Publisher) -> u64 {
	sequence := sync.atomic_load_explicit(&publisher.sequence, .Seq_Cst)
	return sequence & ~u64(1)
}

// snapshot_fingerprint hashes the canonical scalar fields in declaration order
// (FNV-1a over the bit patterns). It ignores struct padding, so it is stable
// across compilers and runs; it is the regression signal for repeatability.
snapshot_fingerprint :: proc(snapshot: Measurement_Snapshot) -> u64 {
	hash: u64 = 0xcbf29ce484222325
	snapshot_hash_u64(&hash, snapshot.generation)
	snapshot_hash_u64(&hash, u64(snapshot.schema_version))
	snapshot_hash_bool(&hash, snapshot.valid)
	snapshot_hash_bool(&hash, snapshot.overrun)
	snapshot_hash_bool(&hash, snapshot.window_valid)
	snapshot_hash_u64(&hash, snapshot.epoch)
	snapshot_hash_u64(&hash, u64(snapshot.frame))
	snapshot_hash_u64(&hash, u64(snapshot.sample_rate))
	snapshot_hash_u64(&hash, u64(snapshot.channels))
	for index in 0 ..< 2 {
		snapshot_hash_f32(&hash, snapshot.window_peak[index])
		snapshot_hash_u64(&hash, u64(snapshot.window_peak_frame[index]))
		snapshot_hash_f32(&hash, snapshot.window_peak_db[index])
		snapshot_hash_f32(&hash, snapshot.rms[index])
		snapshot_hash_f32(&hash, snapshot.rms_db[index])
		snapshot_hash_f32(&hash, snapshot.peak_hold[index])
		snapshot_hash_f32(&hash, snapshot.peak_hold_db[index])
		snapshot_hash_f32(&hash, snapshot.session_max[index])
		snapshot_hash_f32(&hash, snapshot.session_max_db[index])
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
