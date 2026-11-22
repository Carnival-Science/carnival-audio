// Pulse headless CLAP meter product.
//
// The product owns the meter analysis and its canonical measurement export.
// `adapters/clap` owns the CLAP protocol; this package implements the backend
// vtable and the product definition.
//
// Real-time contract for Meter_Process:
//   - no allocation, locking, I/O, logging or UI work;
//   - samples are passed through bit-for-bit (in-place or separate buffers);
//   - analysis is bounded by activation max_frames_count and a preallocated
//     transport ring / measurement queue;
//   - lost or dropped audio samples latch the audio-domain invalid state;
//   - lost measurement records invalidate only the capture domain, never live
//     analysis, and capture is produced only when explicitly enabled.
package pulse

import "base:runtime"
import "core:mem"
import "core:sync"

import "carnival:core/dsp"
import "carnival:core/stream"
import "carnival:core/transport"

import adapter "carnival:adapters/clap"
import clap "carnival:third_party/clap/abi"

CHANNELS :: 2

// Stable parameter IDs. Never renumber these; they are the authoring state.
PARAM_WINDOW_FRAMES :: u32(1001)
PARAM_HOLD_FRAMES :: u32(1002)
PARAM_HOLD_DECAY_ENABLED :: u32(1003)
PARAM_HOLD_DECAY_DB :: u32(1004)

PARAM_WINDOW_FRAMES_INDEX :: 0
PARAM_HOLD_FRAMES_INDEX :: 1
PARAM_HOLD_DECAY_ENABLED_INDEX :: 2
PARAM_HOLD_DECAY_DB_INDEX :: 3

// Schema 1 had IDs 1001..1003. Schema 2 adds 1004; a v1 fixture loads with 1004
// at its descriptor default (20 dB/s). See docs/clap-plugin.md. Schema 3
// appends the product flag word; bit 0 is the telemetry capture mode.
STATE_SCHEMA :: u32(3)

STATE_FLAG_CAPTURE_ENABLED :: u32(1 << 0)

RING_CAPACITY_BLOCKS :: 16
RING_GAP_CAPACITY :: 32
MEASUREMENT_QUEUE_CAPACITY :: 4096

// Measurement_Record is the canonical offline/test export: one record per
// complete, sample-clock-aligned RMS window. It is the draft Carnival telemetry
// wire record; `third_party/clap/abi` declares the layout so an independent
// host can read it without importing product code. UI snapshot cadence never
// creates, delays or drops these records; draining is an explicit host action.
//
// The record carries both validity domains:
//   valid          audio-domain validity (false after lost audio samples)
//   overrun        Milestone 1 alias for audio-domain invalid
//   capture_valid  capture-domain validity (false after lost records); it never
//                  changes `valid` and live analysis ignores it.
Measurement_Record :: clap.Carnival_Measurement_Record

MEASUREMENT_SCHEMA_VERSION :: clap.CARNIVAL_MEASUREMENT_SCHEMA_VERSION

Record_Queue :: struct {
	records:  []Measurement_Record,
	capacity: int,
	write:    u64, // atomic; total records appended
	read:     u64, // atomic; total records drained
	dropped:  u64, // atomic; records lost because the consumer did not drain
	high_water: u64, // atomic; maximum pending records observed
}

