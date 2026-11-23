// Source-independent meter analysis engine.
//
// This package is the reusable analysis foundation behind two consumers: the
// headless CLAP adapter in `products/pulse` and the standalone capture meter in
// `products/pulse-mini`. It owns:
//
//   - windowed sample peak, RMS and peak-hold analysis (`core/dsp`);
//   - the absolute source frame clock, continuity segments and gaps;
//   - audio-domain validity and capture-domain records/queue;
//   - the revisioned presentation snapshot (`core/transport`).
//
// It imports only Odin `core:` packages and sibling core packages. It must not
// import CLAP, Alicorn, miniaudio, a platform backend, `adapters/`, `products/`
// or `verification/`; `tools/check-boundary.ps1` enforces that.
//
// Intake contract
// ---------------
// Both consumers push variable-length blocks with an explicit frame count and
// an explicit source clock:
//
//   engine_push_interleaved: capture path. `steady_time < 0` means the source
//       clock advances by the delivered frame count. The capture adapter owns
//       delivery; an idle device must NOT fabricate silence here. It reports a
//       stall and calls engine_note_discontinuity before delivery resumes.
//
//   engine_push_passthrough: CLAP path. It copies planar input to planar output
//       sample-for-sample and pushes the same frames. A non-negative
//       `steady_time` is the host's steady sample position; a forward jump
//       larger than the previous block's frame count is a source gap. The
//       expected next position uses the previous block's frame count, so
//       variable-length host blocks are not mistaken for gaps.
//
// Gaps -> epochs/segments
// -----------------------
// A forward jump records a `transport.Discontinuity` and starts a new
// continuity segment. No RMS window straddles the gap: the window restarts at
// the post-gap absolute frame. `engine_note_discontinuity` (used on stall,
// device switch/disconnect or capture-ring overrun) additionally advances the
// analysis epoch so records from before and after the discontinuity cannot be
// mistaken for one continuous timeline.
//
// Validity is per window and per epoch, not a sticky global latch. The
// discontinuity ledger keeps the historical record of what was lost; the first
// window after a boundary is marked invalid (the affected/boundary window);
// later windows whose frames are contiguous are valid again. A snapshot is
// published immediately when a discontinuity is noted, even if no audio
// follows, so presentation never waits for the next block to learn that the
// measurement is no longer live.
//
// Real-time contract: reset, activation and draining allocate; the push paths,
// window callback and snapshot publication never allocate, lock or perform I/O.
package meter

import "base:runtime"
import "core:mem"
import "core:sync"

import "carnival:core/dsp"
import "carnival:core/stream"
import "carnival:core/transport"

CHANNELS :: 2

RING_CAPACITY_BLOCKS :: 16
RING_GAP_CAPACITY :: 32
MEASUREMENT_QUEUE_CAPACITY :: 4096
ENGINE_LEDGER_CAPACITY :: 64

// Discontinuity_Event records why an analysis epoch ended. It is the engine's
// historical completeness ledger, deliberately separate from current-window
// validity: a lost range stays in the record even after later windows are valid.
Discontinuity_Event :: enum u8 {
	Source_Gap,        // host steady-clock forward jump
	Transport_Overrun, // the bounded analysis ring dropped a block
	Stall,             // capture endpoint delivered no data
	Device_Lost,       // endpoint removal/switch (no deliverable data)
	Device_Recovered,  // endpoint reopened; new epoch boundary
	Capture_Overrun,   // capture ring dropped frames before engine intake
	Rejected_Block,    // duplicate/stale or malformed source range
}

Engine_Discontinuity :: struct {
	epoch:       u64,
	start_frame: i64,
	frames:      u64, // 0 when the lost duration is unknown (an idle stall)
	event:       Discontinuity_Event,
}

// Default authoring parameters. The CLAP product overwrites them from its
// parameter table every block; the standalone product sets them once.
DEFAULT_WINDOW_FRAMES :: 1024
DEFAULT_HOLD_FRAMES :: 4800
DEFAULT_HOLD_DECAY_DB :: f32(20)

// MEASUREMENT_SCHEMA_VERSION is the canonical record schema. The draft CLAP
// telemetry wire record re-declares this layout in `third_party/clap/abi`;
// `products/pulse` asserts the sizes agree and converts at the ABI boundary.
MEASUREMENT_SCHEMA_VERSION :: u32(1)

// Measurement_Record is one complete, sample-clock-aligned RMS window.
// `valid`/`overrun` are audio-domain; `capture_valid` is capture-domain only.
Measurement_Record :: struct {
	schema_version: u32,
	epoch:          u64,
	generation:     u64,
	start_frame:    i64,
	frames:         u32,
	channels:       u32,
	sample_rate:    u32,
	peak:           [CHANNELS]f32,
	peak_frame:     [CHANNELS]i64,
	rms:            [CHANNELS]f32,
	hold:           [CHANNELS]f32,
	valid:          bool,
	overrun:        bool,
	capture_valid:  bool,
}

