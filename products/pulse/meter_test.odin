// Headless Pulse plugin tests.
//
// Lifecycle and authoring state go through the CLAP ABI with a minimal host
// harness. Measurement, passthrough, partition and drain-cadence tests drive
// the same backend entry point directly, which keeps the expected values cheap
// to express without bypassing the real processing path.
package pulse

import "core:fmt"
import "core:math"
import "core:mem"
import "core:slice"
import "core:testing"
import "core:time"

import adapter "carnival:adapters/clap"
import clap "carnival:third_party/clap/abi"
import "carnival:core/stream"

MAX_TEST_FRAMES :: 8192
MAX_TEST_RECORDS :: 512
PARTITION_FRAMES :: 10000

// ---------------------------------------------------------------------------
// Direct backend harness
// ---------------------------------------------------------------------------

Direct :: struct {
	meter:    ^Meter,
	input:    [2][MAX_TEST_FRAMES]f32,
	output:   [2][MAX_TEST_FRAMES]f32,
	params:   [4]f64,
}

direct_init :: proc(t: ^testing.T, max_frames: u32, rate: int = 48000) -> Direct {
	result: Direct
	result.meter = meter_create()
	if result.meter == nil {
		testing.fail_now(t, "meter_create")
	}
	result.params = {1024, 4800, 1, 20}
	config := adapter.Activation_Config{sample_rate = f64(rate), min_frames_count = 1, max_frames_count = max_frames}
	if !meter_activate(result.meter, config) {
		testing.fail_now(t, "meter_activate")
	}
	return result
}

direct_destroy :: proc(harness: ^Direct) {
	meter_destroy(harness.meter)
}

// direct_process feeds one block from interleaved source frames.
direct_process :: proc(harness: ^Direct, source: []f32, frames: int) -> adapter.Process_Result {
	if frames <= 0 || len(source) < frames * CHANNELS {
		return .Error
	}
	for frame in 0 ..< frames {
		for channel in 0 ..< CHANNELS {
			harness.input[channel][frame] = source[frame * CHANNELS + channel]
		}
	}
	in_ptrs := [2]^f32{&harness.input[0][0], &harness.input[1][0]}
	out_ptrs := [2]^f32{&harness.output[0][0], &harness.output[1][0]}
	request := adapter.Process_Request{
		frames = u32(frames),
		channels = CHANNELS,
		input = cast([^]^f32)&in_ptrs[0],
		output = cast([^]^f32)&out_ptrs[0],
		params = harness.params[:],
	}
	return meter_process(harness.meter, &request)
}

direct_process_in_place :: proc(harness: ^Direct, source: []f32, frames: int) -> adapter.Process_Result {
	for frame in 0 ..< frames {
		for channel in 0 ..< CHANNELS {
			harness.input[channel][frame] = source[frame * CHANNELS + channel]
		}
	}
	in_ptrs := [2]^f32{&harness.input[0][0], &harness.input[1][0]}
	request := adapter.Process_Request{
		frames = u32(frames),
		channels = CHANNELS,
		input = cast([^]^f32)&in_ptrs[0],
		output = cast([^]^f32)&in_ptrs[0],
		params = harness.params[:],
		in_place = true,
	}
	return meter_process(harness.meter, &request)
}

Drain :: struct {
	records: [MAX_TEST_RECORDS]Measurement_Record,
	count:   int,
}

direct_drain :: proc(harness: ^Direct, drain: ^Drain) {
	for drain.count < MAX_TEST_RECORDS {
		read := meter_measurement_drain(harness.meter, drain.records[drain.count:])
		if read <= 0 {
			break
		}
		drain.count += read
	}
}

sine_stream :: proc(frames: int, rate: int, amplitude_left, amplitude_right: f32, frequency: f64 = 750) -> []f32 {
	left := make([]f32, frames)
	right := make([]f32, frames)
	interleaved := make([]f32, frames * 2)
	_ = stream.generate_sine(left, rate, 1, frequency, f64(amplitude_left))
	_ = stream.generate_sine(right, rate, 1, frequency, f64(amplitude_right))
	planar := [][]f32{left, right}
	_ = stream.interleave_f32(interleaved, planar, frames, 2)
	delete(left)
	delete(right)
	return interleaved
}