Meter :: struct {
	allocator:    mem.Allocator,

	// Activation configuration.
	active:       bool,
	sample_rate:  f64,
	max_frames:   int,

	// Preallocated real-time storage.
	ring:         transport.Audio_Ring,
	staging:      []f32, // interleaved analysis copy, max_frames * 2
	drain:        []f32,
	queue:        Record_Queue,
	publisher:    transport.Snapshot_Publisher,

	// Processing state (never serialized as authoring state).
	epoch:        u64,
	frame_clock:  i64,
	// Host-clock discontinuity tracking. CLAP's steady_time is sample-accurate
	// while a host processes continuously; a forward jump means the host skipped
	// source frames. Pulse reports that skip to the transport ring as a gap
	// instead of silently concatenating unrelated audio. A backward or repeated
	// steady_time is ignored (not treated as a discontinuity).
	last_steady_time:   i64,
	last_block_frames:  int,
	steady_initialized: bool,
	// Continuity segment of the last block fed to analysis. A segment change
	// restarts the RMS window so no window straddles a gap.
	processed_segment: u64,
	overall_peak: dsp.Peak_Accumulator,
	window_peak:  dsp.Peak_Accumulator,
	rms:          dsp.RMS_Window,
	hold:         dsp.Peak_Hold,
	last_rms:     [CHANNELS]f32,
	last_rms_start: i64,
	have_window:  bool,

	// Audio-domain validity: lost or out-of-order audio samples invalidate the
	// live analysis (snapshot and record `valid`). Never set by measurement
	// queue overflow.
	audio_invalid: bool,

	// Capture domain. Capture is opt-in; when disabled no records are produced
	// at all, so the queue cannot become a lifecycle hazard. When enabled, a
	// full queue drops the record and invalidates the capture domain only.
	capture_enabled: u32, // atomic bool bit; 0 = off (default)
	capture_invalid: u32, // atomic bool bit; 1 = a record was dropped

	processed_blocks: u64,
	generation:   u64,
	record_generation: u64,

	// Authoring values as last seen at a block boundary. These are copies of
	// the adapter's parameter atomics, used only to detect configuration
	// changes and rebuild derived processing constants.
	window_frames: int,
	hold_frames:   int,
	hold_decay_enabled: bool,
	hold_decay_db: f32,

	// Test seam only: when false the ring is not drained, so a test can force
	// queue saturation without changing passthrough.
	drain_enabled: bool,
}

meter_create :: proc() -> ^Meter {
	allocator := runtime.default_allocator()
	meter := new(Meter, allocator)
	if meter == nil {
		return nil
	}
	meter.allocator = allocator
	meter.drain_enabled = true
	meter.epoch = 1
	meter.capture_enabled = 0
	meter.capture_invalid = 0
	meter.window_frames = 1024
	meter.hold_frames = 4800
	meter.hold_decay_enabled = true
	meter.hold_decay_db = 20
	_ = dsp.peak_accumulator_init(&meter.overall_peak, CHANNELS)
	_ = dsp.peak_accumulator_init(&meter.window_peak, CHANNELS)
	return meter
}

meter_destroy :: proc(meter: ^Meter) {
	if meter == nil {
		return
	}
	meter_deactivate(meter)
	free(meter, runtime.default_allocator())
}

meter_activate :: proc(meter: ^Meter, config: adapter.Activation_Config) -> bool {
	if meter == nil || meter.active {
		return false
	}
	if config.sample_rate <= 0 || config.max_frames_count < 1 {
		return false
	}
	max_frames := int(config.max_frames_count)
	channels := CHANNELS
	if !transport.audio_ring_init(&meter.ring, RING_CAPACITY_BLOCKS, max_frames, channels,
			0, meter.epoch, meter.allocator, RING_GAP_CAPACITY) {
		return false
	}
	sample_count := max_frames * channels
	staging, staging_err := mem.alloc_bytes(sample_count * size_of(f32), align_of(f32), meter.allocator)
	if staging_err != .None || staging == nil {
		transport.audio_ring_destroy(&meter.ring)
		return false
	}
	drain, drain_err := mem.alloc_bytes(sample_count * size_of(f32), align_of(f32), meter.allocator)
	if drain_err != .None || drain == nil {
		mem.free(raw_data(staging), meter.allocator)
		transport.audio_ring_destroy(&meter.ring)
		return false
	}
	records, records_err := mem.alloc_bytes(MEASUREMENT_QUEUE_CAPACITY * size_of(Measurement_Record),
		align_of(Measurement_Record), meter.allocator)
	if records_err != .None || records == nil {
		mem.free(raw_data(drain), meter.allocator)
		mem.free(raw_data(staging), meter.allocator)
		transport.audio_ring_destroy(&meter.ring)
		return false
	}
	meter.staging = mem.slice_data_cast([]f32, staging)
	meter.drain = mem.slice_data_cast([]f32, drain)
	meter.queue.records = mem.slice_data_cast([]Measurement_Record, records)
	meter.queue.capacity = MEASUREMENT_QUEUE_CAPACITY
	meter.queue.write = 0
	meter.queue.read = 0
	meter.queue.dropped = 0
	meter.queue.high_water = 0
	meter.sample_rate = config.sample_rate
	meter.max_frames = max_frames
	meter.active = true
	meter.frame_clock = 0
	meter.generation = 0
	meter.record_generation = 0
	meter.audio_invalid = false
	meter.capture_invalid = 0
	meter.have_window = false
	meter.last_rms = {}
	meter.last_rms_start = 0
	meter.processed_blocks = 0
	meter.record_generation = 0
	meter.last_steady_time = 0
	meter.last_block_frames = 0
	meter.steady_initialized = false
	meter.processed_segment = 0
	meter_reset_analysis(meter)
	return true
}