// Measurement_Sink receives records oldest-first. The pointer is valid only for
// the duration of the callback; returning false stops the drain without
// consuming that record.
Measurement_Sink :: struct {
	ctx:  rawptr,
	push: proc(ctx: rawptr, record: ^Measurement_Record) -> bool,
}

// Capture_Set_Result is the outcome of an attempt to start or end a capture
// episode. An episode switch requires quiescent processing: the audio thread
// may be inside a publication and the episode reset clears the queue. `Busy`
// means nothing changed; stop processing first.
Capture_Set_Result :: enum u8 {
	Ok,
	Busy,
}

// Push_Result reports how one intake block related to the source clock.
Push_Result :: enum u8 {
	Accepted,          // contiguous
	Accepted_With_Gap, // enqueued after one or more lost frames were recorded
	Rejected,          // invalid/oversized block, or a duplicate source range
	Overrun,           // the bounded transport ring was full
}

// Parameters is the authoring configuration applied at a block boundary.
Parameters :: struct {
	window_frames:     int,
	hold_frames:       int,
	hold_decay_enabled: bool,
	hold_decay_db:     f32,
}

default_parameters :: proc() -> Parameters {
	return Parameters{
		window_frames = DEFAULT_WINDOW_FRAMES,
		hold_frames = DEFAULT_HOLD_FRAMES,
		hold_decay_enabled = true,
		hold_decay_db = DEFAULT_HOLD_DECAY_DB,
	}
}

Record_Queue :: struct {
	records:  []Measurement_Record,
	capacity: int,
	write:    u64, // atomic; total records appended
	read:     u64, // atomic; total records drained
	dropped:  u64, // atomic; records lost because the consumer did not drain
	high_water: u64, // atomic; maximum pending records observed
}

Engine :: struct {
	allocator:    mem.Allocator,

	// Activation configuration.
	active:       bool,
	sample_rate:  f64,
	max_frames:   int,

	// Preallocated real-time storage.
	ring:         transport.Audio_Ring,
	staging:      []f32, // interleaved analysis copy, max_frames * CHANNELS
	drain:        []f32,
	queue:        Record_Queue,
	publisher:    transport.Snapshot_Publisher,

	// Processing state (never authoring state).
	epoch:        u64,
	frame_clock:  i64,
	// Host-clock discontinuity tracking.
	last_steady_time:   i64,
	last_block_frames:  int,
	steady_initialized: bool,
	// Continuity segment of the last block fed to analysis.
	processed_segment: u64,
	// Session maximum since the current epoch began. Reset on an epoch bump.
	session_max:  dsp.Peak_Accumulator,
	window_peak:  dsp.Peak_Accumulator,
	rms:          dsp.RMS_Window,
	hold:         dsp.Peak_Hold,
	last_rms:     [CHANNELS]f32,
	last_rms_start: i64,
	last_window_peak: [CHANNELS]dsp.Sample_Peak,
	have_window:  bool,

	// Per-window/per-epoch audio validity. `window_valid` describes the window
	// currently being assembled; `boundary_pending` marks the first window after
	// an epoch/continuity boundary as the affected window; `last_window_valid`
	// is the validity of the most recently completed window (presentation).
	// No global latch survives a valid new epoch.
	window_valid:      bool,
	boundary_pending:  bool,
	last_window_valid: bool,
	// Presentation may not show a pre-gap backlog as the live reading. The
	// flag clears when the first post-boundary block is analysed.
	awaiting_resume:     bool,
	resume_frame:        i64,
	ledger_overflow_seen: bool,

	// Historical completeness ledger. It is append-only for the lifetime of an
	// activation and never used to decide whether a later window is valid.
	discontinuities:          [ENGINE_LEDGER_CAPACITY]Engine_Discontinuity,
	discontinuity_count:      u64,
	discontinuity_overflowed: bool,

	// Capture domain. Capture is opt-in; when disabled no records are produced
	// at all, so the queue cannot become a lifecycle hazard.
	capture_enabled: u32, // atomic bool bit; 0 = off (default)
	capture_invalid: u32, // atomic bool bit; 1 = a record was dropped

	processed_blocks: u64,
	generation:   u64,
	record_generation: u64,

	// Quiescence. A capture episode switch is refused while true.
	processing: bool,

	// Authoring values as last seen at a block boundary.
	window_frames: int,
	hold_frames:   int,
	hold_decay_enabled: bool,
	hold_decay_db: f32,

	// Test seam only: when false the ring is not drained, so a test can force
	// queue saturation without changing passthrough.
	drain_enabled: bool,
}

