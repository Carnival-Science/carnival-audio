// Headless host harness tests for the generic CLAP adapter.
//
// The harness uses the same CLAP ABI procs as an external host: entry ->
// factory -> plugin -> init -> activate -> start -> process -> stop ->
// deactivate -> destroy, plus audio-ports, params and state extensions. It
// deliberately does not use a real DAW.
package clap_adapter

import "core:mem"
import "core:testing"

import clap "carnival:third_party/clap/abi"

// ---------------------------------------------------------------------------
// Test backend
// ---------------------------------------------------------------------------

TEST_DESCRIPTOR_ID :: "com.carnival-science.clap-adapter-test"
TEST_STATE_MAGIC :: [8]u8{'T', 'E', 'S', 'T', 'S', 'T', 'A', 'T'}
TEST_SCHEMA :: u32(1)

Test_Data :: struct {
	calls:        int,
	last_frames:  u32,
	reset_calls:  int,
	start_calls:  int,
	stop_calls:   int,
	capture_enabled: bool,
	capture_dropped: u64,
	capture_valid:   bool,
	capture_records: [2]clap.Carnival_Measurement_Record,
	capture_count:   u32,
	capture_read:    u32,
}

test_create :: proc() -> rawptr {
	data := new(Test_Data)
	data.capture_valid = true
	return data
}

test_destroy :: proc(data: rawptr) {
	free(cast(^Test_Data)data)
}

test_init :: proc(data: rawptr, host: ^Host_Info) -> bool {
	_ = data
	return host != nil && host.host != nil
}

test_activate :: proc(data: rawptr, config: Activation_Config) -> bool {
	_ = data
	return config.sample_rate > 0 && config.max_frames_count >= 1
}

test_deactivate :: proc(data: rawptr) {
	_ = data
}

test_start :: proc(data: rawptr) -> bool {
	(cast(^Test_Data)data).start_calls += 1
	return true
}

test_stop :: proc(data: rawptr) {
	(cast(^Test_Data)data).stop_calls += 1
}

test_reset :: proc(data: rawptr) {
	(cast(^Test_Data)data).reset_calls += 1
}

test_process :: proc(data: rawptr, request: ^Process_Request) -> Process_Result {
	instance := cast(^Test_Data)data
	instance.calls += 1
	instance.last_frames = request.frames
	gain := f32(1)
	if len(request.params) > 0 {
		gain = f32(request.params[0])
	}
	for channel in 0 ..< request.channels {
		source := cast([^]f32)request.input[channel]
		destination := cast([^]f32)request.output[channel]
		for frame in 0 ..< int(request.frames) {
			destination[frame] = source[frame] * gain
		}
	}
	return .Continue
}

test_backend: Backend_VTable = {
	create = test_create,
	destroy = test_destroy,
	init = test_init,
	activate = test_activate,
	deactivate = test_deactivate,
	start = test_start,
	stop = test_stop,
	reset = test_reset,
	process = test_process,
	telemetry = &test_telemetry,
}

// Adapter-level telemetry: a minimal backend implementation used to prove the
// adapter's draft-extension forwarding and the host sink callback.
test_telemetry_set_enabled :: proc(data: rawptr, enabled: bool) -> bool {
	instance := cast(^Test_Data)data
	instance.capture_enabled = enabled
	instance.capture_dropped = 0
	instance.capture_valid = true
	instance.capture_count = enabled ? 2 : 0
	instance.capture_read = 0
	if enabled {
		for index in 0 ..< 2 {
			instance.capture_records[index] = clap.Carnival_Measurement_Record{
				schema_version = clap.CARNIVAL_MEASUREMENT_SCHEMA_VERSION,
				generation = u64(index + 1),
				start_frame = i64(index) * 1024,
				frames = 1024,
				channels = 2,
				sample_rate = 48000,
				valid = true,
				capture_valid = true,
			}
		}
	}
	return true
}

test_telemetry_drain :: proc(
	data: rawptr,
	sink: clap.Carnival_Capture_Sink,
	max_records: u32,
) -> u32 {
	instance := cast(^Test_Data)data
	if sink.push == nil {
		return 0
	}
	limit := instance.capture_count
	if max_records != 0 {
		limit = min(limit, max_records)
	}
	delivered: u32 = 0
	for delivered < limit {
		if !sink.push(sink.ctx, &instance.capture_records[instance.capture_read + delivered]) {
			break
		}
		delivered += 1
	}
	instance.capture_read += delivered
	instance.capture_count -= delivered
	return delivered
}