meter_deactivate :: proc(meter: ^Meter) {
	if meter == nil {
		return
	}
	if meter.ring.samples != nil {
		transport.audio_ring_destroy(&meter.ring)
	}
	if meter.staging != nil {
		mem.free(raw_data(meter.staging), meter.allocator)
	}
	if meter.drain != nil {
		mem.free(raw_data(meter.drain), meter.allocator)
	}
	if meter.queue.records != nil {
		mem.free(raw_data(meter.queue.records), meter.allocator)
	}
	meter.staging = nil
	meter.drain = nil
	meter.queue = {}
	meter.active = false
	meter.max_frames = 0
}

// meter_reset restarts the sample clock and clears analysis, the discontinuity
// ledger and the canonical export queue. Parameter values are unchanged, as
// CLAP requires. The epoch advances so old and new records cannot be confused.
meter_reset :: proc(meter: ^Meter) {
	if meter == nil || !meter.active {
		return
	}
	meter.epoch += 1
	meter.frame_clock = 0
	transport.audio_ring_reset(&meter.ring)
	sync.atomic_store_explicit(&meter.queue.write, 0, .Release)
	sync.atomic_store_explicit(&meter.queue.read, 0, .Release)
	sync.atomic_store_explicit(&meter.queue.dropped, 0, .Release)
	sync.atomic_store_explicit(&meter.queue.high_water, 0, .Release)
	meter.audio_invalid = false
	meter.capture_invalid = 0
	meter.have_window = false
	meter.last_rms = {}
	meter.last_rms_start = 0
	meter.processed_blocks = 0
	meter.record_generation = 0
	meter.last_steady_time = 0
	meter.last_block_frames = 0
	meter.steady_initialized = false
	meter.processed_segment = 0
	meter_reset_analysis(meter)
	transport.snapshot_publisher_reset(&meter.publisher)
}

@(private = "file")
meter_reset_analysis :: proc(meter: ^Meter) {
	dsp.peak_accumulator_reset(&meter.overall_peak)
	dsp.peak_accumulator_reset(&meter.window_peak)
	_ = dsp.rms_window_init(&meter.rms, meter.window_frames, CHANNELS, meter.frame_clock)
	_ = dsp.peak_hold_init(&meter.hold, dsp.Peak_Hold_Config{
		channels = CHANNELS,
		sample_rate = max(int(meter.sample_rate), 1),
		hold_frames = meter.hold_frames,
		decay = meter.hold_decay_enabled ? .Logarithmic : .None,
		db_decay_per_second = meter.hold_decay_enabled ? f32(meter.hold_decay_db) : 0,
	})
}