engine_create :: proc(engine_allocator: mem.Allocator = {}) -> ^Engine {
	allocator := engine_allocator
	if allocator.procedure == nil {
		allocator = runtime.default_allocator()
	}
	engine := new(Engine, allocator)
	if engine == nil {
		return nil
	}
	engine.allocator = allocator
	engine.drain_enabled = true
	engine.epoch = 1
	engine.capture_enabled = 0
	engine.capture_invalid = 0
	parameters := default_parameters()
	engine.window_frames = parameters.window_frames
	engine.hold_frames = parameters.hold_frames
	engine.hold_decay_enabled = parameters.hold_decay_enabled
	engine.hold_decay_db = parameters.hold_decay_db
	_ = dsp.peak_accumulator_init(&engine.session_max, CHANNELS)
	_ = dsp.peak_accumulator_init(&engine.window_peak, CHANNELS)
	return engine
}

engine_destroy :: proc(engine: ^Engine) {
	if engine == nil {
		return
	}
	engine_deactivate(engine)
	free(engine, engine.allocator)
}

engine_activate :: proc(engine: ^Engine, sample_rate: f64, max_block_frames: int) -> bool {
	if engine == nil || engine.active {
		return false
	}
	if sample_rate <= 0 || max_block_frames < 1 {
		return false
	}
	max_frames := max_block_frames
	if !transport.audio_ring_init(&engine.ring, RING_CAPACITY_BLOCKS, max_frames, CHANNELS,
			0, engine.epoch, engine.allocator, RING_GAP_CAPACITY) {
		return false
	}
	sample_count := max_frames * CHANNELS
	staging, staging_err := mem.alloc_bytes(sample_count * size_of(f32), align_of(f32), engine.allocator)
	if staging_err != .None || staging == nil {
		transport.audio_ring_destroy(&engine.ring)
		return false
	}
	drain, drain_err := mem.alloc_bytes(sample_count * size_of(f32), align_of(f32), engine.allocator)
	if drain_err != .None || drain == nil {
		mem.free(raw_data(staging), engine.allocator)
		transport.audio_ring_destroy(&engine.ring)
		return false
	}
	records, records_err := mem.alloc_bytes(MEASUREMENT_QUEUE_CAPACITY * size_of(Measurement_Record),
		align_of(Measurement_Record), engine.allocator)
	if records_err != .None || records == nil {
		mem.free(raw_data(drain), engine.allocator)
		mem.free(raw_data(staging), engine.allocator)
		transport.audio_ring_destroy(&engine.ring)
		return false
	}
	engine.staging = mem.slice_data_cast([]f32, staging)
	engine.drain = mem.slice_data_cast([]f32, drain)
	engine.queue.records = mem.slice_data_cast([]Measurement_Record, records)
	engine.queue.capacity = MEASUREMENT_QUEUE_CAPACITY
	engine.queue.write = 0
	engine.queue.read = 0
	engine.queue.dropped = 0
	engine.queue.high_water = 0
	engine.sample_rate = sample_rate
	engine.max_frames = max_frames
	engine.active = true
	engine.frame_clock = 0
	engine.generation = 0
	engine.record_generation = 0
	engine.capture_invalid = 0
	engine.have_window = false
	engine.last_rms = {}
	engine.last_rms_start = 0
	engine.processed_blocks = 0
	engine.last_steady_time = 0
	engine.last_block_frames = 0
	engine.steady_initialized = false
	engine.processed_segment = 0
	engine.processing = false
	engine.discontinuity_count = 0
	engine.discontinuity_overflowed = false
	engine.awaiting_resume = false
	engine.resume_frame = 0
	engine.ledger_overflow_seen = false
	engine_reset_analysis(engine)
	return true
}

engine_deactivate :: proc(engine: ^Engine) {
	if engine == nil {
		return
	}
	if engine.ring.samples != nil {
		transport.audio_ring_destroy(&engine.ring)
	}
	if engine.staging != nil {
		mem.free(raw_data(engine.staging), engine.allocator)
	}
	if engine.drain != nil {
		mem.free(raw_data(engine.drain), engine.allocator)
	}
	if engine.queue.records != nil {
		mem.free(raw_data(engine.queue.records), engine.allocator)
	}
	engine.staging = nil
	engine.drain = nil
	engine.queue = {}
	engine.active = false
	engine.max_frames = 0
}