test_telemetry_dropped :: proc(data: rawptr) -> u64 {
	return (cast(^Test_Data)data).capture_dropped
}

test_telemetry_valid :: proc(data: rawptr) -> bool {
	return (cast(^Test_Data)data).capture_valid
}

test_telemetry_schema_version :: proc(data: rawptr) -> u32 {
	_ = data
	return clap.CARNIVAL_MEASUREMENT_SCHEMA_VERSION
}

test_telemetry: Telemetry_Ops = {
	set_enabled = test_telemetry_set_enabled,
	drain = test_telemetry_drain,
	dropped = test_telemetry_dropped,
	valid = test_telemetry_valid,
	schema_version = test_telemetry_schema_version,
}

test_params: [2]Param_Descriptor = {
	{
		id = 501,
		name = "Gain",
		module = "Test",
		flags = clap.CLAP_PARAM_IS_AUTOMATABLE,
		min = 0,
		max = 1,
		default = 0.5,
		format = .Decimal,
	},
	{
		id = 502,
		name = "Mode",
		module = "Test",
		flags = clap.CLAP_PARAM_IS_AUTOMATABLE | clap.CLAP_PARAM_IS_STEPPED,
		min = 0,
		max = 1,
		default = 0,
		format = .Boolean,
		stepped = true,
	},
}

test_descriptor: clap.Plugin_Descriptor = {
	clap_version = clap.CLAP_VERSION,
	id = TEST_DESCRIPTOR_ID,
	name = "Adapter Test",
	vendor = "Carnival Science",
	version = "0.1.0",
	features = nil,
}

test_definition: Definition = {
	descriptor = &test_descriptor,
	backend = &test_backend,
	params = test_params[:],
	input_port_id = 10,
	output_port_id = 20,
	input_port_name = "In",
	output_port_name = "Out",
	state_magic = TEST_STATE_MAGIC,
	state_schema = TEST_SCHEMA,
}

// ---------------------------------------------------------------------------
// Host and stream harness
// ---------------------------------------------------------------------------

Test_Host :: struct {
	extension_queries: int,
	restart_calls:     int,
	callback_calls:    int,
	process_calls:     int,
}

Adapter_Capture :: struct {
	records: [4]clap.Carnival_Measurement_Record,
	count:   int,
}

adapter_capture_push :: proc "c" (ctx: rawptr, record: ^clap.Carnival_Measurement_Record) -> bool {
	collector := cast(^Adapter_Capture)ctx
	if collector == nil || record == nil || collector.count >= len(collector.records) {
		return false
	}
	collector.records[collector.count] = record^
	collector.count += 1
	return true
}

test_host_get_extension :: proc "c" (host: ^clap.Host, extension_id: cstring) -> rawptr {
	_ = extension_id
	state := cast(^Test_Host)host.host_data
	state.extension_queries += 1
	return nil
}

test_host_restart :: proc "c" (host: ^clap.Host) {
	(cast(^Test_Host)host.host_data).restart_calls += 1
}

test_host_process :: proc "c" (host: ^clap.Host) {
	(cast(^Test_Host)host.host_data).process_calls += 1
}

test_host_callback :: proc "c" (host: ^clap.Host) {
	(cast(^Test_Host)host.host_data).callback_calls += 1
}

Test_Events :: struct {
	values:  [8]clap.Event_Param_Value,
	count:   u32,
	out_count: int,
}

test_events_size :: proc "c" (list: ^clap.Input_Events) -> u32 {
	return (cast(^Test_Events)list.ctx).count
}

test_events_get :: proc "c" (list: ^clap.Input_Events, index: u32) -> ^clap.Event_Header {
	state := cast(^Test_Events)list.ctx
	if index >= state.count {
		return nil
	}
	return &state.values[index].header
}

test_events_push :: proc "c" (list: ^clap.Output_Events, event: ^clap.Event_Header) -> bool {
	state := cast(^Test_Events)list.ctx
	if event != nil {
		state.out_count += 1
	}
	return true
}

Buffers :: struct {
	input:    [2][512]f32,
	output:   [2][512]f32,
	input_ptrs:  [2]^f32,
	output_ptrs: [2]^f32,
	audio_input:  clap.Audio_Buffer,
	audio_output: clap.Audio_Buffer,
	inputs:       [1]clap.Audio_Buffer,
	outputs:      [1]clap.Audio_Buffer,
}