// meter_process is the real-time backend entry point. It is allocation-free
// and lock-free after activation.
meter_process :: proc(meter: ^Meter, request: ^adapter.Process_Request) -> adapter.Process_Result {
	if meter == nil || request == nil || !meter.active {
		return .Error
	}
	if request.channels != CHANNELS || request.frames == 0 || int(request.frames) > meter.max_frames {
		return .Error
	}
	frames := int(request.frames)
	meter_apply_configuration(meter, request.params)

	// A forward jump in the host's steady sample clock means source frames were
	// skipped. Advance the absolute frame clock before pushing the block so the
	// transport ring records the lost range and analysis starts a new segment.
	if request.steady_time >= 0 {
		if meter.steady_initialized {
			expected := meter.last_steady_time + i64(meter.last_block_frames)
			if request.steady_time > expected {
				meter.frame_clock += request.steady_time - expected
			}
		}
		meter.last_block_frames = frames
		meter.last_steady_time = request.steady_time
		meter.steady_initialized = true
	}

	// Pass through sample-for-sample, and build the interleaved analysis copy.
	input_channels: [CHANNELS][^]f32
	output_channels: [CHANNELS][^]f32
	for channel in 0 ..< CHANNELS {
		input_channels[channel] = cast([^]f32)request.input[channel]
		output_channels[channel] = cast([^]f32)request.output[channel]
	}
	for frame in 0 ..< frames {
		for channel in 0 ..< CHANNELS {
			sample := input_channels[channel][frame]
			output_channels[channel][frame] = sample
			meter.staging[frame * CHANNELS + channel] = sample
		}
	}

	block := stream.Audio_Block{
		start_frame = meter.frame_clock,
		frames = frames,
		channels = CHANNELS,
		interleaved = meter.staging[:frames * CHANNELS],
	}
	status := transport.audio_ring_push(&meter.ring, block, u64(meter.frame_clock))
	switch status {
	case .Accepted:
		// contiguous
	case .Accepted_With_Gap:
		meter.audio_invalid = true
	case .Dropped_Overrun, .Rejected_Duplicate, .Rejected_Invalid:
		meter.audio_invalid = true
	}
	if transport.audio_ring_overrun_seen(&meter.ring) || transport.audio_ring_ledger_overflow_seen(&meter.ring) {
		meter.audio_invalid = true
	}

	meter.frame_clock += i64(frames)
	meter.processed_blocks += 1

	if meter.drain_enabled {
		meter_drain_ring(meter)
	}

	meter_publish_snapshot(meter)
	return .Continue
}

@(private = "file")
meter_apply_configuration :: proc(meter: ^Meter, params: []f64) {
	if len(params) <= PARAM_HOLD_DECAY_DB_INDEX {
		return
	}
	window_frames := int(params[PARAM_WINDOW_FRAMES_INDEX])
	if window_frames < 1 {
		window_frames = 1024
	}
	hold_frames := int(params[PARAM_HOLD_FRAMES_INDEX])
	decay_enabled := params[PARAM_HOLD_DECAY_ENABLED_INDEX] >= 0.5
	decay_db := f32(params[PARAM_HOLD_DECAY_DB_INDEX])

	changed := false
	if window_frames != meter.window_frames {
		meter.window_frames = window_frames
		_ = dsp.rms_window_init(&meter.rms, window_frames, CHANNELS, meter.frame_clock)
		dsp.peak_accumulator_reset(&meter.window_peak)
		meter.have_window = false
		changed = true
	}
	if hold_frames != meter.hold_frames || decay_enabled != meter.hold_decay_enabled || decay_db != meter.hold_decay_db {
		meter.hold_frames = hold_frames
		meter.hold_decay_enabled = decay_enabled
		meter.hold_decay_db = decay_db
		_ = dsp.peak_hold_init(&meter.hold, dsp.Peak_Hold_Config{
			channels = CHANNELS,
			sample_rate = max(int(meter.sample_rate), 1),
			hold_frames = hold_frames,
			decay = decay_enabled ? .Logarithmic : .None,
			db_decay_per_second = decay_enabled ? decay_db : 0,
		})
		changed = true
	}
	_ = changed
}