// engine_reset restarts the sample clock and clears analysis and the canonical
// export queue. The historical discontinuity ledger is intentionally kept: a
// reset is a new epoch, not an erasure of what was already lost. Parameters are
// unchanged. The epoch advances so old and new records cannot be confused.
engine_reset :: proc(engine: ^Engine) {
	if engine == nil || !engine.active {
		return
	}
	engine.epoch += 1
	engine.frame_clock = 0
	transport.audio_ring_reset(&engine.ring)
	sync.atomic_store_explicit(&engine.queue.write, 0, .Release)
	sync.atomic_store_explicit(&engine.queue.read, 0, .Release)
	sync.atomic_store_explicit(&engine.queue.dropped, 0, .Release)
	sync.atomic_store_explicit(&engine.queue.high_water, 0, .Release)
	engine.capture_invalid = 0
	engine.have_window = false
	engine.last_rms = {}
	engine.last_rms_start = 0
	engine.processed_blocks = 0
	engine.record_generation = 0
	engine.last_steady_time = 0
	engine.last_block_frames = 0
	engine.steady_initialized = false
	engine.processed_segment = 0
	engine.awaiting_resume = false
	engine.resume_frame = 0
	engine.ledger_overflow_seen = false
	engine_reset_analysis(engine)
	transport.snapshot_publisher_reset(&engine.publisher)
}

// engine_note_discontinuity records a loss the source cannot account for (an
// idle capture device, an endpoint switch/disconnect or a capture-ring
// overrun). The source clock advances by `lost_frames` only when the caller
// knows that many frames were actually lost; pass 0 when the duration is
// unknown. Either way:
//
//   - the analysis epoch advances and the session maximum restarts;
//   - the affected/boundary window is pending-invalid; later contiguous
//     windows are valid without an explicit reset;
//   - a snapshot is published immediately, even if no audio follows, so a UI
//     observing snapshots learns of the discontinuity at once.
//
// The loss is appended to the historical completeness ledger; no silence is
// fabricated and no stale reading is presented as live.
engine_note_discontinuity :: proc(
	engine: ^Engine,
	lost_frames: u64,
	event: Discontinuity_Event = .Stall,
) {
	if engine == nil || !engine.active {
		return
	}
	loss_start := engine.frame_clock
	engine.epoch += 1
	if lost_frames > 0 {
		engine.frame_clock += i64(lost_frames)
	}
	engine_record_discontinuity(engine, loss_start, lost_frames, event)
	engine.have_window = false
	engine.last_rms = {}
	engine.last_rms_start = engine.frame_clock
	engine.processed_segment = 0
	engine_reset_analysis(engine)
	engine.boundary_pending = true
	engine.awaiting_resume = true
	engine.resume_frame = engine.frame_clock
	engine_publish_snapshot(engine)
}

// engine_discontinuity_count reports how many historical losses have been
// recorded by this activation. The count is not a validity latch.
engine_discontinuity_count :: proc(engine: ^Engine) -> int {
	if engine == nil {
		return 0
	}
	return int(min(engine.discontinuity_count, u64(ENGINE_LEDGER_CAPACITY)))
}

engine_discontinuity_overflowed :: proc(engine: ^Engine) -> bool {
	return engine != nil && engine.discontinuity_overflowed
}

// engine_discontinuity_at copies one ledger entry, oldest first.
engine_discontinuity_at :: proc(engine: ^Engine, index: int) -> (Engine_Discontinuity, bool) {
	if engine == nil || index < 0 || index >= engine_discontinuity_count(engine) {
		return {}, false
	}
	return engine.discontinuities[index], true
}

@(private = "file")
engine_record_discontinuity :: proc(
	engine: ^Engine,
	start_frame: i64,
	frames: u64,
	event: Discontinuity_Event,
) {
	// An explicit note advances the source clock; the transport ring then sees
	// the same skipped range on the next push. Avoid recording that one loss
	// twice while still keeping the ring's own ledger intact.
	if count := engine.discontinuity_count; count > 0 {
		last := engine.discontinuities[int(count - 1) % ENGINE_LEDGER_CAPACITY]
		if last.start_frame == start_frame && last.frames == frames && last.epoch == engine.epoch {
			return
		}
	}
	if engine.discontinuity_count >= u64(ENGINE_LEDGER_CAPACITY) {
		engine.discontinuity_overflowed = true
		return
	}
	engine.discontinuities[int(engine.discontinuity_count)] = Engine_Discontinuity{
		epoch = engine.epoch,
		start_frame = start_frame,
		frames = frames,
		event = event,
	}
	engine.discontinuity_count += 1
}

@(private = "file")
engine_mark_unavailable :: proc(engine: ^Engine, resume_frame: i64, boundary: bool) {
	// The live reading is no longer trustworthy until audio at or after
	// `resume_frame` is analysed. `boundary` additionally marks the next
	// completed window as the affected window (used for an explicit note or a
	// rejected range; transport gaps learn this from the segment change).
	engine.window_valid = false
	engine.last_window_valid = false
	engine.have_window = false
	engine.awaiting_resume = true
	engine.resume_frame = resume_frame
	if boundary {
		engine.boundary_pending = true
	}
}

