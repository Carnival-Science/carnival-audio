// Pulse headless CLAP meter: the thin CLAP product binding.
//
// All analysis lives in `core/meter` (the source-independent engine). This
// package only:
//   - maps the adapter's activation/process request onto the engine;
//   - converts the engine's canonical record to the draft CLAP telemetry wire
//     record declared in `third_party/clap/abi`;
//   - owns the product's authoring-state schema and flag word;
//   - wires the draft telemetry extension and the processing lifecycle.
//
// Real-time contract for meter_process: no allocation, locking, I/O, logging or
// UI work. The engine's push path copies samples, pushes one bounded ring slot,
// analyses and publishes a snapshot; passthrough stays bit-exact.
package pulse

import "core:mem"

import "carnival:core/meter"
import "carnival:core/transport"

import adapter "carnival:adapters/clap"
import clap "carnival:third_party/clap/abi"

CHANNELS :: meter.CHANNELS

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
// at its descriptor default (20 dB/s). Schema 3 appends the product flag word;
// bit 0 is the telemetry capture mode. Authoring state stays parameters-only:
// Pulse declares the optional processing checkpoint unsupported.
STATE_SCHEMA :: u32(3)

STATE_FLAG_CAPTURE_ENABLED :: u32(1 << 0)

MEASUREMENT_QUEUE_CAPACITY :: meter.MEASUREMENT_QUEUE_CAPACITY
RING_CAPACITY_BLOCKS :: meter.RING_CAPACITY_BLOCKS
RING_GAP_CAPACITY :: meter.RING_GAP_CAPACITY

// Measurement_Record is the canonical CLAP wire record. The engine has its own
// declaration in core/meter (which must not import CLAP); the two layouts are
// asserted identical here and converted at the ABI boundary.
Measurement_Record :: clap.Carnival_Measurement_Record

MEASUREMENT_SCHEMA_VERSION :: clap.CARNIVAL_MEASUREMENT_SCHEMA_VERSION

#assert(size_of(meter.Measurement_Record) == size_of(Measurement_Record))

Capture_Set_Result :: meter.Capture_Set_Result

// Meter is the engine. Keeping the product type an alias means the standalone
// and CLAP consumers share exactly the same analysis object.
Meter :: meter.Engine

// ---------------------------------------------------------------------------
// Engine binding
// ---------------------------------------------------------------------------

meter_create :: proc() -> ^Meter {
	return meter.engine_create()
}

meter_destroy :: proc(instance: ^Meter) {
	meter.engine_destroy(instance)
}

meter_activate :: proc(instance: ^Meter, config: adapter.Activation_Config) -> bool {
	return meter.engine_activate(instance, config.sample_rate, int(config.max_frames_count))
}

meter_deactivate :: proc(instance: ^Meter) {
	meter.engine_deactivate(instance)
}

meter_reset :: proc(instance: ^Meter) {
	meter.engine_reset(instance)
}

meter_set_processing :: proc(instance: ^Meter, active: bool) {
	meter.engine_set_processing(instance, active)
}

meter_is_processing :: proc(instance: ^Meter) -> bool {
	return meter.engine_is_processing(instance)
}

// meter_process is the real-time backend entry point. It applies the adapter's
// parameter snapshot at the block boundary, then hands the planar buffers to the
// engine's passthrough intake.
meter_process :: proc(instance: ^Meter, request: ^adapter.Process_Request) -> adapter.Process_Result {
	if instance == nil || request == nil || !instance.active {
		return .Error
	}
	if request.channels != CHANNELS || request.frames == 0 || int(request.frames) > instance.max_frames {
		return .Error
	}
	parameters := meter.Parameters{
		window_frames = instance.window_frames,
		hold_frames = instance.hold_frames,
		hold_decay_enabled = instance.hold_decay_enabled,
		hold_decay_db = instance.hold_decay_db,
	}
	if len(request.params) > PARAM_HOLD_DECAY_DB_INDEX {
		parameters.window_frames = int(request.params[PARAM_WINDOW_FRAMES_INDEX])
		parameters.hold_frames = int(request.params[PARAM_HOLD_FRAMES_INDEX])
		parameters.hold_decay_enabled = request.params[PARAM_HOLD_DECAY_ENABLED_INDEX] >= 0.5
		parameters.hold_decay_db = f32(request.params[PARAM_HOLD_DECAY_DB_INDEX])
	}
	meter.engine_set_parameters(instance, parameters)
	input: [CHANNELS][^]f32
	output: [CHANNELS][^]f32
	for channel in 0 ..< CHANNELS {
		input[channel] = cast([^]f32)request.input[channel]
		output[channel] = cast([^]f32)request.output[channel]
	}
	// A rejected source range still passes audio through; it latches the
	// audio-domain invalid state inside the engine. Only a malformed request is
	// a process error.
	_ = meter.engine_push_passthrough(instance, input, output, int(request.frames), request.steady_time)
	return .Continue
}