@(private = "file")
meter_drain_ring :: proc(meter: ^Meter) {
	for {
		read := transport.audio_ring_read(&meter.ring, meter.drain)
		if !read.ok {
			return
		}
		if read.frames <= 0 {
			continue
		}
		// A continuity segment change means this block does not follow the
		// previous one. The audio domain is already latched invalid; restart the
		// RMS window here so no window straddles the gap and post-gap windows
		// align with absolute frames again.
		if read.continuity_epoch != meter.processed_segment {
			meter.processed_segment = read.continuity_epoch
			meter.have_window = false
			_ = dsp.rms_window_init(&meter.rms, meter.window_frames, CHANNELS, read.start_frame)
			dsp.peak_accumulator_reset(&meter.window_peak)
		}
		meter_analyze_block(meter, stream.Audio_Block{
			start_frame = read.start_frame,
			frames = read.frames,
			channels = CHANNELS,
			interleaved = meter.drain[:read.frames * CHANNELS],
		})
	}
}

@(private = "file")
meter_analyze_block :: proc(meter: ^Meter, block: stream.Audio_Block) {
	_ = dsp.peak_accumulator_process(&meter.overall_peak, block)
	offset := 0
	for offset < block.frames {
		remaining := meter.rms.window_frames - meter.rms.frames_filled
		count := min(remaining, block.frames - offset)
		sub := stream.Audio_Block{
			start_frame = block.start_frame + i64(offset),
			frames = count,
			channels = CHANNELS,
			interleaved = block.interleaved[offset * CHANNELS : (offset + count) * CHANNELS],
		}
		_ = dsp.peak_accumulator_process(&meter.window_peak, sub)
		_ = dsp.peak_hold_process(&meter.hold, sub)
		completed := meter.rms.frames_filled + count == meter.rms.window_frames
		callback := completed ? dsp.RMS_Window_Callback(rms_window_callback) : nil
		_ = dsp.rms_window_process(&meter.rms, sub, callback, meter)
		if completed {
			dsp.peak_accumulator_reset(&meter.window_peak)
		}
		offset += count
	}
}

@(private = "file")
rms_window_callback :: proc(user_data: rawptr, record: dsp.RMS_Record) {
	meter := cast(^Meter)user_data
	if meter == nil {
		return
	}
	meter.have_window = true
	meter.last_rms_start = record.start_frame
	for channel in 0 ..< CHANNELS {
		meter.last_rms[channel] = record.rms[channel]
	}
	meter.record_generation += 1
	// Capture is a verification mode. When it is off the record is not even
	// constructed: live analysis is unchanged and the bounded queue stays empty.
	if sync.atomic_load_explicit(&meter.capture_enabled, .Acquire) == 0 {
		return
	}
	capture_valid := sync.atomic_load_explicit(&meter.capture_invalid, .Acquire) == 0
	measurement := Measurement_Record{
		schema_version = MEASUREMENT_SCHEMA_VERSION,
		epoch = meter.epoch,
		generation = meter.record_generation,
		start_frame = record.start_frame,
		frames = u32(record.frames),
		channels = CHANNELS,
		sample_rate = u32(max(int(meter.sample_rate), 1)),
		rms = {record.rms[0], record.rms[1]},
		valid = !meter.audio_invalid,
		overrun = meter.audio_invalid,
		capture_valid = capture_valid,
	}
	for channel in 0 ..< CHANNELS {
		peak := meter.window_peak.per_channel[channel]
		measurement.peak[channel] = peak.magnitude
		measurement.peak_frame[channel] = peak.frame
		measurement.hold[channel] = meter.hold.held[channel]
	}
	if !meter_measurement_push(meter, measurement) {
		// A lost measurement record invalidates the verification capture only.
		// Live analysis and the audio-domain validity are unaffected.
		sync.atomic_store_explicit(&meter.capture_invalid, 1, .Release)
	}
}