@(private = "file")
engine_reset_analysis :: proc(engine: ^Engine) {
	dsp.peak_accumulator_reset(&engine.session_max)
	dsp.peak_accumulator_reset(&engine.window_peak)
	_ = dsp.rms_window_init(&engine.rms, engine.window_frames, CHANNELS, engine.frame_clock)
	_ = dsp.peak_hold_init(&engine.hold, dsp.Peak_Hold_Config{
		channels = CHANNELS,
		sample_rate = max(int(engine.sample_rate), 1),
		hold_frames = engine.hold_frames,
		decay = engine.hold_decay_enabled ? .Logarithmic : .None,
		db_decay_per_second = engine.hold_decay_enabled ? f32(engine.hold_decay_db) : 0,
	})
	engine.window_valid = true
	engine.boundary_pending = false
	engine.last_window_valid = false
	engine.last_window_peak = {}
}

// engine_set_parameters applies authoring values at a block boundary.
engine_set_parameters :: proc(engine: ^Engine, parameters: Parameters) {
	if engine == nil {
		return
	}
	window_frames := parameters.window_frames
	if window_frames < 1 {
		window_frames = DEFAULT_WINDOW_FRAMES
	}
	if window_frames != engine.window_frames {
		engine.window_frames = window_frames
		_ = dsp.rms_window_init(&engine.rms, window_frames, CHANNELS, engine.frame_clock)
		dsp.peak_accumulator_reset(&engine.window_peak)
		engine.have_window = false
		engine.window_valid = true
		engine.last_window_peak = {}
	}
	if parameters.hold_frames != engine.hold_frames ||
		parameters.hold_decay_enabled != engine.hold_decay_enabled ||
		parameters.hold_decay_db != engine.hold_decay_db {
		engine.hold_frames = parameters.hold_frames
		engine.hold_decay_enabled = parameters.hold_decay_enabled
		engine.hold_decay_db = parameters.hold_decay_db
		_ = dsp.peak_hold_init(&engine.hold, dsp.Peak_Hold_Config{
			channels = CHANNELS,
			sample_rate = max(int(engine.sample_rate), 1),
			hold_frames = parameters.hold_frames,
			decay = parameters.hold_decay_enabled ? .Logarithmic : .None,
			db_decay_per_second = parameters.hold_decay_enabled ? parameters.hold_decay_db : 0,
		})
	}
}

// engine_push_interleaved is the capture intake. `samples` is interleaved f32
// for `frames` frames. A negative `steady_time` advances the source clock by
// the delivered frames; a non-negative value is an explicit source position.
engine_push_interleaved :: proc(
	engine: ^Engine,
	samples: []f32,
	frames: int,
	steady_time: i64 = -1,
) -> Push_Result {
	if engine == nil || !engine.active {
		return .Rejected
	}
	if frames <= 0 || frames > engine.max_frames || len(samples) < frames * CHANNELS {
		return .Rejected
	}
	for index in 0 ..< frames * CHANNELS {
		engine.staging[index] = samples[index]
	}
	return engine_ingest(engine, frames, steady_time)
}

// engine_push_passthrough copies planar input to planar output sample-for-sample
// and feeds the same frames to analysis. `input`/`output` are arrays of channel
// pointers. This is the CLAP intake.
engine_push_passthrough :: proc(
	engine: ^Engine,
	input: [CHANNELS][^]f32,
	output: [CHANNELS][^]f32,
	frames: int,
	steady_time: i64,
) -> Push_Result {
	if engine == nil || !engine.active {
		return .Rejected
	}
	if frames <= 0 || frames > engine.max_frames {
		return .Rejected
	}
	for frame in 0 ..< frames {
		for channel in 0 ..< CHANNELS {
			sample := input[channel][frame]
			output[channel][frame] = sample
			engine.staging[frame * CHANNELS + channel] = sample
		}
	}
	return engine_ingest(engine, frames, steady_time)
}

