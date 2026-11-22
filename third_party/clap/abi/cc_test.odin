// Independent CLAP calling-convention check.
//
// Leg (b): tools/abi/cc_probe.c is a miniature CLAP entry/factory/plugin
// compiled by the platform C compiler against the official headers and exported
// from a shared library. This test loads it and drives it through the Odin
// declarations:
//
//   Odin -> C: entry.init, entry.get_factory, factory.create_plugin,
//              plugin.init/activate/start/process/stop/deactivate/destroy,
//              plugin.get_extension (audio-ports vtable).
//   C -> Odin: host.get_extension, host.request_restart,
//              input_events.size/get, output_events.try_push.
//
// It proves pointer-return, proc-pointer vtables, and by-value struct passing
// for the concrete shapes used by this milestone on the host OS. It is not a
// proof for every CLAP struct or for other architectures.
package clap

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
PROBE_MARKER :: rawptr(uintptr(0x5A5A_5A5A_5A5A_5A5A))

@(private = "file")
Host_State :: struct {
	marker_queries: int,
	restart_calls:  int,
	process_calls:  int,
	callback_calls: int,
}

@(private = "file")
host_get_extension :: proc "c" (host: ^Host, extension_id: cstring) -> rawptr {
	state := cast(^Host_State)host.host_data
	if string(extension_id) == "probe.marker" {
		state.marker_queries += 1
		return PROBE_MARKER
	}
	return nil
}

@(private = "file")
host_request_restart :: proc "c" (host: ^Host) {
	state := cast(^Host_State)host.host_data
	state.restart_calls += 1
}

@(private = "file")
host_request_process :: proc "c" (host: ^Host) {
	state := cast(^Host_State)host.host_data
	state.process_calls += 1
}

@(private = "file")
host_request_callback :: proc "c" (host: ^Host) {
	state := cast(^Host_State)host.host_data
	state.callback_calls += 1
}

@(private = "file")
Event_State :: struct {
	event_count:    u32,
	event:          Event_Param_Value,
	out_count:      int,
	out_event_type: u16,
	out_param_id:   u32,
}

@(private = "file")
input_size :: proc "c" (list: ^Input_Events) -> u32 {
	state := cast(^Event_State)list.ctx
	return state.event_count
}

@(private = "file")
input_get :: proc "c" (list: ^Input_Events, index: u32) -> ^Event_Header {
	state := cast(^Event_State)list.ctx
	if index != 0 || state.event_count == 0 {
		return nil
	}
	return &state.event.header
}

@(private = "file")
output_try_push :: proc "c" (list: ^Output_Events, event: ^Event_Header) -> bool {
	state := cast(^Event_State)list.ctx
	if event == nil {
		return false
	}
	state.out_count += 1
	state.out_event_type = event.type
	if event.type == u16(Event_Type.Param_Gesture_Begin) && event.size >= size_of(Event_Param_Gesture) {
		gesture := cast(^Event_Param_Gesture)event
		state.out_param_id = gesture.param_id
	}
	return true
}

@(private = "file")
Entry_Accessor :: #type proc "c" () -> ^Entry
@(private = "file")
Int_Accessor :: #type proc "c" () -> i32
@(private = "file")
Double_Accessor :: #type proc "c" () -> f64
@(private = "file")
Float_Accessor :: #type proc "c" () -> f32
@(private = "file")
U32_Accessor :: #type proc "c" () -> u32
@(private = "file")
Seed_Accessor :: #type proc "c" (count: u32) -> i32

@(private = "file")
Capture_Collect :: struct {
	records: [8]Carnival_Measurement_Record,
	count:   int,
}

@(private = "file")
capture_push :: proc "c" (ctx: rawptr, record: ^Carnival_Measurement_Record) -> bool {
	state := cast(^Capture_Collect)ctx
	if state == nil || record == nil || state.count >= len(state.records) {
		return false
	}
	state.records[state.count] = record^
	state.count += 1
	return true
}