prepare_buffers :: proc(buffers: ^Buffers) {
	buffers.input_ptrs = {&buffers.input[0][0], &buffers.input[1][0]}
	buffers.output_ptrs = {&buffers.output[0][0], &buffers.output[1][0]}
	buffers.audio_input = clap.Audio_Buffer{
		data32 = cast([^]^f32)&buffers.input_ptrs[0],
		channel_count = 2,
	}
	buffers.audio_output = clap.Audio_Buffer{
		data32 = cast([^]^f32)&buffers.output_ptrs[0],
		channel_count = 2,
	}
	buffers.inputs[0] = buffers.audio_input
	buffers.outputs[0] = buffers.audio_output
}

Harness :: struct {
	host:    clap.Host,
	state:   Test_Host,
	events:  Test_Events,
	in_events:  clap.Input_Events,
	out_events: clap.Output_Events,
	buffers: Buffers,
	process: clap.Process,
}

prepare_harness :: proc(harness: ^Harness) {
	harness.state = {}
	harness.host = clap.Host{
		clap_version = clap.CLAP_VERSION,
		host_data = &harness.state,
		name = "carnival-audio test host",
		vendor = "Carnival Science",
		version = "0.1.0",
		get_extension = test_host_get_extension,
		request_restart = test_host_restart,
		request_process = test_host_process,
		request_callback = test_host_callback,
	}
	harness.events = {}
	harness.in_events = clap.Input_Events{
		ctx = &harness.events,
		size = test_events_size,
		get = test_events_get,
	}
	harness.out_events = clap.Output_Events{
		ctx = &harness.events,
		try_push = test_events_push,
	}
	prepare_buffers(&harness.buffers)
}

make_process :: proc(harness: ^Harness, frames: u32, events: bool) -> clap.Process {
	process := clap.Process{
		steady_time = 0,
		frames_count = frames,
		audio_inputs = &harness.buffers.inputs[0],
		audio_outputs = &harness.buffers.outputs[0],
		audio_inputs_count = 1,
		audio_outputs_count = 1,
	}
	if events {
		process.in_events = &harness.in_events
		process.out_events = &harness.out_events
	}
	return process
}

instantiate :: proc(t: ^testing.T) -> (^clap.Plugin, ^Harness) {
	register_definition(&test_definition)
	if !entry_init("adapter-test.clap") {
		testing.fail_now(t, "entry_init failed")
	}
	factory := cast(^clap.Plugin_Factory)entry_get_factory(cstring(clap.CLAP_PLUGIN_FACTORY_ID))
	if factory == nil {
		testing.fail_now(t, "no factory")
	}
	testing.expect_value(t, factory.get_plugin_count(factory), u32(1))
	harness := new(Harness)
	prepare_harness(harness)
	plugin := factory.create_plugin(factory, &harness.host, cstring(TEST_DESCRIPTOR_ID))
	if plugin == nil {
		testing.fail_now(t, "create_plugin failed")
	}
	return plugin, harness
}

destroy_instance :: proc(plugin: ^clap.Plugin, harness: ^Harness) {
	plugin.destroy(plugin)
	free(harness)
	entry_deinit()
}

