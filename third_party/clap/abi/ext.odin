// CLAP 1.2.10 extension ABI declarations used by the headless Pulse meter.
//
// Mirrors include/clap/ext/{audio-ports,params,state,latency,thread-check,tail,
// render}.h and include/clap/factory/plugin-factory.h from the vendored
// headers. Layout is validated by the C probe; see clap.odin's header comment.
package clap

// ---------------------------------------------------------------------------
// clap/ext/audio-ports.h
// ---------------------------------------------------------------------------

CLAP_AUDIO_PORT_IS_MAIN :: u32(1 << 0)
CLAP_AUDIO_PORT_SUPPORTS_64BITS :: u32(1 << 1)
CLAP_AUDIO_PORT_PREFERS_64BITS :: u32(1 << 2)
CLAP_AUDIO_PORT_REQUIRES_COMMON_SAMPLE_SIZE :: u32(1 << 3)

Audio_Port_Info :: struct {
	id:             u32,
	name:           [CLAP_NAME_SIZE]u8,
	flags:          u32,
	channel_count:  u32,
	port_type:      cstring,
	in_place_pair:  u32,
}

Plugin_Audio_Ports :: struct {
	count: proc "c" (plugin: ^Plugin, is_input: bool) -> u32,
	get:   proc "c" (plugin: ^Plugin, index: u32, is_input: bool, info: ^Audio_Port_Info) -> bool,
}

CLAP_AUDIO_PORTS_RESCAN_NAMES :: u32(1 << 0)
CLAP_AUDIO_PORTS_RESCAN_FLAGS :: u32(1 << 1)
CLAP_AUDIO_PORTS_RESCAN_CHANNEL_COUNT :: u32(1 << 2)
CLAP_AUDIO_PORTS_RESCAN_PORT_TYPE :: u32(1 << 3)
CLAP_AUDIO_PORTS_RESCAN_IN_PLACE_PAIR :: u32(1 << 4)
CLAP_AUDIO_PORTS_RESCAN_LIST :: u32(1 << 5)

Host_Audio_Ports :: struct {
	is_rescan_flag_supported: proc "c" (host: ^Host, flag: u32) -> bool,
	rescan:                   proc "c" (host: ^Host, flags: u32),
}

// ---------------------------------------------------------------------------
// clap/ext/params.h
// ---------------------------------------------------------------------------

CLAP_PARAM_IS_STEPPED :: u32(1 << 0)
CLAP_PARAM_IS_PERIODIC :: u32(1 << 1)
CLAP_PARAM_IS_HIDDEN :: u32(1 << 2)
CLAP_PARAM_IS_READONLY :: u32(1 << 3)
CLAP_PARAM_IS_BYPASS :: u32(1 << 4)
CLAP_PARAM_IS_AUTOMATABLE :: u32(1 << 5)
CLAP_PARAM_IS_AUTOMATABLE_PER_NOTE_ID :: u32(1 << 6)
CLAP_PARAM_IS_AUTOMATABLE_PER_KEY :: u32(1 << 7)
CLAP_PARAM_IS_AUTOMATABLE_PER_CHANNEL :: u32(1 << 8)
CLAP_PARAM_IS_AUTOMATABLE_PER_PORT :: u32(1 << 9)
CLAP_PARAM_IS_MODULATABLE :: u32(1 << 10)
CLAP_PARAM_IS_MODULATABLE_PER_NOTE_ID :: u32(1 << 11)
CLAP_PARAM_IS_MODULATABLE_PER_KEY :: u32(1 << 12)
CLAP_PARAM_IS_MODULATABLE_PER_CHANNEL :: u32(1 << 13)
CLAP_PARAM_IS_MODULATABLE_PER_PORT :: u32(1 << 14)
CLAP_PARAM_REQUIRES_PROCESS :: u32(1 << 15)
CLAP_PARAM_IS_ENUM :: u32(1 << 16)