// ---------------------------------------------------------------------------
// Canonical records (CLAP wire conversion)
// ---------------------------------------------------------------------------

to_clap_record :: proc(record: meter.Measurement_Record) -> Measurement_Record {
	return Measurement_Record{
		schema_version = record.schema_version,
		epoch = record.epoch,
		generation = record.generation,
		start_frame = record.start_frame,
		frames = record.frames,
		channels = record.channels,
		sample_rate = record.sample_rate,
		peak = record.peak,
		peak_frame = record.peak_frame,
		rms = record.rms,
		hold = record.hold,
		valid = record.valid,
		overrun = record.overrun,
		capture_valid = record.capture_valid,
	}
}

meter_measurement_pending :: proc(instance: ^Meter) -> int {
	return meter.engine_measurement_pending(instance)
}

// meter_measurement_drain copies pending records oldest-first into a CLAP wire
// record array. The engine record is layout-compatible, so the destination
// slice is reinterpreted rather than copied.
meter_measurement_drain :: proc(instance: ^Meter, destination: []Measurement_Record) -> int {
	if len(destination) == 0 {
		return 0
	}
	engine_destination := mem.slice_data_cast([]meter.Measurement_Record, destination)
	return meter.engine_measurement_drain(instance, engine_destination)
}

meter_measurement_dropped :: proc(instance: ^Meter) -> u64 {
	return meter.engine_measurement_dropped(instance)
}

meter_measurement_high_water :: proc(instance: ^Meter) -> u64 {
	return meter.engine_measurement_high_water(instance)
}

// ---------------------------------------------------------------------------
// Capture mode (verification seam)
// ---------------------------------------------------------------------------

meter_capture_enabled :: proc(instance: ^Meter) -> bool {
	return meter.engine_capture_enabled(instance)
}

meter_capture_set_enabled :: proc(instance: ^Meter, enabled: bool) -> Capture_Set_Result {
	return meter.engine_capture_set_enabled(instance, enabled)
}

meter_capture_valid :: proc(instance: ^Meter) -> bool {
	return meter.engine_capture_valid(instance)
}

meter_capture_schema_version :: proc(instance: ^Meter) -> u32 {
	return meter.engine_capture_schema_version(instance)
}

Sink_Bridge :: struct {
	sink: clap.Carnival_Capture_Sink,
}

sink_bridge_push :: proc(ctx: rawptr, record: ^meter.Measurement_Record) -> bool {
	bridge := cast(^Sink_Bridge)ctx
	if bridge == nil || record == nil || bridge.sink.push == nil {
		return false
	}
	converted := to_clap_record(record^)
	return bridge.sink.push(bridge.sink.ctx, &converted)
}

// meter_measurement_drain_sink delivers records through a host callback. The
// pointer is valid only for the callback; the read cursor advances only after
// the sink returns true.
meter_measurement_drain_sink :: proc(
	instance: ^Meter,
	sink: clap.Carnival_Capture_Sink,
	max_records: u32,
) -> u32 {
	if sink.push == nil {
		return 0
	}
	bridge := Sink_Bridge{sink = sink}
	return meter.engine_measurement_drain_sink(
		instance,
		meter.Measurement_Sink{ctx = rawptr(&bridge), push = sink_bridge_push},
		max_records,
	)
}

// meter_snapshot is the latest-wins presentation view.
meter_snapshot :: proc(instance: ^Meter) -> transport.Measurement_Snapshot {
	return meter.engine_snapshot(instance)
}

// ---------------------------------------------------------------------------
// Test seams
// ---------------------------------------------------------------------------

meter_test_set_drain_enabled :: proc(instance: ^Meter, enabled: bool) {
	meter.engine_test_set_drain_enabled(instance, enabled)
}