@(private = "file")
meter_measurement_push :: proc(meter: ^Meter, measurement: Measurement_Record) -> bool {
	write := sync.atomic_load_explicit(&meter.queue.write, .Relaxed)
	read := sync.atomic_load_explicit(&meter.queue.read, .Acquire)
	if meter.queue.records == nil || write - read >= u64(meter.queue.capacity) {
		sync.atomic_add_explicit(&meter.queue.dropped, 1, .Relaxed)
		return false
	}
	slot := int(write % u64(meter.queue.capacity))
	meter.queue.records[slot] = measurement
	sync.atomic_store_explicit(&meter.queue.write, write + 1, .Release)
	depth := write + 1 - read
	high := sync.atomic_load_explicit(&meter.queue.high_water, .Relaxed)
	if depth > high {
		sync.atomic_store_explicit(&meter.queue.high_water, depth, .Relaxed)
	}
	return true
}

// meter_measurement_pending reports buffered canonical records.
meter_measurement_pending :: proc(meter: ^Meter) -> int {
	if meter == nil || meter.queue.records == nil {
		return 0
	}
	write := sync.atomic_load_explicit(&meter.queue.write, .Acquire)
	read := sync.atomic_load_explicit(&meter.queue.read, .Acquire)
	return int(write - read)
}

// meter_measurement_drain copies up to len(destination) pending canonical
// records, oldest first. It returns the count copied. Call it in a loop to
// perform a complete drain at a quiescent boundary.
meter_measurement_drain :: proc(meter: ^Meter, destination: []Measurement_Record) -> int {
	if meter == nil || meter.queue.records == nil || len(destination) == 0 {
		return 0
	}
	read := sync.atomic_load_explicit(&meter.queue.read, .Relaxed)
	write := sync.atomic_load_explicit(&meter.queue.write, .Acquire)
	available := int(write - read)
	count := min(available, len(destination))
	for index in 0 ..< count {
		slot := int((read + u64(index)) % u64(meter.queue.capacity))
		destination[index] = meter.queue.records[slot]
	}
	sync.atomic_store_explicit(&meter.queue.read, read + u64(count), .Release)
	return count
}

meter_measurement_dropped :: proc(meter: ^Meter) -> u64 {
	if meter == nil {
		return 0
	}
	return sync.atomic_load_explicit(&meter.queue.dropped, .Acquire)
}

meter_measurement_high_water :: proc(meter: ^Meter) -> u64 {
	if meter == nil {
		return 0
	}
	return sync.atomic_load_explicit(&meter.queue.high_water, .Acquire)
}

// ---------------------------------------------------------------------------
// Capture mode (verification seam)
// ---------------------------------------------------------------------------

// meter_capture_enabled reports the explicit capture mode. Off by default.
meter_capture_enabled :: proc(meter: ^Meter) -> bool {
	if meter == nil {
		return false
	}
	return sync.atomic_load_explicit(&meter.capture_enabled, .Acquire) != 0
}

// meter_capture_set_enabled switches canonical record capture. It is a main
// thread operation (the telemetry extension documents the same rule). Enabling
// (or disabling) starts a fresh capture episode: pending records are discarded
// and the dropped counter and capture validity are reset. The audio thread may
// be producing at the instant of the switch; callers needing an exact boundary
// should stop processing first. Live analysis is never affected.
meter_capture_set_enabled :: proc(meter: ^Meter, enabled: bool) -> bool {
	if meter == nil {
		return false
	}
	// Stop production first so a concurrent push cannot race the queue reset.
	sync.atomic_store_explicit(&meter.capture_enabled, 0, .Release)
	if meter.queue.records != nil {
		sync.atomic_store_explicit(&meter.queue.write, 0, .Release)
		sync.atomic_store_explicit(&meter.queue.read, 0, .Release)
		sync.atomic_store_explicit(&meter.queue.dropped, 0, .Release)
		sync.atomic_store_explicit(&meter.queue.high_water, 0, .Release)
	}
	sync.atomic_store_explicit(&meter.capture_invalid, 0, .Release)
	if enabled {
		sync.atomic_store_explicit(&meter.capture_enabled, 1, .Release)
	}
	return true
}