records_equal :: proc(a, b: Measurement_Record) -> bool {
	if a.epoch != b.epoch || a.generation != b.generation || a.start_frame != b.start_frame ||
		a.frames != b.frames || a.channels != b.channels || a.sample_rate != b.sample_rate ||
		a.valid != b.valid || a.overrun != b.overrun {
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

@(test)
test_silence_impulse_and_sine_measurements :: proc(t: ^testing.T) {
	harness := direct_init(t, 1024)
	defer direct_destroy(&harness)

	// Digital silence is valid, reports peak/RMS 0 and the documented DBFS floor.
	silence := make([]f32, 2048 * 2)
	defer delete(silence)
	for frame in 0 ..< 2048 {
		testing.expect_value(t, direct_process(&harness, silence[frame * 2:], 1), adapter.Process_Result.Continue)
	}
	drain: Drain
	direct_drain(&harness, &drain)
	testing.expect_value(t, drain.count, 2)
	testing.expect(t, drain.records[0].valid, "silence valid")
	testing.expect_value(t, drain.records[0].rms[0], f32(0))
	testing.expect_value(t, drain.records[0].peak[0], f32(0))
	snapshot := meter_snapshot(harness.meter)
	testing.expect_value(t, snapshot.rms_db[0], f32(-144.0))
	testing.expect_value(t, snapshot.peak_db[0], f32(-144.0))
	testing.expect(t, snapshot.valid, "silence snapshot valid")

	// Impulse: exact peak frame and closed-form RMS for one sample in 1024.
	impulse := make([]f32, 1024 * 2)
	defer delete(impulse)
	impulse[100 * 2] = 1
	testing.expect_value(t, direct_process(&harness, impulse, 1024), adapter.Process_Result.Continue)
	drain = {}
	direct_drain(&harness, &drain)
	testing.expect_value(t, drain.count, 1)
	testing.expect_value(t, drain.records[0].peak[0], f32(1))
	testing.expect_value(t, drain.records[0].peak_frame[0], i64(2148))
	// One unit sample over 1024: sqrt(1/1024) = 0.03125 exactly.
	testing.expect_value(t, drain.records[0].rms[0], f32(0.03125))
	testing.expect_value(t, drain.records[0].hold[0], f32(1))

	// Stereo sine with different amplitudes: closed-form RMS per channel.
	harness2 := direct_init(t, 512)
	defer direct_destroy(&harness2)
	FRAMES :: 4800
	sine := sine_stream(FRAMES, 48000, 0.5, 0.25)
	defer delete(sine)
	offset := 0
	for offset < FRAMES {
		count := min(128, FRAMES - offset)
		testing.expect_value(t, direct_process(&harness2, sine[offset * 2:], count), adapter.Process_Result.Continue)
		offset += count
	}
	sine_drain: Drain
	direct_drain(&harness2, &sine_drain)
	testing.expect_value(t, sine_drain.count, 4)
	expected_left := f32(0.3535533905932738)
	expected_right := f32(0.1767766952966369)
	for record in sine_drain.records[:sine_drain.count] {
		testing.expect(t, record.valid, "sine record valid")
		testing.expectf(t, math.abs(record.rms[0] - expected_left) < 1e-4,
			"left RMS %v vs %v", record.rms[0], expected_left)
		testing.expectf(t, math.abs(record.rms[1] - expected_right) < 1e-4,
			"right RMS %v vs %v", record.rms[1], expected_right)
		testing.expectf(t, record.peak[0] <= 0.5 && record.peak[0] > 0.499,
			"left peak %v", record.peak[0])
	}
	testing.expect_value(t, sine_drain.records[0].start_frame, i64(0))
	testing.expect_value(t, sine_drain.records[1].start_frame, i64(1024))
	testing.expect_value(t, sine_drain.records[3].start_frame, i64(3072))
}

@(test)
test_sample_rate_matrix_and_deterministic_noise :: proc(t: ^testing.T) {
	rates := [?]int{44100, 48000, 96000}
	for rate in rates {
		harness := direct_init(t, 512, rate)
		// Bin-centred 16-cycle tone in a 1024-frame window.
		frequency := f64(rate) / 64.0
		sine := sine_stream(4096, rate, 0.5, 0.5, frequency)
		offset := 0
		partition := 0
		sizes := [?]int{64, 128, 512}
		for offset < 4096 {
			count := min(sizes[partition % len(sizes)], 4096 - offset)
			testing.expect_value(t, direct_process(&harness, sine[offset * 2:], count),
				adapter.Process_Result.Continue)
			offset += count
			partition += 1
		}
		drain: Drain
		direct_drain(&harness, &drain)
		testing.expect_value(t, drain.count, 4)
		for record in drain.records[:drain.count] {
			testing.expect(t, record.valid, "rate matrix record valid")
			testing.expectf(t, math.abs(record.rms[0] - 0.3535533905932738) < 1e-3,
				"rate %d RMS %v", rate, record.rms[0])
		}
		direct_destroy(&harness)
		delete(sine)
	}

	// Deterministic noise: valid records, finite values, and peak bounded by
	// the generated amplitude.
	harness := direct_init(t, 512)
	defer direct_destroy(&harness)
	noise := make([]f32, 4096 * 2)
	defer delete(noise)
	state: u32 = 0x9E3779B9
	for index in 0 ..< len(noise) {
		state = state * 1664525 + 1013904223
		noise[index] = f32(i32(state >> 8) % 65536) / 65536 * 0.5
	}
	offset := 0
	for offset < 4096 {
		count := min(127, 4096 - offset)
		testing.expect_value(t, direct_process(&harness, noise[offset * 2:], count),
			adapter.Process_Result.Continue)
		offset += count
	}
	drain: Drain
	direct_drain(&harness, &drain)
	testing.expect_value(t, drain.count, 4)
	for record in drain.records[:drain.count] {
		testing.expect(t, record.valid, "noise record valid")
		for channel in 0 ..< CHANNELS {
			testing.expect(t, !math.is_nan(record.rms[channel]), "noise RMS finite")
			testing.expect(t, record.peak[channel] <= 0.5, "noise peak bounded")
		}
	}
}

@(test)
test_partition_and_drain_cadence_do_not_change_records :: proc(t: ^testing.T) {
	sine := sine_stream(PARTITION_FRAMES, 48000, 0.6, 0.3)
	defer delete(sine)

	run := proc(t: ^testing.T, source: []f32, partition: int, drain_each_block: bool) -> Drain {
		harness := direct_init(t, 1024)
		defer direct_destroy(&harness)
		result: Drain
		offset := 0
		for offset < PARTITION_FRAMES {
			count := min(partition, PARTITION_FRAMES - offset)
			testing.expect_value(t, direct_process(&harness, source[offset * 2:], count),
				adapter.Process_Result.Continue)
			if drain_each_block {
				read := meter_measurement_drain(harness.meter, result.records[result.count:])
				result.count += read
				// Snapshot cadence must be irrelevant; this run reads the
				// presentation snapshot every block, the others never do.
				_ = meter_snapshot(harness.meter)
			}
			offset += count
		}
		if !drain_each_block {
			direct_drain(&harness, &result)
		} else {
			direct_drain(&harness, &result)
		}
		return result
	}

	baseline := run(t, sine, 128, true)
	testing.expect_value(t, baseline.count, 9)
	partitions := [?]int{64, 256, 512, 997}
	for partition in partitions {
		result := run(t, sine, partition, false)
		testing.expect_value(t, result.count, baseline.count)
		for index in 0 ..< min(result.count, baseline.count) {
			testing.expectf(t, records_equal(result.records[index], baseline.records[index]),
				"partition %d record %d differs", partition, index)
		}
	}
}

@(test)
test_passthrough_bit_exact_non_in_place_and_in_place :: proc(t: ^testing.T) {
	harness := direct_init(t, 1024)
	defer direct_destroy(&harness)

	bits: u32 = 0x1234_5678
	source := make([]f32, 2048 * 2)
	defer delete(source)
	for index in 0 ..< len(source) {
		bits = bits * 1664525 + 1013904223
		value := transmute(f32)bits
		if math.is_nan(value) || math.is_inf(value) {
			value = f32(i32(bits % 2001) - 1000) / 1000
		}
		source[index] = value
	}
	// Include exact boundary values and a subnormal bit pattern.
	source[0] = -1
	source[1] = 1
	source[2] = transmute(f32)u32(1)
	source[3] = 0

	offset := 0
	for offset < 2048 {
		count := min(97, 2048 - offset)
		testing.expect_value(t, direct_process(&harness, source[offset * 2:], count), adapter.Process_Result.Continue)
		for frame in 0 ..< count {
			for channel in 0 ..< CHANNELS {
				testing.expect_value(t, transmute(u32)harness.output[channel][frame],
					transmute(u32)source[(offset + frame) * 2 + channel])
			}
		}
		offset += count
	}

	// In-place: output and input are the same channel pointers.
	in_place := make([]f32, 512 * 2)
	defer delete(in_place)
	for index in 0 ..< len(in_place) {
		bits = bits * 1664525 + 1013904223
		in_place[index] = transmute(f32)bits
	}
	testing.expect_value(t, direct_process_in_place(&harness, in_place, 512), adapter.Process_Result.Continue)
	for frame in 0 ..< 512 {
		for channel in 0 ..< CHANNELS {
			testing.expect_value(t, transmute(u32)harness.input[channel][frame],
				transmute(u32)in_place[frame * 2 + channel])
		}
	}
}

@(test)
test_forced_overrun_invalidates_without_breaking_passthrough :: proc(t: ^testing.T) {
	harness := direct_init(t, 256)
	defer direct_destroy(&harness)
	meter_test_set_drain_enabled(harness.meter, false)

	source := make([]f32, 256 * 2)
	defer delete(source)
	for frame in 0 ..< 256 {
		source[frame * 2 + 0] = f32(frame) * 1e-3
		source[frame * 2 + 1] = -f32(frame) * 1e-3
	}
	// Fill the ring, then force at least one overrun drop.
	for _ in 0 ..< RING_CAPACITY_BLOCKS + 2 {
		testing.expect_value(t, direct_process(&harness, source, 256), adapter.Process_Result.Continue)
		for frame in 0 ..< 256 {
			testing.expect_value(t, transmute(u32)harness.output[0][frame],
				transmute(u32)source[frame * 2])
		}
	}
	testing.expect(t, transport_overrun_seen(harness.meter), "overrun latched")
	snapshot := meter_snapshot(harness.meter)
	testing.expect(t, snapshot.overrun, "snapshot overrun")
	testing.expect(t, !snapshot.valid, "overrun snapshot invalid")

	// Re-enable draining; remaining queued blocks produce explicitly invalid
	// records, and passthrough still works.
	meter_test_set_drain_enabled(harness.meter, true)
	testing.expect_value(t, direct_process(&harness, source, 256), adapter.Process_Result.Continue)
	drain: Drain
	direct_drain(&harness, &drain)
	testing.expect(t, drain.count > 0, "records emitted")
	for record in drain.records[:drain.count] {
		testing.expect(t, !record.valid, "record invalid after overrun")
		testing.expect(t, record.overrun, "record overrun flag")
	}
	snapshot = meter_snapshot(harness.meter)
	testing.expect(t, snapshot.overrun && !snapshot.valid, "invalid latched until reset")

	meter_reset(harness.meter)
	snapshot = meter_snapshot(harness.meter)
	testing.expect(t, !snapshot.overrun, "reset clears the latch")
	drain = {}
	testing.expect_value(t, direct_process(&harness, source, 256), adapter.Process_Result.Continue)
	direct_drain(&harness, &drain)
	// No window completed in one 256-frame block with a 1024-frame window.
	testing.expect_value(t, drain.count, 0)
}

// Keep the transport import exercised without leaking it into the product API.
@(private)
transport_overrun_seen :: proc(meter: ^Meter) -> bool {
	return meter.invalid && meter.ring.overrun_latched != 0
}

@(test)
test_reset_starts_new_epoch_and_clears_export :: proc(t: ^testing.T) {
	harness := direct_init(t, 1024)
	defer direct_destroy(&harness)
	sine := sine_stream(2048, 48000, 0.5, 0.5)
	defer delete(sine)
	testing.expect_value(t, direct_process(&harness, sine, 1024), adapter.Process_Result.Continue)
	testing.expect_value(t, direct_process(&harness, sine[1024 * 2:], 1024), adapter.Process_Result.Continue)
	before: Drain
	direct_drain(&harness, &before)
	testing.expect_value(t, before.count, 2)
	old_epoch := before.records[0].epoch

	meter_reset(harness.meter)
	testing.expect_value(t, meter_measurement_pending(harness.meter), 0)
	testing.expect_value(t, direct_process(&harness, sine[1024 * 2:], 1024), adapter.Process_Result.Continue)
	after: Drain
	direct_drain(&harness, &after)
	testing.expect_value(t, after.count, 1)
	testing.expect(t, after.records[0].epoch > old_epoch, "epoch advanced")
	testing.expect_value(t, after.records[0].start_frame, i64(0))
}

// ---------------------------------------------------------------------------
// CLAP harness
// ---------------------------------------------------------------------------

Test_Host :: struct {
	extensions: int,
}

Harness :: struct {
	host:     clap.Host,
	state:    Test_Host,
	input:    [2][1024]f32,
	output:   [2][1024]f32,
	in_ptrs:  [2]^f32,
	out_ptrs: [2]^f32,
	audio_in:  clap.Audio_Buffer,
	audio_out: clap.Audio_Buffer,
	inputs:   [1]clap.Audio_Buffer,
	outputs:  [1]clap.Audio_Buffer,
}

host_extension :: proc "c" (host: ^clap.Host, id: cstring) -> rawptr {
	_ = id
	(cast(^Test_Host)host.host_data).extensions += 1
	return nil
}

host_restart :: proc "c" (host: ^clap.Host) {}
host_process :: proc "c" (host: ^clap.Host) {}
host_callback :: proc "c" (host: ^clap.Host) {}

prepare_harness :: proc(harness: ^Harness) {
	harness.in_ptrs = {&harness.input[0][0], &harness.input[1][0]}
	harness.out_ptrs = {&harness.output[0][0], &harness.output[1][0]}
	harness.audio_in = clap.Audio_Buffer{data32 = cast([^]^f32)&harness.in_ptrs[0], channel_count = 2}
	harness.audio_out = clap.Audio_Buffer{data32 = cast([^]^f32)&harness.out_ptrs[0], channel_count = 2}
	harness.inputs[0] = harness.audio_in
	harness.outputs[0] = harness.audio_out
	harness.host = clap.Host{
		clap_version = clap.CLAP_VERSION,
		host_data = &harness.state,
		name = "pulse test host",
		vendor = "Carnival Science",
		version = "0.1.0",
		get_extension = host_extension,
		request_restart = host_restart,
		request_process = host_process,
		request_callback = host_callback,
	}
}

create_plugin :: proc(t: ^testing.T) -> (^clap.Plugin, ^Harness) {
	adapter.register_definition(&pulse_definition)
	if !adapter.entry_init("pulse-test.clap") {
		testing.fail_now(t, "entry_init")
	}
	factory := cast(^clap.Plugin_Factory)adapter.entry_get_factory(cstring(clap.CLAP_PLUGIN_FACTORY_ID))
	if factory == nil {
		testing.fail_now(t, "factory")
	}
	harness := new(Harness)
	prepare_harness(harness)
	plugin := factory.create_plugin(factory, &harness.host, cstring(PULSE_PLUGIN_ID))
	if plugin == nil {
		testing.fail_now(t, "create_plugin")
	}
	return plugin, harness
}

destroy_plugin :: proc(plugin: ^clap.Plugin, harness: ^Harness) {
	plugin.destroy(plugin)
	free(harness)
	adapter.entry_deinit()
}

params_of :: proc(plugin: ^clap.Plugin) -> ^clap.Plugin_Params {
	return cast(^clap.Plugin_Params)plugin.get_extension(plugin, cstring(clap.CLAP_EXT_PARAMS))
}

state_of :: proc(plugin: ^clap.Plugin) -> ^clap.Plugin_State {
	return cast(^clap.Plugin_State)plugin.get_extension(plugin, cstring(clap.CLAP_EXT_STATE))
}

@(test)
test_clap_lifecycle_two_instances_and_reset :: proc(t: ^testing.T) {
	plugin_a, harness_a := create_plugin(t)
	plugin_b, harness_b := create_plugin(t)
	defer destroy_plugin(plugin_a, harness_a)
	defer destroy_plugin(plugin_b, harness_b)

	testing.expect(t, plugin_a.init(plugin_a) && plugin_b.init(plugin_b), "init")
	testing.expect(t, plugin_a.activate(plugin_a, 48000, 64, 512), "activate a")
	testing.expect(t, plugin_b.activate(plugin_b, 48000, 64, 512), "activate b")
	testing.expect(t, plugin_a.start_processing(plugin_a) && plugin_b.start_processing(plugin_b), "start")

	for frame in 0 ..< 64 {
		harness_a.input[0][frame] = 0.5
		harness_a.input[1][frame] = -0.25
		harness_b.input[0][frame] = 0.125
		harness_b.input[1][frame] = 0.0
	}
	process_a := clap.Process{
		frames_count = 64,
		audio_inputs = &harness_a.inputs[0],
		audio_outputs = &harness_a.outputs[0],
		audio_inputs_count = 1,
		audio_outputs_count = 1,
	}
	process_b := process_a
	process_b.audio_inputs = &harness_b.inputs[0]
	process_b.audio_outputs = &harness_b.outputs[0]
	testing.expect_value(t, plugin_a.process(plugin_a, &process_a), clap.Process_Status(clap.CLAP_PROCESS_CONTINUE))
	testing.expect_value(t, plugin_b.process(plugin_b, &process_b), clap.Process_Status(clap.CLAP_PROCESS_CONTINUE))
	for frame in 0 ..< 64 {
		testing.expect_value(t, harness_a.output[0][frame], f32(0.5))
		testing.expect_value(t, harness_b.output[0][frame], f32(0.125))
	}

	// Reset via CLAP, then process the next block.
	plugin_a.reset(plugin_a)
	process_a.steady_time = 64
	testing.expect_value(t, plugin_a.process(plugin_a, &process_a), clap.Process_Status(clap.CLAP_PROCESS_CONTINUE))
	// Instance B was not reset; its independent state is untouched.
	testing.expect_value(t, harness_b.output[0][0], f32(0.125))
}

Mem_Stream :: struct {
	data: [4096]u8,
	size: int,
	read: int,
}

mem_write :: proc "c" (stream: ^clap.OStream, buffer: rawptr, size: u64) -> i64 {
	state := cast(^Mem_Stream)stream.ctx
	if state.size + int(size) > len(state.data) {
		return -1
	}
	copy(state.data[state.size:state.size + int(size)], ([^]u8)(buffer)[:int(size)])
	state.size += int(size)
	return i64(size)
}

mem_read :: proc "c" (stream: ^clap.IStream, buffer: rawptr, size: u64) -> i64 {
	state := cast(^Mem_Stream)stream.ctx
	available := state.size - state.read
	count := min(int(size), available)
	if count <= 0 {
		return 0
	}
	copy(([^]u8)(buffer)[:count], state.data[state.read:state.read + count])
	state.read += count
	return i64(count)
}

put_u32 :: proc(buffer: []u8, offset: int, value: u32) {
	buffer[offset + 0] = u8(value)
	buffer[offset + 1] = u8(value >> 8)
	buffer[offset + 2] = u8(value >> 16)
	buffer[offset + 3] = u8(value >> 24)
}

put_f64 :: proc(buffer: []u8, offset: int, value: f64) {
	bits := transmute(u64)value
	for index in 0 ..< 8 {
		buffer[offset + index] = u8(bits >> (8 * u64(index)))
	}
}

@(test)
test_authoring_state_round_trip_is_processing_independent :: proc(t: ^testing.T) {
	plugin, harness := create_plugin(t)
	defer destroy_plugin(plugin, harness)
	testing.expect(t, plugin.init(plugin), "init")
	testing.expect(t, plugin.activate(plugin, 48000, 64, 512), "activate")
	testing.expect(t, plugin.start_processing(plugin), "start")
	state := state_of(plugin)
	testing.expect(t, state != nil, "state extension")

	first := Mem_Stream{}
	ostream := clap.OStream{ctx = &first, write = mem_write}
	testing.expect(t, state.save(plugin, &ostream), "save before process")

	process := clap.Process{
		frames_count = 64,
		audio_inputs = &harness.inputs[0],
		audio_outputs = &harness.outputs[0],
		audio_inputs_count = 1,
		audio_outputs_count = 1,
	}
	for frame in 0 ..< 64 {
		harness.input[0][frame] = 0.25
	}
	testing.expect_value(t, plugin.process(plugin, &process), clap.Process_Status(clap.CLAP_PROCESS_CONTINUE))

	second := Mem_Stream{}
	ostream = clap.OStream{ctx = &second, write = mem_write}
	testing.expect(t, state.save(plugin, &ostream), "save after process")
	testing.expect_value(t, second.size, first.size)
	testing.expect(t, mem.compare(first.data[:first.size], second.data[:second.size]) == 0,
		"processing state does not enter authoring state")

	// Change a parameter, load the first state, and read the restored value.
	params := params_of(plugin)
	stream := first
	stream.read = 0
	istream := clap.IStream{ctx = &stream, read = mem_read}
	testing.expect(t, state.load(plugin, &istream), "load")
	value: f64
	testing.expect(t, params.get_value(plugin, PARAM_WINDOW_FRAMES, &value), "get")
	testing.expect_value(t, value, f64(1024))
}

@(test)
test_state_v1_fixture_migrates_to_schema_2 :: proc(t: ^testing.T) {
	plugin, harness := create_plugin(t)
	defer destroy_plugin(plugin, harness)
	testing.expect(t, plugin.init(plugin), "init")
	state := state_of(plugin)
	params := params_of(plugin)

	// Historical schema 1 fixture: IDs 1001..1003 only, no 1004.
	fixture := Mem_Stream{}
	copy(fixture.data[:8], pulse_definition.state_magic[:])
	put_u32(fixture.data[:], 8, 1)
	put_u32(fixture.data[:], 12, 3)
	put_u32(fixture.data[:], 16, PARAM_WINDOW_FRAMES)
	put_f64(fixture.data[:], 20, 512)
	put_u32(fixture.data[:], 28, PARAM_HOLD_FRAMES)
	put_f64(fixture.data[:], 32, 0)
	put_u32(fixture.data[:], 40, PARAM_HOLD_DECAY_ENABLED)
	put_f64(fixture.data[:], 44, 0)
	fixture.size = 52

	istream := clap.IStream{ctx = &fixture, read = mem_read}
	testing.expect(t, state.load(plugin, &istream), "load v1")
	value: f64
	testing.expect(t, params.get_value(plugin, PARAM_WINDOW_FRAMES, &value), "v1 window")
	testing.expect_value(t, value, f64(512))
	testing.expect(t, params.get_value(plugin, PARAM_HOLD_FRAMES, &value), "v1 hold")
	testing.expect_value(t, value, f64(0))
	testing.expect(t, params.get_value(plugin, PARAM_HOLD_DECAY_ENABLED, &value), "v1 decay enabled")
	testing.expect_value(t, value, f64(0))
	// The schema-2-only parameter keeps its descriptor default.
	testing.expect(t, params.get_value(plugin, PARAM_HOLD_DECAY_DB, &value), "v2 decay rate migrated")
	testing.expect_value(t, value, f64(20))

	saved := Mem_Stream{}
	ostream := clap.OStream{ctx = &saved, write = mem_write}
	testing.expect(t, state.save(plugin, &ostream), "save migrated")
	testing.expect_value(t, get_u32(saved.data[:], 8), u32(2))
	testing.expect_value(t, get_u32(saved.data[:], 12), u32(4))
}

get_u32 :: proc(buffer: []u8, offset: int) -> u32 {
	return u32(buffer[offset]) | u32(buffer[offset + 1]) << 8 |
		u32(buffer[offset + 2]) << 16 | u32(buffer[offset + 3]) << 24
}

// ---------------------------------------------------------------------------
// RT allocation probe over the full adapter + product path
// ---------------------------------------------------------------------------

Alloc_Probe :: struct {
	backing: mem.Allocator,
	allocs:  int,
	frees:   int,
}

probe_proc :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size: int,
	alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	probe := cast(^Alloc_Probe)data
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		probe.allocs += 1
		return mem.alloc_bytes(size, alignment, probe.backing)
	case .Free:
		probe.frees += 1
		return nil, mem.free(old_memory, probe.backing)
	case .Resize, .Resize_Non_Zeroed:
		return mem.resize_bytes(mem.byte_slice(old_memory, old_size), size, alignment, probe.backing)
	case .Query_Features, .Query_Info:
		return nil, .None
	case .Free_All:
		return nil, .Mode_Not_Implemented
	}
	return nil, .Mode_Not_Implemented
}