@(private = "file")
engine_ingest :: proc(engine: ^Engine, frames: int, steady_time: i64) -> Push_Result {
	// A forward jump in the host's steady sample clock means source frames were
	// skipped. Advance the absolute frame clock before pushing the block.
	if steady_time >= 0 {
		if engine.steady_initialized {
			expected := engine.last_steady_time + i64(engine.last_block_frames)
			if steady_time > expected {
				engine.frame_clock += steady_time - expected
			}
		}
		engine.last_block_frames = frames
		engine.last_steady_time = steady_time
		engine.steady_initialized = true
	}

	block_start := engine.frame_clock
	// Compare against the ring's published source position before the push:
	// a forward range is a ledger gap, not a continuation of the window.
	if expected := i64(transport.audio_ring_source_frame_pos(&engine.ring)); block_start > expected {
		gap := u64(block_start - expected)
		engine_record_discontinuity(engine, expected, gap, .Source_Gap)
		engine_mark_unavailable(engine, block_start, false)
	}

	block := stream.Audio_Block{
		start_frame = block_start,
		frames = frames,
		channels = CHANNELS,
		interleaved = engine.staging[:frames * CHANNELS],
	}
	status := transport.audio_ring_push(&engine.ring, block, u64(block_start))
	result := Push_Result.Accepted
	switch status {
	case .Accepted:
		// contiguous
	case .Accepted_With_Gap:
		// The ring recorded a forward range the pre-push check did not see.
		engine_mark_unavailable(engine, block_start, false)
		result = .Accepted_With_Gap
	case .Dropped_Overrun:
		engine_record_discontinuity(engine, block_start, u64(frames), .Transport_Overrun)
		engine_mark_unavailable(engine, block_start + i64(frames), false)
		result = .Overrun
	case .Rejected_Duplicate, .Rejected_Invalid:
		engine_record_discontinuity(engine, block_start, 0, .Rejected_Block)
		engine_mark_unavailable(engine, block_start, true)
		result = .Rejected
	}
	// The overrun/ledger-overflow latches are historical completeness signals.
	// They are recorded once and never used as a sticky current-validity latch.
	if transport.audio_ring_ledger_overflow_seen(&engine.ring) && !engine.ledger_overflow_seen {
		engine.ledger_overflow_seen = true
		engine_record_discontinuity(engine, block_start, 0, .Transport_Overrun)
		engine_mark_unavailable(engine, block_start, false)
	}

	engine.frame_clock += i64(frames)
	engine.processed_blocks += 1

	if engine.drain_enabled {
		engine_drain_ring(engine)
	}
	engine_publish_snapshot(engine)
	return result
}

@(private = "file")
engine_drain_ring :: proc(engine: ^Engine) {
	for {
		read := transport.audio_ring_read(&engine.ring, engine.drain)
		if !read.ok {
			return
		}
		if read.frames <= 0 {
			continue
		}
		// A continuity segment change means this block does not follow the
		// previous one. Restart the RMS window so no window straddles the gap,
		// and mark the first new window as the affected/boundary window.
		if read.continuity_epoch != engine.processed_segment {
			engine.processed_segment = read.continuity_epoch
			engine.have_window = false
			_ = dsp.rms_window_init(&engine.rms, engine.window_frames, CHANNELS, read.start_frame)
			dsp.peak_accumulator_reset(&engine.window_peak)
			engine.window_valid = true
			engine.boundary_pending = true
			engine.last_window_valid = false
		}
		if engine.awaiting_resume {
			if read.start_frame >= engine.resume_frame {
				engine.awaiting_resume = false
			} else {
				// Pre-boundary backlog: it was captured before the break and is
				// still a valid historical measurement.
				engine.window_valid = true
			}
		}
		engine_analyze_block(engine, stream.Audio_Block{
			start_frame = read.start_frame,
			frames = read.frames,
			channels = CHANNELS,
			interleaved = engine.drain[:read.frames * CHANNELS],
		})
	}
}

@(private = "file")
engine_analyze_block :: proc(engine: ^Engine, block: stream.Audio_Block) {
	_ = dsp.peak_accumulator_process(&engine.session_max, block)
	offset := 0
	for offset < block.frames {
		remaining := engine.rms.window_frames - engine.rms.frames_filled
		count := min(remaining, block.frames - offset)
		sub := stream.Audio_Block{
			start_frame = block.start_frame + i64(offset),
			frames = count,
			channels = CHANNELS,
			interleaved = block.interleaved[offset * CHANNELS : (offset + count) * CHANNELS],
		}
		_ = dsp.peak_accumulator_process(&engine.window_peak, sub)
		_ = dsp.peak_hold_process(&engine.hold, sub)
		completed := engine.rms.frames_filled + count == engine.rms.window_frames
		callback := completed ? dsp.RMS_Window_Callback(rms_window_callback) : nil
		_ = dsp.rms_window_process(&engine.rms, sub, callback, engine)
		if completed {
			dsp.peak_accumulator_reset(&engine.window_peak)
		}
		offset += count
	}
}