// meter_capture_valid is the capture-domain validity. It is true when capture
// is off, and false only after a canonical record was dropped because the queue
// was full. It never reflects lost audio samples (that is the audio domain).
meter_capture_valid :: proc(meter: ^Meter) -> bool {
	if meter == nil {
		return true
	}
	return sync.atomic_load_explicit(&meter.capture_invalid, .Acquire) == 0
}

// meter_capture_schema_version reports the canonical record schema implemented
// by this build.
meter_capture_schema_version :: proc(meter: ^Meter) -> u32 {
	if meter == nil {
		return 0
	}
	return MEASUREMENT_SCHEMA_VERSION
}

// meter_measurement_drain_sink delivers up to max_records pending canonical
// records, oldest first, through a host callback. max_records == 0 drains every
// pending record. The record pointer passed to the callback points into the
// bounded queue and is valid only for the duration of that callback; the read
// cursor advances only after the callback returns true, so the audio thread
// never overwrites an unread or in-flight slot. Returns the number delivered.
meter_measurement_drain_sink :: proc(
	meter: ^Meter,
	sink: clap.Carnival_Capture_Sink,
	max_records: u32,
) -> u32 {
	if meter == nil || meter.queue.records == nil || sink.push == nil {
		return 0
	}
	read := sync.atomic_load_explicit(&meter.queue.read, .Relaxed)
	write := sync.atomic_load_explicit(&meter.queue.write, .Acquire)
	available := write - read
	limit := available
	if max_records != 0 {
		limit = min(available, u64(max_records))
	}
	delivered: u64 = 0
	for delivered < limit {
		slot := int((read + delivered) % u64(meter.queue.capacity))
		record := &meter.queue.records[slot]
		if !sink.push(sink.ctx, record) {
			break
		}
		delivered += 1
	}
	if delivered > 0 {
		sync.atomic_store_explicit(&meter.queue.read, read + delivered, .Release)
	}
	return u32(delivered)
}

// meter_snapshot is the latest-wins presentation view. Reading it has no effect
// on canonical measurement records.
meter_snapshot :: proc(meter: ^Meter) -> transport.Measurement_Snapshot {
	if meter == nil {
		return {}
	}
	return transport.snapshot_read(&meter.publisher)
}

@(private = "file")
meter_publish_snapshot :: proc(meter: ^Meter) {
	meter.generation += 1
	snapshot := transport.Measurement_Snapshot{
		generation = meter.generation,
		valid = !meter.audio_invalid && meter.overall_peak.overall.valid,
		overrun = meter.audio_invalid,
		epoch = meter.epoch,
		frame = meter.frame_clock,
		sample_rate = max(int(meter.sample_rate), 1),
		channels = CHANNELS,
		correlation_valid = false,
	}
	for channel in 0 ..< CHANNELS {
		peak := meter.overall_peak.per_channel[channel]
		snapshot.peak[channel] = peak.magnitude
		snapshot.peak_frame[channel] = peak.frame
		snapshot.peak_db[channel] = dsp.peak_amplitude_to_dbfs(peak.magnitude)
		snapshot.rms[channel] = meter.last_rms[channel]
		snapshot.rms_db[channel] = dsp.rms_to_dbfs(meter.last_rms[channel])
		snapshot.hold[channel] = meter.hold.held[channel]
		snapshot.hold_db[channel] = dsp.peak_amplitude_to_dbfs(meter.hold.held[channel])
	}
	_ = transport.snapshot_publish(&meter.publisher, snapshot)
}

// Test seam: disabling the drain forces the transport ring to fill so the
// overrun invalidation path can be exercised without touching passthrough.
meter_test_set_drain_enabled :: proc(meter: ^Meter, enabled: bool) {
	if meter != nil {
		meter.drain_enabled = enabled
	}
}