@(test)
test_full_plugin_process_makes_no_context_allocations :: proc(t: ^testing.T) {	plugin, harness := create_plugin(t)
	defer destroy_plugin(plugin, harness)
	testing.expect(t, plugin.init(plugin), "init")
	testing.expect(t, plugin.activate(plugin, 48000, 64, 512), "activate")
	testing.expect(t, plugin.start_processing(plugin), "start")

	probe := Alloc_Probe{backing = context.allocator}
	allocator := mem.Allocator{procedure = probe_proc, data = rawptr(&probe)}
	adapter.set_process_allocator(allocator)
	defer adapter.set_process_allocator({})

	process := clap.Process{
		frames_count = 512,
		audio_inputs = &harness.inputs[0],
		audio_outputs = &harness.outputs[0],
		audio_inputs_count = 1,
		audio_outputs_count = 1,
	}
	for frame in 0 ..< 512 {
		harness.input[0][frame] = f32(frame) * 1e-4
		harness.input[1][frame] = -f32(frame) * 1e-4
	}
	for iteration in 0 ..< 64 {
		process.steady_time = i64(iteration * 512)
		testing.expect_value(t, plugin.process(plugin, &process), clap.Process_Status(clap.CLAP_PROCESS_CONTINUE))
	}
	testing.expect_value(t, probe.allocs, 0)

}

