// CLAP 1.2.10 core ABI declarations.
//
// Source: github.com/free-audio/clap tag 1.2.10, commit
// 195b42a004144fab0b3cf95e9c067187d15365b7 (see ../UPSTREAM.md).
//
// These are *declarations only*. They mirror the official C headers with
// normal C layout and the platform CLAP_ABI (cdecl on Windows, the platform
// default elsewhere); proc fields are therefore declared `proc "c"`.
//
// Every struct here is asserted against sizeof/offsetof output from a C
// translation unit compiled with the vendored headers (see
// tests/abi_layout_test.odin and tools/abi/abi_probe.c). Do not edit a layout
// without rerunning that gate.
package clap

// Version constants from clap/version.h.
CLAP_VERSION_MAJOR :: u32(1)
CLAP_VERSION_MINOR :: u32(2)
CLAP_VERSION_REVISION :: u32(10)

Version :: struct {
	major:    u32,
	minor:    u32,
	revision: u32,
}

CLAP_VERSION :: Version{CLAP_VERSION_MAJOR, CLAP_VERSION_MINOR, CLAP_VERSION_REVISION}

version_is_compatible :: proc(version: Version) -> bool {
	// clap_version_is_compatible(): versions 0.x.y are development builds.
	return version.major >= 1
}

// clap/id.h
CLAP_INVALID_ID :: u32(0xFFFF_FFFF)

// clap/string-sizes.h
CLAP_NAME_SIZE :: 256
CLAP_PATH_SIZE :: 1024

// clap/process.h
CLAP_PROCESS_ERROR :: i32(0)
CLAP_PROCESS_CONTINUE :: i32(1)
CLAP_PROCESS_CONTINUE_IF_NOT_QUIET :: i32(2)
CLAP_PROCESS_TAIL :: i32(3)
CLAP_PROCESS_SLEEP :: i32(4)

Process_Status :: i32

// clap/plugin-features.h
CLAP_PLUGIN_FEATURE_AUDIO_EFFECT :: "audio-effect"
CLAP_PLUGIN_FEATURE_ANALYZER :: "analyzer"
CLAP_PLUGIN_FEATURE_STEREO :: "stereo"
CLAP_PLUGIN_FEATURE_UTILITY :: "utility"

// Extension identifiers used by this adapter/product pair.
CLAP_EXT_AUDIO_PORTS :: "clap.audio-ports"
CLAP_EXT_PARAMS :: "clap.params"
CLAP_EXT_STATE :: "clap.state"
CLAP_EXT_LATENCY :: "clap.latency"
CLAP_EXT_THREAD_CHECK :: "clap.thread-check"
CLAP_EXT_TAIL :: "clap.tail"
CLAP_EXT_RENDER :: "clap.render"

CLAP_PLUGIN_FACTORY_ID :: "clap.plugin-factory"

CLAP_PORT_MONO :: "mono"
CLAP_PORT_STEREO :: "stereo"

// ---------------------------------------------------------------------------
// Entry point (clap/entry.h)
// ---------------------------------------------------------------------------

Entry_Init :: #type proc "c" (plugin_path: cstring) -> bool
Entry_Deinit :: #type proc "c" ()
Entry_Get_Factory :: #type proc "c" (factory_id: cstring) -> rawptr

Entry :: struct {
	clap_version: Version,
	init:         Entry_Init,
	deinit:       Entry_Deinit,
	get_factory:  Entry_Get_Factory,
}

// ---------------------------------------------------------------------------
// Plugin and host (clap/plugin.h, clap/host.h)
// ---------------------------------------------------------------------------

Plugin_Descriptor :: struct {
	clap_version: Version,
	id:           cstring, // mandatory
	name:         cstring, // mandatory
	vendor:       cstring,
	url:          cstring,
	manual_url:   cstring,
	support_url:  cstring,
	version:      cstring,
	description:  cstring,
	features:     [^]cstring, // null-terminated array of pointers
}

Plugin :: struct {
	desc:               ^Plugin_Descriptor,
	plugin_data:        rawptr,
	init:               proc "c" (plugin: ^Plugin) -> bool,
	destroy:            proc "c" (plugin: ^Plugin),
	activate:           proc "c" (plugin: ^Plugin, sample_rate: f64, min_frames_count, max_frames_count: u32) -> bool,
	deactivate:         proc "c" (plugin: ^Plugin),
	start_processing:   proc "c" (plugin: ^Plugin) -> bool,
	stop_processing:    proc "c" (plugin: ^Plugin),
	reset:              proc "c" (plugin: ^Plugin),
	process:            proc "c" (plugin: ^Plugin, process: ^Process) -> Process_Status,
	get_extension:      proc "c" (plugin: ^Plugin, id: cstring) -> rawptr,
	on_main_thread:     proc "c" (plugin: ^Plugin),
}

Host :: struct {
	clap_version:     Version,
	host_data:        rawptr,
	name:             cstring,
	vendor:           cstring,
	url:              cstring,
	version:          cstring,
	get_extension:    proc "c" (host: ^Host, extension_id: cstring) -> rawptr,
	request_restart:  proc "c" (host: ^Host),
	request_process:  proc "c" (host: ^Host),
	request_callback: proc "c" (host: ^Host),
}