@(private = "file")
rms_window_callback :: proc(user_data: rawptr, record: dsp.RMS_Record) {
	engine := cast(^Engine)user_data
	if engine == nil {
		return
	}
	window_valid := engine.window_valid && !engine.boundary_pending
	engine.last_window_valid = window_valid
	engine.have_window = true
	engine.last_rms_start = record.start_frame
	for channel in 0 ..< CHANNELS {
		engine.last_rms[channel] = record.rms[channel]
		engine.last_window_peak[channel] = engine.window_peak.per_channel[channel]
	}
	// The boundary/affected window has been emitted; later contiguous windows
	// are valid again without an explicit reset.
	engine.boundary_pending = false
	engine.window_valid = true
	engine.record_generation += 1
	// Capture is a verification mode. When it is off the record is not even
	// constructed: live analysis is unchanged and the bounded queue stays empty.
	if sync.atomic_load_explicit(&engine.capture_enabled, .Acquire) == 0 {
		return
	}
	capture_valid := sync.atomic_load_explicit(&engine.capture_invalid, .Acquire) == 0
	measurement := Measurement_Record{
		schema_version = MEASUREMENT_SCHEMA_VERSION,
		epoch = engine.epoch,
		generation = engine.record_generation,
		start_frame = record.start_frame,
		frames = u32(record.frames),
		channels = CHANNELS,
		sample_rate = u32(max(int(engine.sample_rate), 1)),
		rms = {record.rms[0], record.rms[1]},
		valid = window_valid,
		overrun = !window_valid,
		capture_valid = capture_valid,
	}
	for channel in 0 ..< CHANNELS {
		peak := engine.window_peak.per_channel[channel]
		measurement.peak[channel] = peak.magnitude
		measurement.peak_frame[channel] = peak.frame
		measurement.hold[channel] = engine.hold.held[channel]
	}
	if !engine_measurement_push(engine, measurement) {
		// A lost measurement record invalidates the verification capture only.
		sync.atomic_store_explicit(&engine.capture_invalid, 1, .Release)
	}
}

@(private = "file")
engine_measurement_push :: proc(engine: ^Engine, measurement: Measurement_Record) -> bool {
	write := sync.atomic_load_explicit(&engine.queue.write, .Relaxed)
	read := sync.atomic_load_explicit(&engine.queue.read, .Acquire)
	if engine.queue.records == nil || write - read >= u64(engine.queue.capacity) {
		sync.atomic_add_explicit(&engine.queue.dropped, 1, .Relaxed)
		return false
	}
	slot := int(write % u64(engine.queue.capacity))
	engine.queue.records[slot] = measurement
	sync.atomic_store_explicit(&engine.queue.write, write + 1, .Release)
	depth := write + 1 - read
	high := sync.atomic_load_explicit(&engine.queue.high_water, .Relaxed)
	if depth > high {
		sync.atomic_store_explicit(&engine.queue.high_water, depth, .Relaxed)
	}
	return true
}

// engine_measurement_pending reports buffered canonical records.
engine_measurement_pending :: proc(engine: ^Engine) -> int {
	if engine == nil || engine.queue.records == nil {
		return 0
	}
	write := sync.atomic_load_explicit(&engine.queue.write, .Acquire)
	read := sync.atomic_load_explicit(&engine.queue.read, .Acquire)
	return int(write - read)
}

// engine_measurement_drain copies up to len(destination) pending records,
// oldest first. Returns the count copied.
engine_measurement_drain :: proc(engine: ^Engine, destination: []Measurement_Record) -> int {
	if engine == nil || engine.queue.records == nil || len(destination) == 0 {
		return 0
	}
	read := sync.atomic_load_explicit(&engine.queue.read, .Relaxed)
	write := sync.atomic_load_explicit(&engine.queue.write, .Acquire)
	available := int(write - read)
	count := min(available, len(destination))
	for index in 0 ..< count {
		slot := int((read + u64(index)) % u64(engine.queue.capacity))
		destination[index] = engine.queue.records[slot]
	}
	sync.atomic_store_explicit(&engine.queue.read, read + u64(count), .Release)
	return count
}

engine_measurement_dropped :: proc(engine: ^Engine) -> u64 {
	if engine == nil {
		return 0
	}
	return sync.atomic_load_explicit(&engine.queue.dropped, .Acquire)
}

engine_measurement_high_water :: proc(engine: ^Engine) -> u64 {
	if engine == nil {
		return 0
	}
	return sync.atomic_load_explicit(&engine.queue.high_water, .Acquire)
}

// ---------------------------------------------------------------------------
// Capture mode (verification seam)
// ---------------------------------------------------------------------------

engine_capture_enabled :: proc(engine: ^Engine) -> bool {
	if engine == nil {
		return false
	}
	return sync.atomic_load_explicit(&engine.capture_enabled, .Acquire) != 0
}

// engine_capture_set_enabled switches canonical record capture. Main thread
// only, and requires quiescent processing: while processing is active a
// publication may be in flight and the episode reset would race it. Returns
// .Busy and changes nothing in that case. Enabling or disabling starts a fresh
// episode (queue cleared, dropped zeroed, capture validity reset).
engine_capture_set_enabled :: proc(engine: ^Engine, enabled: bool) -> Capture_Set_Result {
	if engine == nil {
		return .Busy
	}
	if engine.processing {
		return .Busy
	}
	sync.atomic_store_explicit(&engine.capture_enabled, 0, .Release)
	if engine.queue.records != nil {
		sync.atomic_store_explicit(&engine.queue.write, 0, .Release)
		sync.atomic_store_explicit(&engine.queue.read, 0, .Release)
		sync.atomic_store_explicit(&engine.queue.dropped, 0, .Release)
		sync.atomic_store_explicit(&engine.queue.high_water, 0, .Release)
	}
	sync.atomic_store_explicit(&engine.capture_invalid, 0, .Release)
	if enabled {
		sync.atomic_store_explicit(&engine.capture_enabled, 1, .Release)
	}
	return .Ok
}

