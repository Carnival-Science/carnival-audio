// Independent CLAP ABI layout check.
//
// Leg (a): build tools/abi/abi_probe.c against the vendored official CLAP
// 1.2.10 headers with the platform C compiler, run it to obtain sizeof and
// offsetof for every declaration this repository binds, and compare each value
// with Odin's size_of/offset_of. A mismatch is a declaration bug; the C header
// is the authority. tools/test.ps1 / tools/test.sh build the probe and set
// PULSE_CLAP_ABI_PROBE.
package clap

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
Abi_Case :: struct {
	name:  string,
	value: int,
}

@(test)
test_c_abi_layout_matches_odin :: proc(t: ^testing.T) {
	path := os.get_env("PULSE_CLAP_ABI_PROBE", context.allocator)
	defer delete(path, context.allocator)
	if path == "" {
		testing.fail_now(t, "PULSE_CLAP_ABI_PROBE is unset; run tools/abi/build.ps1 or tools/abi/build.sh first (tools/test.* does this)")
	}
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		testing.fail_now(t, fmt.tprintf("cannot read ABI probe output %q: %v", path, err))
	}
	defer delete(data, context.allocator)

	size_cases := []Abi_Case{
		{"Version", size_of(Version)},
		{"Entry", size_of(Entry)},
		{"Plugin_Descriptor", size_of(Plugin_Descriptor)},
		{"Plugin", size_of(Plugin)},
		{"Host", size_of(Host)},
		{"Audio_Buffer", size_of(Audio_Buffer)},
		{"Process", size_of(Process)},
		{"Event_Header", size_of(Event_Header)},
		{"Event_Param_Value", size_of(Event_Param_Value)},
		{"Event_Param_Mod", size_of(Event_Param_Mod)},
		{"Event_Param_Gesture", size_of(Event_Param_Gesture)},
		{"Event_Transport", size_of(Event_Transport)},
		{"Event_Midi", size_of(Event_Midi)},
		{"Event_Midi_Sysex", size_of(Event_Midi_Sysex)},
		{"Event_Midi2", size_of(Event_Midi2)},
		{"Input_Events", size_of(Input_Events)},
		{"Output_Events", size_of(Output_Events)},
		{"Plugin_Factory", size_of(Plugin_Factory)},
		{"Audio_Port_Info", size_of(Audio_Port_Info)},
		{"Plugin_Audio_Ports", size_of(Plugin_Audio_Ports)},
		{"Param_Info", size_of(Param_Info)},
		{"Plugin_Params", size_of(Plugin_Params)},
		{"IStream", size_of(IStream)},
		{"OStream", size_of(OStream)},
		{"Plugin_State", size_of(Plugin_State)},
		{"Host_State", size_of(Host_State)},
		{"Plugin_Latency", size_of(Plugin_Latency)},
		{"Host_Latency", size_of(Host_Latency)},
		{"Host_Thread_Check", size_of(Host_Thread_Check)},
		{"Plugin_Tail", size_of(Plugin_Tail)},
		{"Host_Audio_Ports", size_of(Host_Audio_Ports)},
		{"Host_Params", size_of(Host_Params)},
		{"Plugin_Render", size_of(Plugin_Render)},
	}
	size_seen := make([]bool, len(size_cases), context.allocator)
	defer delete(size_seen)

	offset_cases := []Abi_Case{
		{"Version.major", int(offset_of(Version, major))},
		{"Version.minor", int(offset_of(Version, minor))},
		{"Version.revision", int(offset_of(Version, revision))},
		{"Entry.clap_version", int(offset_of(Entry, clap_version))},
		{"Entry.init", int(offset_of(Entry, init))},
		{"Entry.deinit", int(offset_of(Entry, deinit))},
		{"Entry.get_factory", int(offset_of(Entry, get_factory))},
		{"Plugin_Descriptor.clap_version", int(offset_of(Plugin_Descriptor, clap_version))},
		{"Plugin_Descriptor.id", int(offset_of(Plugin_Descriptor, id))},
		{"Plugin_Descriptor.name", int(offset_of(Plugin_Descriptor, name))},
		{"Plugin_Descriptor.vendor", int(offset_of(Plugin_Descriptor, vendor))},
		{"Plugin_Descriptor.url", int(offset_of(Plugin_Descriptor, url))},
		{"Plugin_Descriptor.manual_url", int(offset_of(Plugin_Descriptor, manual_url))},
		{"Plugin_Descriptor.support_url", int(offset_of(Plugin_Descriptor, support_url))},
		{"Plugin_Descriptor.version", int(offset_of(Plugin_Descriptor, version))},
		{"Plugin_Descriptor.description", int(offset_of(Plugin_Descriptor, description))},
		{"Plugin_Descriptor.features", int(offset_of(Plugin_Descriptor, features))},
		{"Plugin.desc", int(offset_of(Plugin, desc))},
		{"Plugin.plugin_data", int(offset_of(Plugin, plugin_data))},
		{"Plugin.init", int(offset_of(Plugin, init))},
		{"Plugin.destroy", int(offset_of(Plugin, destroy))},
		{"Plugin.activate", int(offset_of(Plugin, activate))},
		{"Plugin.deactivate", int(offset_of(Plugin, deactivate))},
		{"Plugin.start_processing", int(offset_of(Plugin, start_processing))},
		{"Plugin.stop_processing", int(offset_of(Plugin, stop_processing))},
		{"Plugin.reset", int(offset_of(Plugin, reset))},
		{"Plugin.process", int(offset_of(Plugin, process))},
		{"Plugin.get_extension", int(offset_of(Plugin, get_extension))},
		{"Plugin.on_main_thread", int(offset_of(Plugin, on_main_thread))},
		{"Host.clap_version", int(offset_of(Host, clap_version))},
		{"Host.host_data", int(offset_of(Host, host_data))},
		{"Host.name", int(offset_of(Host, name))},
		{"Host.vendor", int(offset_of(Host, vendor))},
		{"Host.url", int(offset_of(Host, url))},
		{"Host.version", int(offset_of(Host, version))},
		{"Host.get_extension", int(offset_of(Host, get_extension))},
		{"Host.request_restart", int(offset_of(Host, request_restart))},
		{"Host.request_process", int(offset_of(Host, request_process))},
		{"Host.request_callback", int(offset_of(Host, request_callback))},
		{"Audio_Buffer.data32", int(offset_of(Audio_Buffer, data32))},
		{"Audio_Buffer.data64", int(offset_of(Audio_Buffer, data64))},
		{"Audio_Buffer.channel_count", int(offset_of(Audio_Buffer, channel_count))},
		{"Audio_Buffer.latency", int(offset_of(Audio_Buffer, latency))},
		{"Audio_Buffer.constant_mask", int(offset_of(Audio_Buffer, constant_mask))},
		{"Process.steady_time", int(offset_of(Process, steady_time))},
		{"Process.frames_count", int(offset_of(Process, frames_count))},
		{"Process.transport", int(offset_of(Process, transport))},
		{"Process.audio_inputs", int(offset_of(Process, audio_inputs))},
		{"Process.audio_outputs", int(offset_of(Process, audio_outputs))},
		{"Process.audio_inputs_count", int(offset_of(Process, audio_inputs_count))},
		{"Process.audio_outputs_count", int(offset_of(Process, audio_outputs_count))},
		{"Process.in_events", int(offset_of(Process, in_events))},
		{"Process.out_events", int(offset_of(Process, out_events))},
		{"Event_Header.size", int(offset_of(Event_Header, size))},
		{"Event_Header.time", int(offset_of(Event_Header, time))},
		{"Event_Header.space_id", int(offset_of(Event_Header, space_id))},
		{"Event_Header.type", int(offset_of(Event_Header, type))},
		{"Event_Header.flags", int(offset_of(Event_Header, flags))},
		{"Event_Param_Value.header", int(offset_of(Event_Param_Value, header))},
		{"Event_Param_Value.param_id", int(offset_of(Event_Param_Value, param_id))},
		{"Event_Param_Value.cookie", int(offset_of(Event_Param_Value, cookie))},
		{"Event_Param_Value.note_id", int(offset_of(Event_Param_Value, note_id))},
		{"Event_Param_Value.port_index", int(offset_of(Event_Param_Value, port_index))},
		{"Event_Param_Value.channel", int(offset_of(Event_Param_Value, channel))},
		{"Event_Param_Value.key", int(offset_of(Event_Param_Value, key))},
		{"Event_Param_Value.value", int(offset_of(Event_Param_Value, value))},
		{"Event_Param_Mod.amount", int(offset_of(Event_Param_Mod, amount))},
		{"Event_Param_Gesture.param_id", int(offset_of(Event_Param_Gesture, param_id))},
		{"Event_Transport.header", int(offset_of(Event_Transport, header))},
		{"Event_Transport.flags", int(offset_of(Event_Transport, flags))},
		{"Event_Transport.song_pos_beats", int(offset_of(Event_Transport, song_pos_beats))},
		{"Event_Transport.song_pos_seconds", int(offset_of(Event_Transport, song_pos_seconds))},
		{"Event_Transport.tempo", int(offset_of(Event_Transport, tempo))},
		{"Event_Transport.tempo_inc", int(offset_of(Event_Transport, tempo_inc))},
		{"Event_Transport.bar_number", int(offset_of(Event_Transport, bar_number))},
		{"Event_Transport.tsig_num", int(offset_of(Event_Transport, tsig_num))},
		{"Event_Transport.tsig_denom", int(offset_of(Event_Transport, tsig_denom))},
		{"Event_Midi.port_index", int(offset_of(Event_Midi, port_index))},
		{"Event_Midi.data", int(offset_of(Event_Midi, data))},
		{"Event_Midi_Sysex.buffer", int(offset_of(Event_Midi_Sysex, buffer))},
		{"Event_Midi_Sysex.size", int(offset_of(Event_Midi_Sysex, size))},
		{"Event_Midi2.port_index", int(offset_of(Event_Midi2, port_index))},
		{"Event_Midi2.data", int(offset_of(Event_Midi2, data))},
		{"Input_Events.ctx", int(offset_of(Input_Events, ctx))},
		{"Input_Events.size", int(offset_of(Input_Events, size))},
		{"Input_Events.get", int(offset_of(Input_Events, get))},
		{"Output_Events.ctx", int(offset_of(Output_Events, ctx))},
		{"Output_Events.try_push", int(offset_of(Output_Events, try_push))},
		{"Plugin_Factory.get_plugin_count", int(offset_of(Plugin_Factory, get_plugin_count))},
		{"Plugin_Factory.get_plugin_descriptor", int(offset_of(Plugin_Factory, get_plugin_descriptor))},
		{"Plugin_Factory.create_plugin", int(offset_of(Plugin_Factory, create_plugin))},
		{"Audio_Port_Info.id", int(offset_of(Audio_Port_Info, id))},
		{"Audio_Port_Info.name", int(offset_of(Audio_Port_Info, name))},
		{"Audio_Port_Info.flags", int(offset_of(Audio_Port_Info, flags))},
		{"Audio_Port_Info.channel_count", int(offset_of(Audio_Port_Info, channel_count))},
		{"Audio_Port_Info.port_type", int(offset_of(Audio_Port_Info, port_type))},
		{"Audio_Port_Info.in_place_pair", int(offset_of(Audio_Port_Info, in_place_pair))},
		{"Plugin_Audio_Ports.count", int(offset_of(Plugin_Audio_Ports, count))},
		{"Plugin_Audio_Ports.get", int(offset_of(Plugin_Audio_Ports, get))},
		{"Param_Info.id", int(offset_of(Param_Info, id))},
		{"Param_Info.flags", int(offset_of(Param_Info, flags))},
		{"Param_Info.cookie", int(offset_of(Param_Info, cookie))},
		{"Param_Info.name", int(offset_of(Param_Info, name))},
		{"Param_Info.module", int(offset_of(Param_Info, module))},
		{"Param_Info.min_value", int(offset_of(Param_Info, min_value))},
		{"Param_Info.max_value", int(offset_of(Param_Info, max_value))},
		{"Param_Info.default_value", int(offset_of(Param_Info, default_value))},
		{"Plugin_Params.count", int(offset_of(Plugin_Params, count))},
		{"Plugin_Params.get_info", int(offset_of(Plugin_Params, get_info))},
		{"Plugin_Params.get_value", int(offset_of(Plugin_Params, get_value))},
		{"Plugin_Params.value_to_text", int(offset_of(Plugin_Params, value_to_text))},
		{"Plugin_Params.text_to_value", int(offset_of(Plugin_Params, text_to_value))},
		{"Plugin_Params.flush", int(offset_of(Plugin_Params, flush))},
		{"IStream.ctx", int(offset_of(IStream, ctx))},
		{"IStream.read", int(offset_of(IStream, read))},
		{"OStream.ctx", int(offset_of(OStream, ctx))},
		{"OStream.write", int(offset_of(OStream, write))},
		{"Plugin_State.save", int(offset_of(Plugin_State, save))},
		{"Plugin_State.load", int(offset_of(Plugin_State, load))},
		{"Host_State.mark_dirty", int(offset_of(Host_State, mark_dirty))},
		{"Plugin_Latency.get", int(offset_of(Plugin_Latency, get))},
		{"Host_Latency.changed", int(offset_of(Host_Latency, changed))},
		{"Host_Thread_Check.is_main_thread", int(offset_of(Host_Thread_Check, is_main_thread))},
		{"Host_Thread_Check.is_audio_thread", int(offset_of(Host_Thread_Check, is_audio_thread))},
		{"Plugin_Tail.get", int(offset_of(Plugin_Tail, get))},
		{"Host_Audio_Ports.is_rescan_flag_supported", int(offset_of(Host_Audio_Ports, is_rescan_flag_supported))},
		{"Host_Audio_Ports.rescan", int(offset_of(Host_Audio_Ports, rescan))},
		{"Host_Params.rescan", int(offset_of(Host_Params, rescan))},
		{"Host_Params.clear", int(offset_of(Host_Params, clear))},
		{"Host_Params.request_flush", int(offset_of(Host_Params, request_flush))},
		{"Plugin_Render.has_hard_realtime_requirement", int(offset_of(Plugin_Render, has_hard_realtime_requirement))},
		{"Plugin_Render.set", int(offset_of(Plugin_Render, set))},
	}
	offset_seen := make([]bool, len(offset_cases), context.allocator)
	defer delete(offset_seen)

	lines := strings.split_lines(string(data), context.temp_allocator)
	defer free_all(context.temp_allocator)

	version_seen := false
	saw_bool := false
	for line in lines {
		if line == "" {
			continue
		}
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) < 2 {
			testing.expectf(t, false, "malformed ABI probe line: %q", line)
			continue
		}
		switch fields[0] {
		case "version":
			if len(fields) != 4 {
				testing.expectf(t, false, "malformed version line: %q", line)
				continue
			}
			version_seen = true
			testing.expect_value(t, fields[1], fmt.tprint(CLAP_VERSION_MAJOR))
			testing.expect_value(t, fields[2], fmt.tprint(CLAP_VERSION_MINOR))
			testing.expect_value(t, fields[3], fmt.tprint(CLAP_VERSION_REVISION))
		case "bool_size":
			saw_bool = true
			testing.expect_value(t, fields[1], "1")
		case "invalid_id":
			testing.expect_value(t, fields[1], fmt.tprint(CLAP_INVALID_ID))
		case "name_size":
			testing.expect_value(t, fields[1], fmt.tprint(CLAP_NAME_SIZE))
		case "path_size":
			testing.expect_value(t, fields[1], fmt.tprint(CLAP_PATH_SIZE))
		case "size":
			if len(fields) != 3 {
				testing.expectf(t, false, "malformed size line: %q", line)
				continue
			}
			found := false
			for index in 0 ..< len(size_cases) {
				if size_cases[index].name != fields[1] {
					continue
				}
				found = true
				size_seen[index] = true
				testing.expectf(t, fields[2] == fmt.tprint(size_cases[index].value),
					"%s: C sizeof %s, Odin size_of %d", fields[1], fields[2], size_cases[index].value)
			}
			testing.expectf(t, found, "C probe reports unbound size %q", fields[1])
		case "offset":
			if len(fields) != 3 {
				testing.expectf(t, false, "malformed offset line: %q", line)
				continue
			}
			found := false
			for index in 0 ..< len(offset_cases) {
				if offset_cases[index].name != fields[1] {
					continue
				}
				found = true
				offset_seen[index] = true
				testing.expectf(t, fields[2] == fmt.tprint(offset_cases[index].value),
					"%s: C offsetof %s, Odin offset_of %d", fields[1], fields[2], offset_cases[index].value)
			}
			testing.expectf(t, found, "C probe reports unbound offset %q", fields[1])
		}
	}

	missing := 0
	for seen in size_seen {
		if !seen do missing += 1
	}
	for seen in offset_seen {
		if !seen do missing += 1
	}
	testing.expect(t, version_seen, "C probe did not report CLAP version")
	testing.expect(t, saw_bool, "C probe did not report bool size")
	testing.expectf(t, missing == 0, "C probe did not cover %d bound facts", missing)
	fmt.printf("CLAP ABI layout: %d struct sizes and %d field offsets agree with C\n",
		len(size_cases), len(offset_cases))
}