// ---------------------------------------------------------------------------
// Processing (clap/process.h, clap/audio-buffer.h, clap/events.h)
// ---------------------------------------------------------------------------

Audio_Buffer :: struct {
	data32:        [^]^f32, // either data32 or data64 is set
	data64:        [^]^f64,
	channel_count: u32,
	latency:       u32,
	constant_mask: u64,
}

Process :: struct {
	steady_time:         i64,
	frames_count:        u32,
	transport:           ^Event_Transport,
	audio_inputs:        [^]Audio_Buffer,
	audio_outputs:       [^]Audio_Buffer,
	audio_inputs_count:  u32,
	audio_outputs_count: u32,
	in_events:           ^Input_Events,
	out_events:          ^Output_Events,
}

Event_Header :: struct {
	size:     u32, // event size including this header
	time:     u32, // sample offset within the buffer
	space_id: u16,
	type:     u16,
	flags:    u32,
}

CLAP_CORE_EVENT_SPACE_ID :: u16(0)

Event_Type :: enum u16 {
	Note_On                 = 0,
	Note_Off                = 1,
	Note_Choke              = 2,
	Note_End                = 3,
	Note_Expression         = 4,
	Param_Value             = 5,
	Param_Mod               = 6,
	Param_Gesture_Begin     = 7,
	Param_Gesture_End       = 8,
	Transport               = 9,
	Midi                    = 10,
	Midi_Sysex              = 11,
	Midi2                   = 12,
}

CLAP_EVENT_IS_LIVE :: u32(1 << 0)
CLAP_EVENT_DONT_RECORD :: u32(1 << 1)

Event_Param_Value :: struct {
	header:     Event_Header,
	param_id:   u32,
	cookie:     rawptr,
	note_id:    i32,
	port_index: i16,
	channel:    i16,
	key:        i16,
	value:      f64,
}

// Event_Param_Mod has the same layout as Event_Param_Value; the trailing
// field is named `amount` in the C header. Declared separately so call sites
// cannot confuse the two meanings.
Event_Param_Mod :: struct {
	header:     Event_Header,
	param_id:   u32,
	cookie:     rawptr,
	note_id:    i32,
	port_index: i16,
	channel:    i16,
	key:        i16,
	amount:     f64,
}

Event_Param_Gesture :: struct {
	header:   Event_Header,
	param_id: u32,
}

// clap/fixedpoint.h
CLAP_BEATTIME_FACTOR :: i64(1) << 31
CLAP_SECTIME_FACTOR :: i64(1) << 31
Beattime :: i64
Sectime :: i64

// clap/events.h transport flags
CLAP_TRANSPORT_HAS_TEMPO :: u32(1 << 0)
CLAP_TRANSPORT_HAS_BEATS_TIMELINE :: u32(1 << 1)
CLAP_TRANSPORT_HAS_SECONDS_TIMELINE :: u32(1 << 2)
CLAP_TRANSPORT_HAS_TIME_SIGNATURE :: u32(1 << 3)
CLAP_TRANSPORT_IS_PLAYING :: u32(1 << 4)
CLAP_TRANSPORT_IS_RECORDING :: u32(1 << 5)
CLAP_TRANSPORT_IS_LOOP_ACTIVE :: u32(1 << 6)
CLAP_TRANSPORT_IS_WITHIN_PRE_ROLL :: u32(1 << 7)

Event_Transport :: struct {
	header:            Event_Header,
	flags:             u32,
	song_pos_beats:    Beattime,
	song_pos_seconds:  Sectime,
	tempo:             f64,
	tempo_inc:         f64,
	loop_start_beats:  Beattime,
	loop_end_beats:    Beattime,
	loop_start_seconds: Sectime,
	loop_end_seconds:  Sectime,
	bar_start:         Beattime,
	bar_number:        i32,
	tsig_num:          u16,
	tsig_denom:        u16,
}

Event_Midi :: struct {
	header:     Event_Header,
	port_index: u16,
	data:       [3]u8,
}

Event_Midi_Sysex :: struct {
	header:     Event_Header,
	port_index: u16,
	buffer:     [^]u8,
	size:       u32,
}

Event_Midi2 :: struct {
	header:     Event_Header,
	port_index: u16,
	data:       [4]u32,
}

Input_Events :: struct {
	ctx:  rawptr,
	size: proc "c" (list: ^Input_Events) -> u32,
	get:  proc "c" (list: ^Input_Events, index: u32) -> ^Event_Header,
}

Output_Events :: struct {
	ctx:      rawptr,
	try_push: proc "c" (list: ^Output_Events, event: ^Event_Header) -> bool,
}

// ---------------------------------------------------------------------------
// Factory (clap/factory/plugin-factory.h)
// ---------------------------------------------------------------------------

Plugin_Factory :: struct {
	get_plugin_count:      proc "c" (factory: ^Plugin_Factory) -> u32,
	get_plugin_descriptor: proc "c" (factory: ^Plugin_Factory, index: u32) -> ^Plugin_Descriptor,
	create_plugin:         proc "c" (factory: ^Plugin_Factory, host: ^Host, plugin_id: cstring) -> ^Plugin,
}