// engine_set_processing records the host/consumer quiescence signal.
engine_set_processing :: proc(engine: ^Engine, active: bool) {
	if engine != nil {
		engine.processing = active
	}
}

engine_is_processing :: proc(engine: ^Engine) -> bool {
	return engine != nil && engine.processing
}

// engine_capture_valid is the capture-domain validity: false only after a
// record was dropped. It never reflects lost audio samples.
engine_capture_valid :: proc(engine: ^Engine) -> bool {
	if engine == nil {
		return true
	}
	return sync.atomic_load_explicit(&engine.capture_invalid, .Acquire) == 0
}

engine_capture_schema_version :: proc(engine: ^Engine) -> u32 {
	if engine == nil {
		return 0
	}
	return MEASUREMENT_SCHEMA_VERSION
}

// engine_measurement_drain_sink delivers up to max_records pending records
// oldest-first. max_records == 0 drains everything. The pointer is valid only
// for the callback; the read cursor advances only after the sink returns true.
engine_measurement_drain_sink :: proc(
	engine: ^Engine,
	sink: Measurement_Sink,
	max_records: u32,
) -> u32 {
	if engine == nil || engine.queue.records == nil || sink.push == nil {
		return 0
	}
	read := sync.atomic_load_explicit(&engine.queue.read, .Relaxed)
	write := sync.atomic_load_explicit(&engine.queue.write, .Acquire)
	available := write - read
	limit := available
	if max_records != 0 {
		limit = min(available, u64(max_records))
	}
	delivered: u64 = 0
	for delivered < limit {
		slot := int((read + delivered) % u64(engine.queue.capacity))
		record := &engine.queue.records[slot]
		if !sink.push(sink.ctx, record) {
			break
		}
		delivered += 1
	}
	if delivered > 0 {
		sync.atomic_store_explicit(&engine.queue.read, read + delivered, .Release)
	}
	return u32(delivered)
}

// engine_snapshot is the latest-wins presentation view. Reading it has no
// effect on canonical measurement records; presentation cadence is independent
// of analysis cadence.
engine_snapshot :: proc(engine: ^Engine) -> transport.Measurement_Snapshot {
	if engine == nil {
		return {}
	}
	return transport.snapshot_read(&engine.publisher)
}

@(private = "file")
engine_publish_snapshot :: proc(engine: ^Engine) {
	engine.generation += 1
	current_valid := engine.have_window && engine.last_window_valid && !engine.awaiting_resume
	snapshot := transport.Measurement_Snapshot{
		generation = engine.generation,
		schema_version = transport.SNAPSHOT_SCHEMA_VERSION,
		valid = current_valid && engine.session_max.overall.valid,
		overrun = !current_valid && (engine.awaiting_resume || engine.have_window),
		window_valid = current_valid,
		epoch = engine.epoch,
		frame = engine.frame_clock,
		sample_rate = max(int(engine.sample_rate), 1),
		channels = CHANNELS,
		correlation_valid = false,
	}
	for channel in 0 ..< CHANNELS {
		peak := engine.last_window_peak[channel]
		snapshot.window_peak[channel] = peak.magnitude
		snapshot.window_peak_frame[channel] = peak.frame
		snapshot.window_peak_db[channel] = dsp.peak_amplitude_to_dbfs(peak.magnitude)
		snapshot.rms[channel] = engine.last_rms[channel]
		snapshot.rms_db[channel] = dsp.rms_to_dbfs(engine.last_rms[channel])
		snapshot.peak_hold[channel] = engine.hold.held[channel]
		snapshot.peak_hold_db[channel] = dsp.peak_amplitude_to_dbfs(engine.hold.held[channel])
		session_peak := engine.session_max.per_channel[channel]
		snapshot.session_max[channel] = session_peak.magnitude
		snapshot.session_max_db[channel] = dsp.peak_amplitude_to_dbfs(session_peak.magnitude)
	}
	_ = transport.snapshot_publish(&engine.publisher, snapshot)
}

// engine_test_set_drain_enabled is a test seam: disabling the drain forces the
// transport ring to fill so the overrun path can be exercised without changing
// passthrough.
engine_test_set_drain_enabled :: proc(engine: ^Engine, enabled: bool) {
	if engine != nil {
		engine.drain_enabled = enabled
	}
}