@(test)
test_c_calling_convention_through_clap_vtables :: proc(t: ^testing.T) {
	path := os.get_env("PULSE_CLAP_CC_PROBE", context.allocator)
	defer delete(path, context.allocator)
	if path == "" {
		testing.fail_now(t, "PULSE_CLAP_CC_PROBE is unset; run tools/abi/build.ps1 or tools/abi/build.sh first (tools/test.* does this)")
	}
	library, loaded := load_library(path)
	if !loaded {
		testing.fail_now(t, fmt.tprintf("cannot load C calling-convention probe %q", path))
	}
	defer close_library(library)

	entry_symbol := library_symbol(library, "probe_entry")
	if entry_symbol == nil {
		testing.fail_now(t, "probe_entry symbol missing from C probe library")
	}
	entry := (cast(Entry_Accessor)entry_symbol)()
	if entry == nil {
		testing.fail_now(t, "C probe returned nil entry")
	}
	testing.expect_value(t, entry.clap_version, CLAP_VERSION)
	testing.expect(t, version_is_compatible(entry.clap_version), "C entry version compatible")
	testing.expect(t, entry.init != nil && entry.deinit != nil && entry.get_factory != nil, "entry vtable populated")

	testing.expect(t, entry.init(strings.clone_to_cstring(path, context.temp_allocator)), "C entry.init")
	factory := cast(^Plugin_Factory)entry.get_factory(cstring(CLAP_PLUGIN_FACTORY_ID))
	testing.expect(t, factory != nil, "C get_factory(clap.plugin-factory)")
	if factory == nil {
		entry.deinit()
		testing.fail_now(t, "no factory returned; cannot continue")
	}
	testing.expect_value(t, factory.get_plugin_count(factory), u32(1))
	descriptor := factory.get_plugin_descriptor(factory, 0)
	testing.expect(t, descriptor != nil, "C factory descriptor")
	if descriptor == nil {
		entry.deinit()
		testing.fail_now(t, "no descriptor returned; cannot continue")
	}
	testing.expect_value(t, string(descriptor.id), "com.carnival-science.probe")
	testing.expect_value(t, string(descriptor.name), "CLAP C Calling Probe")
	testing.expect_value(t, descriptor.clap_version, CLAP_VERSION)
	testing.expect(t, factory.get_plugin_descriptor(factory, 1) == nil, "descriptor index bound")

	host_state := Host_State{}
	host := Host{
		clap_version = CLAP_VERSION,
		host_data = &host_state,
		name = "carnival-audio ABI test host",
		vendor = "Carnival Science",
		url = "https://carnival.science/",
		version = "0.1.0",
		get_extension = host_get_extension,
		request_restart = host_request_restart,
		request_process = host_request_process,
		request_callback = host_request_callback,
	}

	plugin := factory.create_plugin(factory, &host, cstring("com.carnival-science.probe"))
	testing.expect(t, plugin != nil, "C factory.create_plugin")
	if plugin == nil {
		entry.deinit()
		testing.fail_now(t, "no plugin returned; cannot continue")
	}
	defer if plugin != nil {
		plugin.destroy(plugin)
	}
	testing.expect(t, plugin.desc == descriptor, "plugin descriptor identity")
	testing.expect(t, plugin.init(plugin), "C plugin.init")
	testing.expect_value(t, host_state.marker_queries, 1)
	testing.expect(t, plugin.activate(plugin, 48000, 1, 512), "C plugin.activate")
	testing.expect(t, plugin.start_processing(plugin), "C plugin.start_processing")

	// Audio buffers: two channels, 64 frames, separate in/out storage first.
	FRAMES :: 64
	CHANNELS :: 2
	input := [CHANNELS][FRAMES]f32{}
	output := [CHANNELS][FRAMES]f32{}
	for channel in 0 ..< CHANNELS {
		for frame in 0 ..< FRAMES {
			input[channel][frame] = f32(frame) * 0.01 + f32(channel) * 0.5
		}
	}
	input_ptrs := [CHANNELS]^f32{&input[0][0], &input[1][0]}
	output_ptrs := [CHANNELS]^f32{&output[0][0], &output[1][0]}
	input_buffer := Audio_Buffer{
		data32 = cast([^]^f32)&input_ptrs[0],
		channel_count = CHANNELS,
	}
	output_buffer := Audio_Buffer{
		data32 = cast([^]^f32)&output_ptrs[0],
		channel_count = CHANNELS,
	}
	audio_inputs := [1]Audio_Buffer{input_buffer}
	audio_outputs := [1]Audio_Buffer{output_buffer}

	events := Event_State{event_count = 1}
	events.event = Event_Param_Value{
		header = Event_Header{
			size = u32(size_of(Event_Param_Value)),
			time = 0,
			space_id = CLAP_CORE_EVENT_SPACE_ID,
			type = u16(Event_Type.Param_Value),
		},
		param_id = 1001,
		note_id = -1,
		port_index = -1,
		channel = -1,
		key = -1,
		value = 0.75,
	}
	in_events := Input_Events{ctx = &events, size = input_size, get = input_get}
	out_events := Output_Events{ctx = &events, try_push = output_try_push}

	process := Process{
		steady_time = 0,
		frames_count = FRAMES,
		audio_inputs = &audio_inputs[0],
		audio_outputs = &audio_outputs[0],
		audio_inputs_count = 1,
		audio_outputs_count = 1,
		in_events = &in_events,
		out_events = &out_events,
	}
	status := plugin.process(plugin, &process)
	testing.expect_value(t, status, Process_Status(CLAP_PROCESS_CONTINUE))
	for channel in 0 ..< CHANNELS {
		for frame in 0 ..< FRAMES {
			testing.expect_value(t, transmute(u32)output[channel][frame], transmute(u32)input[channel][frame])
		}
	}
	testing.expect_value(t, events.out_count, 1)
	testing.expect_value(t, events.out_event_type, u16(Event_Type.Param_Gesture_Begin))
	testing.expect_value(t, events.out_param_id, u32(1001))
	testing.expect_value(t, host_state.restart_calls, 1)

	// In-place: C sees data32[ch] input and output pointing at the same block.
	in_place_ptrs := [CHANNELS]^f32{&output[0][0], &output[1][0]}
	audio_outputs[0].data32 = cast([^]^f32)&in_place_ptrs[0]
	process.steady_time = FRAMES
	status = plugin.process(plugin, &process)
	testing.expect_value(t, status, Process_Status(CLAP_PROCESS_CONTINUE))

	// C-owned extension vtable reached through the Odin declaration.
	ports := cast(^Plugin_Audio_Ports)plugin.get_extension(plugin, cstring(CLAP_EXT_AUDIO_PORTS))
	testing.expect(t, ports != nil, "C plugin.get_extension(clap.audio-ports)")
	if ports != nil {
		testing.expect_value(t, ports.count(plugin, true), u32(1))
		testing.expect_value(t, ports.count(plugin, false), u32(1))
		info: Audio_Port_Info
		testing.expect(t, ports.get(plugin, 0, true, &info), "C audio_ports.get(input)")
		testing.expect_value(t, info.channel_count, u32(2))
		testing.expect_value(t, info.flags, CLAP_AUDIO_PORT_IS_MAIN)
		testing.expect_value(t, info.in_place_pair, u32(20))
		name := string(cstring(&info.name[0]))
		testing.expect_value(t, name, "Probe In")
		testing.expect_value(t, string(info.port_type), CLAP_PORT_STEREO)
	}
	testing.expect(t, plugin.get_extension(plugin, cstring("probe.unknown")) == nil, "unknown extension is nil")

	// Draft Carnival telemetry extension, implemented by the C plugin and
	// driven through the Odin declaration. This is the private-draft ABI proof:
	// plugin-implemented vtable, by-value sink struct, and an Odin callback
	// invoked by C.
	telemetry := cast(^Carnival_Telemetry_Capture)plugin.get_extension(
		plugin, cstring(CARNIVAL_EXT_TELEMETRY_CAPTURE_DRAFT))
	testing.expect(t, telemetry != nil, "C plugin.get_extension(carnival telemetry draft)")
	if telemetry != nil {
		testing.expect_value(t, telemetry.schema_version(plugin), CARNIVAL_MEASUREMENT_SCHEMA_VERSION)
		testing.expect(t, telemetry.valid(plugin), "capture valid before enable")
		testing.expect_value(t, telemetry.dropped(plugin), u64(0))
		testing.expect(t, telemetry.set_enabled(plugin, true), "capture set_enabled through C")

		seed := cast(Seed_Accessor)library_symbol(library, "probe_capture_seed")
		testing.expect_value(t, seed(3), i32(3))

		collect: Capture_Collect
		sink := Carnival_Capture_Sink{ctx = &collect, push = capture_push}
		delivered := telemetry.drain(plugin, sink, 2)
		testing.expect_value(t, delivered, u32(2))
		testing.expect_value(t, collect.count, 2)
		if collect.count == 2 {
			testing.expect_value(t, collect.records[0].schema_version, CARNIVAL_MEASUREMENT_SCHEMA_VERSION)
			testing.expect_value(t, collect.records[0].epoch, u64(7))
			testing.expect_value(t, collect.records[0].generation, u64(1))
			testing.expect_value(t, collect.records[0].start_frame, i64(0))
			testing.expect_value(t, collect.records[0].rms[0], f32(0.25))
			testing.expect(t, collect.records[0].valid && collect.records[0].capture_valid,
				"C record domain flags")
			testing.expect_value(t, collect.records[1].generation, u64(2))
			testing.expect_value(t, collect.records[1].start_frame, i64(1024))
		}
		// max_records == 0 drains the remainder.
		delivered = telemetry.drain(plugin, sink, 0)
		testing.expect_value(t, delivered, u32(1))
		testing.expect_value(t, collect.count, 3)
		testing.expect_value(t, telemetry.drain(plugin, sink, 0), u32(0))

		overflow := cast(Int_Accessor)library_symbol(library, "probe_capture_force_overflow")
		testing.expect_value(t, overflow(), i32(2))
		testing.expect_value(t, telemetry.dropped(plugin), u64(2))
		testing.expect(t, !telemetry.valid(plugin), "capture invalid after forced overflow")

		testing.expect(t, telemetry.set_enabled(plugin, false), "capture set_enabled(false)")
		enabled := (cast(Int_Accessor)library_symbol(library, "probe_capture_enabled"))()
		testing.expect_value(t, enabled, i32(0))
		testing.expect_value(t, telemetry.dropped(plugin), u64(0))
		testing.expect(t, telemetry.valid(plugin), "disable restores capture validity")
	}

	plugin.stop_processing(plugin)
	plugin.deactivate(plugin)
	plugin.destroy(plugin)
	plugin = nil
	entry.deinit()

	// C-observed state proves the directions of every call above.
	marker_ok := (cast(Int_Accessor)library_symbol(library, "probe_marker_ok"))()
	destroyed := (cast(Int_Accessor)library_symbol(library, "probe_destroyed"))()
	process_calls := (cast(Int_Accessor)library_symbol(library, "probe_process_calls"))()
	param_seen := (cast(Int_Accessor)library_symbol(library, "probe_param_seen"))()
	param_value := (cast(Double_Accessor)library_symbol(library, "probe_param_value"))()
	first_input := (cast(Float_Accessor)library_symbol(library, "probe_first_input"))()
	last_frames := (cast(U32_Accessor)library_symbol(library, "probe_last_frames"))()
	restart_calls := (cast(Int_Accessor)library_symbol(library, "probe_host_restart_calls"))()

	testing.expect_value(t, marker_ok, i32(1))
	testing.expect_value(t, destroyed, i32(1))
	testing.expect_value(t, process_calls, i32(2))
	testing.expect_value(t, param_seen, i32(1))
	testing.expect_value(t, param_value, f64(0.75))
	testing.expect_value(t, transmute(u32)first_input, transmute(u32)input[0][0])
	testing.expect_value(t, last_frames, u32(FRAMES))
	testing.expect_value(t, restart_calls, i32(2))
	fmt.printf("CLAP C probe: entry/factory/plugin/host/events/audio-ports vtables agree in both directions\n")
}