// Observation only: prints a timing distribution for the evidence record. It
// deliberately asserts no wall-clock threshold; CI timings are not real-time
// proofs and vary by machine/OS.
@(test)
test_process_timing_observation :: proc(t: ^testing.T) {
	BLOCKS :: 5000
	FRAMES :: 256
	harness := direct_init(t, FRAMES)
	defer direct_destroy(&harness)
	source := make([]f32, FRAMES * 2)
	defer delete(source)
	for frame in 0 ..< FRAMES {
		source[frame * 2] = f32(frame) * 1e-5
		source[frame * 2 + 1] = -f32(frame) * 1e-5
	}
	timings: [BLOCKS]f64
	for block in 0 ..< BLOCKS {
		start := time.tick_now()
		testing.expect_value(t, direct_process(&harness, source, FRAMES), adapter.Process_Result.Continue)
		elapsed := time.tick_diff(start, time.tick_now())
		timings[block] = time.duration_seconds(elapsed) * 1e6 // microseconds
	}
	slice.sort(timings[:BLOCKS])
	p50 := timings[BLOCKS * 50 / 100]
	p95 := timings[BLOCKS * 95 / 100]
	p99 := timings[BLOCKS * 99 / 100]
	maximum := timings[BLOCKS - 1]
	fmt.printf("process timing (256 frames, 48kHz): p50 %.2f us, p95 %.2f us, p99 %.2f us, max %.2f us; pending records %d, high-water %d, dropped %d\n",
		p50, p95, p99, maximum,
		meter_measurement_pending(harness.meter),
		meter_measurement_high_water(harness.meter),
		meter_measurement_dropped(harness.meter))
	testing.expect_value(t, meter_measurement_dropped(harness.meter), u64(0))

	// Cold activation observation (create + activate, including all storage).
	cold_start := time.tick_now()
	cold := meter_create()
	config := adapter.Activation_Config{sample_rate = 48000, min_frames_count = 1, max_frames_count = 512}
	testing.expect(t, meter_activate(cold, config), "cold activate")
	cold_us := time.duration_seconds(time.tick_diff(cold_start, time.tick_now())) * 1e6
	meter_destroy(cold)
	fmt.printf("cold create+activate (max 512 frames): %.2f us\n", cold_us)
}