Param_Info :: struct {
	id:            u32,
	flags:         u32,
	cookie:        rawptr,
	name:          [CLAP_NAME_SIZE]u8,
	module:        [CLAP_PATH_SIZE]u8,
	min_value:     f64,
	max_value:     f64,
	default_value: f64,
}

Plugin_Params :: struct {
	count:         proc "c" (plugin: ^Plugin) -> u32,
	get_info:      proc "c" (plugin: ^Plugin, param_index: u32, param_info: ^Param_Info) -> bool,
	get_value:     proc "c" (plugin: ^Plugin, param_id: u32, out_value: ^f64) -> bool,
	value_to_text: proc "c" (plugin: ^Plugin, param_id: u32, value: f64, out_buffer: [^]u8, out_buffer_capacity: u32) -> bool,
	text_to_value: proc "c" (plugin: ^Plugin, param_id: u32, param_value_text: cstring, out_value: ^f64) -> bool,
	flush:         proc "c" (plugin: ^Plugin, input: ^Input_Events, output: ^Output_Events),
}

CLAP_PARAM_RESCAN_VALUES :: u32(1 << 0)
CLAP_PARAM_RESCAN_TEXT :: u32(1 << 1)
CLAP_PARAM_RESCAN_INFO :: u32(1 << 2)
CLAP_PARAM_RESCAN_ALL :: u32(1 << 3)

CLAP_PARAM_CLEAR_ALL :: u32(1 << 0)
CLAP_PARAM_CLEAR_AUTOMATIONS :: u32(1 << 1)
CLAP_PARAM_CLEAR_MODULATIONS :: u32(1 << 2)

Host_Params :: struct {
	rescan:        proc "c" (host: ^Host, flags: u32),
	clear:         proc "c" (host: ^Host, param_id: u32, flags: u32),
	request_flush: proc "c" (host: ^Host),
}

// ---------------------------------------------------------------------------
// clap/ext/state.h and clap/stream.h
// ---------------------------------------------------------------------------

IStream :: struct {
	ctx:  rawptr,
	read: proc "c" (stream: ^IStream, buffer: rawptr, size: u64) -> i64,
}

OStream :: struct {
	ctx:   rawptr,
	write: proc "c" (stream: ^OStream, buffer: rawptr, size: u64) -> i64,
}

Plugin_State :: struct {
	save: proc "c" (plugin: ^Plugin, stream: ^OStream) -> bool,
	load: proc "c" (plugin: ^Plugin, stream: ^IStream) -> bool,
}

Host_State :: struct {
	mark_dirty: proc "c" (host: ^Host),
}

// ---------------------------------------------------------------------------
// clap/ext/latency.h
// ---------------------------------------------------------------------------

Plugin_Latency :: struct {
	get: proc "c" (plugin: ^Plugin) -> u32,
}

Host_Latency :: struct {
	changed: proc "c" (host: ^Host),
}

// ---------------------------------------------------------------------------
// clap/ext/thread-check.h
// ---------------------------------------------------------------------------

Host_Thread_Check :: struct {
	is_main_thread:  proc "c" (host: ^Host) -> bool,
	is_audio_thread: proc "c" (host: ^Host) -> bool,
}

// ---------------------------------------------------------------------------
// clap/ext/tail.h
// ---------------------------------------------------------------------------

Plugin_Tail :: struct {
	get: proc "c" (plugin: ^Plugin) -> u32,
}

Host_Tail :: struct {
	changed: proc "c" (host: ^Host),
}

// ---------------------------------------------------------------------------
// clap/ext/render.h
// ---------------------------------------------------------------------------

CLAP_RENDER_REALTIME :: i32(0)
CLAP_RENDER_OFFLINE :: i32(1)
Plugin_Render_Mode :: i32

Plugin_Render :: struct {
	has_hard_realtime_requirement: proc "c" (plugin: ^Plugin) -> bool,
	set:                           proc "c" (plugin: ^Plugin, mode: Plugin_Render_Mode) -> bool,
}