set_param :: proc(plugin: ^clap.Plugin, id: u32, value: f64) -> bool {
	params := cast(^clap.Plugin_Params)plugin.get_extension(plugin, cstring(clap.CLAP_EXT_PARAMS))
	if params == nil || params.flush == nil {
		return false
	}
	state := Test_Events{count = 1}
	state.values[0] = clap.Event_Param_Value{
		header = clap.Event_Header{
			size = u32(size_of(clap.Event_Param_Value)),
			space_id = clap.CLAP_CORE_EVENT_SPACE_ID,
			type = u16(clap.Event_Type.Param_Value),
		},
		param_id = id,
		note_id = -1,
		port_index = -1,
		channel = -1,
		key = -1,
		value = value,
	}
	input := clap.Input_Events{ctx = &state, size = test_events_size, get = test_events_get}
	output := clap.Output_Events{ctx = &state, try_push = test_events_push}
	params.flush(plugin, &input, &output)
	return true
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@(test)
test_draft_telemetry_extension_forwarding :: proc(t: ^testing.T) {
	plugin, harness := instantiate(t)
	defer destroy_instance(plugin, harness)
	testing.expect(t, plugin.init(plugin), "init")

	extension := cast(^clap.Carnival_Telemetry_Capture)plugin.get_extension(
		plugin, cstring(clap.CARNIVAL_EXT_TELEMETRY_CAPTURE_DRAFT))
	testing.expect(t, extension != nil, "draft telemetry extension exposed")
	if extension == nil {
		return
	}
	testing.expect_value(t, extension.schema_version(plugin), clap.CARNIVAL_MEASUREMENT_SCHEMA_VERSION)
	testing.expect(t, extension.valid(plugin), "capture valid before enable")
	testing.expect_value(t, extension.dropped(plugin), u64(0))
	testing.expect(t, extension.set_enabled(plugin, true), "enable forwarded")
	testing.expect(t, (cast(^Test_Data)instance_of(plugin).data).capture_enabled,
		"backend observed enable")

	collector: Adapter_Capture
	sink := clap.Carnival_Capture_Sink{ctx = &collector, push = adapter_capture_push}
	testing.expect_value(t, extension.drain(plugin, sink, 1), u32(1))
	testing.expect_value(t, collector.count, 1)
	testing.expect_value(t, collector.records[0].generation, u64(1))
	testing.expect_value(t, collector.records[0].schema_version, clap.CARNIVAL_MEASUREMENT_SCHEMA_VERSION)
	// max_records == 0 drains the remainder.
	testing.expect_value(t, extension.drain(plugin, sink, 0), u32(1))
	testing.expect_value(t, collector.count, 2)
	testing.expect_value(t, collector.records[1].generation, u64(2))
	testing.expect_value(t, extension.drain(plugin, sink, 0), u32(0))

	// Forced backend loss is visible through the adapter without touching audio.
	data := cast(^Test_Data)instance_of(plugin).data
	data.capture_dropped = 3
	data.capture_valid = false
	testing.expect_value(t, extension.dropped(plugin), u64(3))
	testing.expect(t, !extension.valid(plugin), "capture invalid forwarded")

	testing.expect(t, extension.set_enabled(plugin, false), "disable forwarded")
	testing.expect(t, !(cast(^Test_Data)instance_of(plugin).data).capture_enabled, "backend observed disable")
	testing.expect(t, extension.valid(plugin), "disable resets capture validity")
	testing.expect_value(t, extension.dropped(plugin), u64(0))
}

@(test)
test_lifecycle_and_thread_state_rules :: proc(t: ^testing.T) {
	plugin, harness := instantiate(t)
	defer destroy_instance(plugin, harness)

	testing.expect(t, plugin.init(plugin), "init")
	testing.expect(t, plugin.init(plugin) == false, "double init rejected")
	testing.expect(t, plugin.activate(plugin, 48000, 1, 512), "activate")
	testing.expect(t, plugin.activate(plugin, 48000, 1, 512) == false, "double activate rejected")

	buffers := &harness.buffers
	for frame in 0 ..< 64 {
		buffers.input[0][frame] = f32(frame) * 0.01
		buffers.input[1][frame] = -f32(frame) * 0.02
	}

	// A process call before start is a host contract violation.
	process := make_process(harness, 64, false)
	testing.expect_value(t, plugin.process(plugin, &process), clap.Process_Status(clap.CLAP_PROCESS_ERROR))

	testing.expect(t, plugin.start_processing(plugin), "start")
	testing.expect(t, plugin.start_processing(plugin) == false, "double start rejected")
	testing.expect_value(t, plugin.process(plugin, &process), clap.Process_Status(clap.CLAP_PROCESS_CONTINUE))
	for frame in 0 ..< 64 {
		testing.expect_value(t, transmute(u32)buffers.output[0][frame],
			transmute(u32)(buffers.input[0][frame] * 0.5))
	}
	plugin.reset(plugin)
	plugin.stop_processing(plugin)
	testing.expect_value(t, plugin.process(plugin, &process), clap.Process_Status(clap.CLAP_PROCESS_ERROR))
	plugin.deactivate(plugin)

	// process while active but stopped is also rejected
	testing.expect(t, plugin.activate(plugin, 44100, 1, 256), "reactivate")
	testing.expect_value(t, plugin.process(plugin, &process), clap.Process_Status(clap.CLAP_PROCESS_ERROR))
	plugin.deactivate(plugin)
}

@(test)
test_two_independent_instances :: proc(t: ^testing.T) {
	plugin_a, harness_a := instantiate(t)
	plugin_b, harness_b := instantiate(t)
	defer destroy_instance(plugin_a, harness_a)
	defer destroy_instance(plugin_b, harness_b)

	testing.expect(t, plugin_a.init(plugin_a) && plugin_b.init(plugin_b), "init both")
	testing.expect(t, plugin_a.activate(plugin_a, 48000, 1, 512), "activate a")
	testing.expect(t, plugin_b.activate(plugin_b, 48000, 1, 512), "activate b")
	testing.expect(t, plugin_a.start_processing(plugin_a) && plugin_b.start_processing(plugin_b), "start both")

	testing.expect(t, set_param(plugin_a, 501, 0.25), "set a")
	testing.expect(t, set_param(plugin_b, 501, 0.75), "set b")

	for instance in 0 ..< 2 {
		harness := instance == 0 ? harness_a : harness_b
		plugin := instance == 0 ? plugin_a : plugin_b
		for frame in 0 ..< 32 {
			harness.buffers.input[0][frame] = 1
			harness.buffers.input[1][frame] = 1
		}
		process := make_process(harness, 32, false)
		testing.expect_value(t, plugin.process(plugin, &process), clap.Process_Status(clap.CLAP_PROCESS_CONTINUE))
	}
	testing.expect_value(t, harness_a.buffers.output[0][0], f32(0.25))
	testing.expect_value(t, harness_b.buffers.output[0][0], f32(0.75))

	params := cast(^clap.Plugin_Params)plugin_a.get_extension(plugin_a, cstring(clap.CLAP_EXT_PARAMS))
	value_a: f64
	testing.expect(t, params.get_value(plugin_a, 501, &value_a), "get a")
	testing.expect_value(t, value_a, f64(0.25))
	params_b := cast(^clap.Plugin_Params)plugin_b.get_extension(plugin_b, cstring(clap.CLAP_EXT_PARAMS))
	value_b: f64
	testing.expect(t, params_b.get_value(plugin_b, 501, &value_b), "get b")
	testing.expect_value(t, value_b, f64(0.75))
}

@(test)
test_variable_block_sizes_and_in_place :: proc(t: ^testing.T) {
	plugin, harness := instantiate(t)
	defer destroy_instance(plugin, harness)
	testing.expect(t, plugin.init(plugin), "init")
	testing.expect(t, plugin.activate(plugin, 96000, 1, 512), "activate")
	testing.expect(t, plugin.start_processing(plugin), "start")
	buffers := &harness.buffers
	testing.expect(t, set_param(plugin, 501, 1.0), "unity gain")

	sizes := [?]u32{1, 17, 64, 128, 512, 3}
	for frames in sizes {
		for channel in 0 ..< 2 {
			for frame in 0 ..< int(frames) {
				buffers.input[channel][frame] = f32(frame + channel * 1000) * 1e-3
			}
		}
		process := make_process(harness, frames, false)
		testing.expect_value(t, plugin.process(plugin, &process), clap.Process_Status(clap.CLAP_PROCESS_CONTINUE))
		for channel in 0 ..< 2 {
			for frame in 0 ..< int(frames) {
				testing.expect_value(t, transmute(u32)buffers.output[channel][frame],
					transmute(u32)buffers.input[channel][frame])
			}
		}
	}

	// In-place: host points output at input.
	buffers.output_ptrs = buffers.input_ptrs
	buffers.outputs[0].data32 = cast([^]^f32)&buffers.output_ptrs[0]
	for frame in 0 ..< 128 {
		buffers.input[0][frame] = f32(frame) * 1e-3
		buffers.input[1][frame] = -f32(frame) * 1e-3
	}
	process := make_process(harness, 128, false)
	testing.expect_value(t, plugin.process(plugin, &process), clap.Process_Status(clap.CLAP_PROCESS_CONTINUE))
	for frame in 0 ..< 128 {
		testing.expect_value(t, transmute(u32)buffers.input[0][frame], transmute(u32)(f32(frame) * 1e-3))
	}
}

@(test)
test_unsupported_audio_configurations_are_rejected :: proc(t: ^testing.T) {
	plugin, harness := instantiate(t)
	defer destroy_instance(plugin, harness)
	testing.expect(t, plugin.init(plugin), "init")
	testing.expect(t, plugin.activate(plugin, 48000, 1, 128), "activate")
	testing.expect(t, plugin.start_processing(plugin), "start")

	process := make_process(harness, 64, false)
	process.audio_inputs_count = 0
	testing.expect_value(t, plugin.process(plugin, &process), clap.Process_Status(clap.CLAP_PROCESS_ERROR))

	process = make_process(harness, 64, false)
	harness.buffers.inputs[0].channel_count = 1
	testing.expect_value(t, plugin.process(plugin, &process), clap.Process_Status(clap.CLAP_PROCESS_ERROR))

	process = make_process(harness, 129, false)
	testing.expect_value(t, plugin.process(plugin, &process), clap.Process_Status(clap.CLAP_PROCESS_ERROR))
}

@(test)
test_audio_ports_and_parameters :: proc(t: ^testing.T) {
	plugin, harness := instantiate(t)
	defer destroy_instance(plugin, harness)
	testing.expect(t, plugin.init(plugin), "init")

	ports := cast(^clap.Plugin_Audio_Ports)plugin.get_extension(plugin, cstring(clap.CLAP_EXT_AUDIO_PORTS))
	testing.expect(t, ports != nil, "audio-ports extension")
	if ports != nil {
		testing.expect_value(t, ports.count(plugin, true), u32(1))
		testing.expect_value(t, ports.count(plugin, false), u32(1))
		info_in: clap.Audio_Port_Info
		info_out: clap.Audio_Port_Info
		testing.expect(t, ports.get(plugin, 0, true, &info_in), "input port info")
		testing.expect(t, ports.get(plugin, 0, false, &info_out), "output port info")
		testing.expect_value(t, info_in.channel_count, u32(2))
		testing.expect_value(t, info_out.channel_count, u32(2))
		testing.expect_value(t, info_in.in_place_pair, u32(20))
		testing.expect_value(t, info_out.in_place_pair, u32(10))
		testing.expect_value(t, string(cstring(&info_in.name[0])), "In")
		testing.expect_value(t, string(info_in.port_type), "stereo")
	}

	params := cast(^clap.Plugin_Params)plugin.get_extension(plugin, cstring(clap.CLAP_EXT_PARAMS))
	testing.expect(t, params != nil, "params extension")
	testing.expect_value(t, params.count(plugin), u32(2))
	info: clap.Param_Info
	testing.expect(t, params.get_info(plugin, 0, &info), "param info")
	testing.expect_value(t, info.id, u32(501))
	testing.expect_value(t, string(cstring(&info.name[0])), "Gain")
	testing.expect_value(t, info.min_value, f64(0))
	testing.expect_value(t, info.max_value, f64(1))
	testing.expect_value(t, info.default_value, f64(0.5))

	value: f64
	testing.expect(t, params.get_value(plugin, 501, &value), "default")
	testing.expect_value(t, value, f64(0.5))
	testing.expect(t, params.get_value(plugin, 999, &value) == false, "unknown id rejected")

	buffer: [64]u8
	testing.expect(t, params.value_to_text(plugin, 502, 1, &buffer[0], u32(len(buffer))), "bool text")
	testing.expect_value(t, string(cstring(&buffer[0])), "On")
	parsed: f64
	testing.expect(t, params.text_to_value(plugin, 502, cstring("off"), &parsed), "bool parse")
	testing.expect_value(t, parsed, f64(0))
	testing.expect(t, params.text_to_value(plugin, 502, cstring("banana"), &parsed) == false, "bad text rejected")

	testing.expect(t, params.value_to_text(plugin, 501, 0.1234, &buffer[0], u32(len(buffer))), "decimal text")
	testing.expect(t, params.text_to_value(plugin, 501, cstring("0.25"), &parsed), "decimal parse")
	testing.expect_value(t, parsed, f64(0.25))
}

// In-memory state stream.
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

@(test)
test_state_round_trip_and_empty_state :: proc(t: ^testing.T) {
	plugin, harness := instantiate(t)
	defer destroy_instance(plugin, harness)
	testing.expect(t, plugin.init(plugin), "init")

	params := cast(^clap.Plugin_Params)plugin.get_extension(plugin, cstring(clap.CLAP_EXT_PARAMS))
	state := cast(^clap.Plugin_State)plugin.get_extension(plugin, cstring(clap.CLAP_EXT_STATE))
	testing.expect(t, params != nil && state != nil, "extensions")
	testing.expect(t, set_param(plugin, 501, 0.25), "set gain")

	stream := Mem_Stream{}
	ostream := clap.OStream{ctx = &stream, write = mem_write}
	testing.expect(t, state.save(plugin, &ostream), "save")
	testing.expect_value(t, stream.size, 8 + 4 + 4 + 2 * 12)

	testing.expect(t, set_param(plugin, 501, 0.9), "change gain")
	istream := clap.IStream{ctx = &stream, read = mem_read}
	testing.expect(t, state.load(plugin, &istream), "load")
	value: f64
	testing.expect(t, params.get_value(plugin, 501, &value), "read restored")
	testing.expect_value(t, value, f64(0.25))

	empty := Mem_Stream{}
	empty_input := clap.IStream{ctx = &empty, read = mem_read}
	testing.expect(t, state.load(plugin, &empty_input) == false, "empty state rejected")
}

@(test)
test_state_rejects_bad_magic_and_truncation :: proc(t: ^testing.T) {
	plugin, harness := instantiate(t)
	defer destroy_instance(plugin, harness)
	testing.expect(t, plugin.init(plugin), "init")
	state := cast(^clap.Plugin_State)plugin.get_extension(plugin, cstring(clap.CLAP_EXT_STATE))

	bad := Mem_Stream{size = 16}
	copy(bad.data[:8], "NOTMAGIC")
	istream := clap.IStream{ctx = &bad, read = mem_read}
	testing.expect(t, state.load(plugin, &istream) == false, "bad magic rejected")

	truncated := Mem_Stream{}
	ostream := clap.OStream{ctx = &truncated, write = mem_write}
	testing.expect(t, state.save(plugin, &ostream), "save")
	truncated.size -= 3
	truncated.read = 0
	istream = clap.IStream{ctx = &truncated, read = mem_read}
	testing.expect(t, state.load(plugin, &istream) == false, "truncated state rejected")
}

// Processing-state blob hooks used by the schema-4 extension test.
Blob_Probe :: struct {
	seen: [4]u8,
}

blob_load_calls: int

blob_size :: proc(data: rawptr) -> u32 {
	_ = data
	return 4
}

blob_save :: proc(data: rawptr, stream: ^clap.OStream) -> bool {
	_ = data
	bytes := [4]u8{0xDE, 0xAD, 0xBE, 0xEF}
	return stream.write(stream, &bytes[0], u64(len(bytes))) == i64(len(bytes))
}

blob_load :: proc(data: rawptr, bytes: []u8) -> bool {
	_ = data
	blob_load_calls += 1
	return len(bytes) == 4 && bytes[0] == 0xDE && bytes[3] == 0xEF
}

@(test)
test_state_schema4_processing_blob_round_trip :: proc(t: ^testing.T) {
	definition := new(Definition)
	defer free(definition)
	definition^ = test_definition
	definition.state_schema = 4
	definition.state_blob_size = blob_size
	definition.state_blob_save = blob_save
	definition.state_blob_load = blob_load
	register_definition(definition)
	defer entry_deinit()
	testing.expect(t, entry_init("adapter-test.clap"), "entry_init")
	factory := cast(^clap.Plugin_Factory)entry_get_factory(cstring(clap.CLAP_PLUGIN_FACTORY_ID))
	testing.expect(t, factory != nil, "factory")
	harness := new(Harness)
	defer free(harness)
	prepare_harness(harness)
	plugin := factory.create_plugin(factory, &harness.host, cstring(TEST_DESCRIPTOR_ID))
	testing.expect(t, plugin != nil, "create")
	defer plugin.destroy(plugin)
	testing.expect(t, plugin.init(plugin), "init")

	state := cast(^clap.Plugin_State)plugin.get_extension(plugin, cstring(clap.CLAP_EXT_STATE))
	params := cast(^clap.Plugin_Params)plugin.get_extension(plugin, cstring(clap.CLAP_EXT_PARAMS))
	testing.expect(t, state != nil && params != nil, "extensions")
	testing.expect(t, set_param(plugin, 501, 0.75), "set gain")

	stream := Mem_Stream{}
	ostream := clap.OStream{ctx = &stream, write = mem_write}
	testing.expect(t, state.save(plugin, &ostream), "save")
	// header 16 + two params 24 + blob length 4 + blob 4
	testing.expect_value(t, stream.size, 48)

	testing.expect(t, set_param(plugin, 501, 0.1), "change gain")
	blob_load_calls = 0
	istream := clap.IStream{ctx = &stream, read = mem_read}
	testing.expect(t, state.load(plugin, &istream), "load")
	testing.expect_value(t, blob_load_calls, 1)
	value: f64
	testing.expect(t, params.get_value(plugin, 501, &value), "read restored")
	testing.expect_value(t, value, f64(0.75))
}

@(test)
test_state_schema4_rejects_incomplete_blob_hooks :: proc(t: ^testing.T) {
	definition := new(Definition)
	defer free(definition)
	definition^ = test_definition
	definition.state_schema = 4
	definition.state_blob_size = blob_size
	register_definition(definition)
	defer entry_deinit()
	testing.expect(t, entry_init("adapter-test.clap"), "entry_init")
	factory := cast(^clap.Plugin_Factory)entry_get_factory(cstring(clap.CLAP_PLUGIN_FACTORY_ID))
	testing.expect(t, factory != nil, "factory")
	harness := new(Harness)
	defer free(harness)
	prepare_harness(harness)
	plugin := factory.create_plugin(factory, &harness.host, cstring(TEST_DESCRIPTOR_ID))
	testing.expect(t, plugin == nil, "partial blob hooks are rejected")
}

// Counting allocator used to prove the process path performs no allocation
// through context.allocator/context.temp_allocator.
Alloc_Probe :: struct {
	backing: mem.Allocator,
	allocs:  int,
	frees:   int,
	temp_calls: int,
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
test_process_makes_no_context_allocations :: proc(t: ^testing.T) {
	plugin, harness := instantiate(t)
	defer destroy_instance(plugin, harness)
	testing.expect(t, plugin.init(plugin), "init")
	testing.expect(t, plugin.activate(plugin, 48000, 1, 512), "activate")
	testing.expect(t, plugin.start_processing(plugin), "start")

	probe := Alloc_Probe{backing = context.allocator}
	allocator := mem.Allocator{procedure = probe_proc, data = rawptr(&probe)}
	set_process_allocator(allocator)
	defer set_process_allocator({})

	process := make_process(harness, 512, true)
	for iteration in 0 ..< 32 {
		process.steady_time = i64(iteration * 512)
		testing.expect_value(t, plugin.process(plugin, &process), clap.Process_Status(clap.CLAP_PROCESS_CONTINUE))
	}
	testing.expect_value(t, probe.allocs, 0)
	testing.expect_value(t, harness.state.restart_calls, 0)

	// Sanity: the same allocator does observe an allocation outside process.
	scratch := make([]u8, 16, allocator)
	delete(scratch, allocator)
	testing.expect_value(t, probe.allocs, 1)
}

@(test)
test_automation_events_reach_backend :: proc(t: ^testing.T) {
	plugin, harness := instantiate(t)
	defer destroy_instance(plugin, harness)
	testing.expect(t, plugin.init(plugin), "init")
	testing.expect(t, plugin.activate(plugin, 48000, 1, 64), "activate")
	testing.expect(t, plugin.start_processing(plugin), "start")

	harness.events = Test_Events{count = 1}
	harness.events.values[0] = clap.Event_Param_Value{
		header = clap.Event_Header{
			size = u32(size_of(clap.Event_Param_Value)),
			time = 0,
			space_id = clap.CLAP_CORE_EVENT_SPACE_ID,
			type = u16(clap.Event_Type.Param_Value),
		},
		param_id = 501,
		note_id = -1,
		port_index = -1,
		channel = -1,
		key = -1,
		value = 0.125,
	}
	for frame in 0 ..< 32 {
		harness.buffers.input[0][frame] = 1
	}
	process := make_process(harness, 32, true)
	testing.expect_value(t, plugin.process(plugin, &process), clap.Process_Status(clap.CLAP_PROCESS_CONTINUE))
	testing.expect_value(t, harness.buffers.output[0][0], f32(0.125))

	// Malformed event: ignored, passthrough continues.
	harness.events.values[0].header.type = u16(clap.Event_Type.Midi)
	testing.expect_value(t, plugin.process(plugin, &process), clap.Process_Status(clap.CLAP_PROCESS_CONTINUE))
}






