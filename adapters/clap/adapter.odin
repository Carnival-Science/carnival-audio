// Generic CLAP 1.2 plugin lifecycle adapter.
//
// `adapters/clap` owns the protocol/threading rules: factory, plugin vtables,
// activation state checks, extension tables, parameter plumbing and versioned
// authoring state. A product supplies a `Definition` (descriptor, parameter
// list) and a `Backend_VTable` (the DSP/analysis implementation). The adapter
// never imports a product; products import this package.
//
// Real-time rule: the adapter's process path performs no allocation, locking
// or I/O. It copies parameter values into a bounded stack array and calls the
// backend once. Host event storage is read-only and bounded by the host's
// event count; malformed events are ignored.
package clap_adapter

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:sync"

import clap "carnival:third_party/clap/abi"

MAX_PARAMS :: 32
MAX_STATE_BYTES :: 4096
STATE_HEADER_BYTES :: 16

// ---------------------------------------------------------------------------
// Product-facing contract
// ---------------------------------------------------------------------------

Param_Format :: enum u8 {
	Decimal,
	Integer,
	Milliseconds,
	Decibels,
	Boolean,
}

Param_Descriptor :: struct {
	id:       u32,
	name:     string,
	module:   string,
	flags:    u32,
	min:      f64,
	max:      f64,
	default:  f64,
	format:   Param_Format,
	stepped:  bool,
}

Activation_Config :: struct {
	sample_rate:      f64,
	min_frames_count: u32,
	max_frames_count: u32,
}

Host_Info :: struct {
	host:         ^clap.Host,
	thread_check: ^clap.Host_Thread_Check,
}

Process_Request :: struct {
	steady_time: i64,
	frames:      u32,
	channels:    int,
	// Planar channel pointers. Input is read-only; output is writable.
	input:       [^]^f32,
	output:      [^]^f32,
	// Parameter values in Definition.params order, copied at block start.
	params:      []f64,
	// True when the host supplied the same channel pointers for input and
	// output (in-place processing).
	in_place:    bool,
}

Process_Result :: enum u8 {
	Continue,
	Continue_If_Not_Quiet,
	Sleep,
	Error,
}

Backend_VTable :: struct {
	// create/destroy run on the main thread. create may allocate; destroy must
	// free everything created by create and activate.
	create:    proc() -> rawptr,
	destroy:   proc(data: rawptr),
	// init receives the host pointer before activate. Backend must not call
	// host extension functions outside the CLAP thread rules.
	init:      proc(data: rawptr, host: ^Host_Info) -> bool,
	activate:  proc(data: rawptr, config: Activation_Config) -> bool,
	deactivate: proc(data: rawptr),
	start:     proc(data: rawptr) -> bool,
	stop:      proc(data: rawptr),
	reset:     proc(data: rawptr),
	process:   proc(data: rawptr, request: ^Process_Request) -> Process_Result,
	// telemetry is optional. When present, the adapter exposes the draft
	// Carnival telemetry-capture extension and forwards its calls here. All
	// vtable calls arrive on the host main thread; the drain sink callback runs
	// synchronously on that thread.
	telemetry: ^Telemetry_Ops,
}

// Telemetry_Ops is the product side of the draft Carnival telemetry extension
// (clap.CARNIVAL_EXT_TELEMETRY_CAPTURE_DRAFT). Every proc may be called from the
// host main thread only. drain delivers records through a host callback; the
// record pointer is valid only for the duration of that call.
Telemetry_Ops :: struct {
	set_enabled:    proc(data: rawptr, enabled: bool) -> bool,
	drain:          proc(data: rawptr, sink: clap.Carnival_Capture_Sink, max_records: u32) -> u32,
	dropped:        proc(data: rawptr) -> u64,
	valid:          proc(data: rawptr) -> bool,
	schema_version: proc(data: rawptr) -> u32,
}

// Checkpoint_Ops is the product side of the draft Carnival
// processing-checkpoint capability
// (clap.CARNIVAL_EXT_PROCESSING_CHECKPOINT_DRAFT). It is **separate from
// authoring state**: authoring state reopens a project with the same settings,
// a checkpoint resumes computation at an exact sample position. A product opts
// in by setting `Definition.checkpoint`; a nil value means `supported()` reports
// false and the host must not probe further. The product owns the payload
// framing (magic/version/length) and must validate it before committing.
// Main thread only, like the state extension.
Checkpoint_Ops :: struct {
	save: proc(data: rawptr, stream: ^clap.OStream) -> bool,
	load: proc(data: rawptr, stream: ^clap.IStream) -> bool,
}

Definition :: struct {
	descriptor:      ^clap.Plugin_Descriptor,
	backend:         ^Backend_VTable,
	params:          []Param_Descriptor,
	input_port_id:   u32,
	output_port_id:  u32,
	input_port_name: string,
	output_port_name: string,
	state_magic:     [8]u8,
	state_schema:    u32,
	// Optional product authoring flags appended to state schema 3 and later.
	// Schema 1/2 files carry no flag word; loading one leaves the product at
	// its default flags. The save hook returns the current flags, the load hook
	// applies a validated value. A definition that sets these hooks must use
	// state_schema >= 3.
	state_flags_save: proc(data: rawptr) -> u32,
	state_flags_load: proc(data: rawptr, flags: u32),
	// Optional processing-checkpoint capability. This is deliberately NOT part
	// of state_schema: authoring state and processing checkpoints are separate
	// contracts with separate lifetimes. A definition that sets both hooks
	// exposes the draft checkpoint extension and reports supported() == true.
	// Products that cannot snapshot processing state leave this nil.
	checkpoint: ^Checkpoint_Ops,
	// Optional declared tail length in frames. The adapter's clap.tail
	// extension reports this value; a nil hook reports zero.
	tail_frames: proc(data: rawptr) -> u32,
}

// ---------------------------------------------------------------------------
// Instance
// ---------------------------------------------------------------------------

Instance :: struct {
	plugin:        clap.Plugin,
	host:          ^clap.Host,
	host_info:     Host_Info,
	host_params:   ^clap.Host_Params,
	definition:    ^Definition,
	data:          rawptr,
	initialized:   bool,
	active:        bool,
	processing:    bool,
	max_frames:    u32,
	param_values:  [MAX_PARAMS]u64, // atomic f64 bit patterns
	ext_audio_ports: clap.Plugin_Audio_Ports,
	ext_params:      clap.Plugin_Params,
	ext_state:       clap.Plugin_State,
	ext_latency:     clap.Plugin_Latency,
	ext_tail:        clap.Plugin_Tail,
	ext_telemetry:   clap.Carnival_Telemetry_Capture,
	ext_checkpoint:  clap.Carnival_Processing_Checkpoint,
}

// ---------------------------------------------------------------------------
// Definition registry and entry point
//
// A CLAP DSO may host exactly one product definition in this repository. The
// product's exported clap_entry calls register_definition from init() before
// get_factory is used, then delegates to entry_init/deinit/get_factory. The
// registry is not atomic because CLAP forbids concurrent init/deinit and the
// factory is only queried after a successful init.
// ---------------------------------------------------------------------------

@(private)
registered_definition: ^Definition
@(private)
entry_init_depth: int
@(private)
process_allocator: mem.Allocator

// set_process_allocator installs an allocator for the process callback's
// context. Tests use it with a tracking allocator to prove the real-time path
// performs no context-allocator allocation. Passing a zero Allocator restores
// the default heap for process. This is a test seam, not a released ABI.
set_process_allocator :: proc(allocator: mem.Allocator) {
	process_allocator = allocator
}

register_definition :: proc "c" (definition: ^Definition) {
	registered_definition = definition
}

entry_init :: proc "c" (plugin_path: cstring) -> bool {
	_ = plugin_path
	entry_init_depth += 1
	return registered_definition != nil
}

entry_deinit :: proc "c" () {
	if entry_init_depth > 0 {
		entry_init_depth -= 1
	}
	if entry_init_depth == 0 {
		registered_definition = nil
	}
}

entry_get_factory :: proc "c" (factory_id: cstring) -> rawptr {
	if factory_id == nil || string(factory_id) != clap.CLAP_PLUGIN_FACTORY_ID {
		return nil
	}
	return &factory
}

@(private)
factory_get_plugin_count :: proc "c" (factory: ^clap.Plugin_Factory) -> u32 {
	_ = factory
	if registered_definition == nil {
		return 0
	}
	return 1
}

@(private)
factory_get_plugin_descriptor :: proc "c" (factory: ^clap.Plugin_Factory, index: u32) -> ^clap.Plugin_Descriptor {
	_ = factory
	if registered_definition == nil || index != 0 {
		return nil
	}
	return registered_definition.descriptor
}

@(private)
factory_create_plugin :: proc "c" (factory: ^clap.Plugin_Factory, host: ^clap.Host, plugin_id: cstring) -> ^clap.Plugin {
	context = runtime.default_context()
	_ = factory
	definition := registered_definition
	if definition == nil || host == nil || !clap.version_is_compatible(host.clap_version) {
		return nil
	}
	if definition.descriptor == nil || plugin_id == nil || string(plugin_id) != string(definition.descriptor.id) {
		return nil
	}
	if len(definition.params) > MAX_PARAMS {
		return nil
	}
	if (definition.state_flags_save != nil || definition.state_flags_load != nil) &&
		definition.state_schema < 3 {
		return nil
	}
	if definition.checkpoint != nil &&
		(definition.checkpoint.save == nil || definition.checkpoint.load == nil) {
		return nil
	}
	if definition.backend == nil || definition.backend.create == nil || definition.backend.process == nil {
		return nil
	}

	allocator := runtime.default_allocator()
	instance := new(Instance, allocator)
	if instance == nil {
		return nil
	}
	instance.definition = definition
	instance.host = host
	instance.host_info.host = host
	for param, index in definition.params {
		sync.atomic_store_explicit(&instance.param_values[index],
			transmute(u64)clamp_param(param, param.default), .Release)
	}
	instance.data = definition.backend.create()
	if instance.data == nil {
		free(instance, allocator)
		return nil
	}

	instance.plugin = clap.Plugin{
		desc = definition.descriptor,
		plugin_data = instance,
		init = plugin_init,
		destroy = plugin_destroy,
		activate = plugin_activate,
		deactivate = plugin_deactivate,
		start_processing = plugin_start_processing,
		stop_processing = plugin_stop_processing,
		reset = plugin_reset,
		process = plugin_process,
		get_extension = plugin_get_extension,
		on_main_thread = plugin_on_main_thread,
	}
	instance.ext_audio_ports = clap.Plugin_Audio_Ports{
		count = audio_ports_count,
		get = audio_ports_get,
	}
	instance.ext_params = clap.Plugin_Params{
		count = params_count,
		get_info = params_get_info,
		get_value = params_get_value,
		value_to_text = params_value_to_text,
		text_to_value = params_text_to_value,
		flush = params_flush,
	}
	instance.ext_state = clap.Plugin_State{
		save = state_save,
		load = state_load,
	}
	instance.ext_latency = clap.Plugin_Latency{get = latency_get}
	instance.ext_tail = clap.Plugin_Tail{get = tail_get}
	if definition.backend.telemetry != nil {
		instance.ext_telemetry = clap.Carnival_Telemetry_Capture{
			set_enabled = telemetry_set_enabled,
			drain = telemetry_drain,
			dropped = telemetry_dropped,
			valid = telemetry_valid,
			schema_version = telemetry_schema_version,
		}
	}
	instance.ext_checkpoint = clap.Carnival_Processing_Checkpoint{
		supported = checkpoint_ext_supported,
		save = checkpoint_ext_save,
		load = checkpoint_ext_load,
		schema_version = checkpoint_ext_schema_version,
	}
	return &instance.plugin
}

factory: clap.Plugin_Factory = {
	get_plugin_count = factory_get_plugin_count,
	get_plugin_descriptor = factory_get_plugin_descriptor,
	create_plugin = factory_create_plugin,
}

// ---------------------------------------------------------------------------
// Plugin lifecycle
// ---------------------------------------------------------------------------

@(private)
instance_of :: proc "c" (plugin: ^clap.Plugin) -> ^Instance {
	return cast(^Instance)plugin.plugin_data
}

@(private)
plugin_init :: proc "c" (plugin: ^clap.Plugin) -> bool {
	context = runtime.default_context()
	instance := instance_of(plugin)
	if instance == nil || instance.initialized {
		return false
	}
	if instance.host != nil && instance.host.get_extension != nil {
		thread_check := instance.host.get_extension(instance.host, cstring(clap.CLAP_EXT_THREAD_CHECK))
		instance.host_info.thread_check = cast(^clap.Host_Thread_Check)thread_check
		host_params := instance.host.get_extension(instance.host, cstring(clap.CLAP_EXT_PARAMS))
		instance.host_params = cast(^clap.Host_Params)host_params
	}
	if instance.definition.backend.init != nil {
		if !instance.definition.backend.init(instance.data, &instance.host_info) {
			return false
		}
	}
	instance.initialized = true
	return true
}

@(private)
plugin_destroy :: proc "c" (plugin: ^clap.Plugin) {
	context = runtime.default_context()
	instance := instance_of(plugin)
	if instance == nil {
		return
	}
	if instance.active {
		plugin_deactivate(plugin)
	}
	if instance.definition.backend.destroy != nil {
		instance.definition.backend.destroy(instance.data)
	}
	free(instance, runtime.default_allocator())
}

@(private)
plugin_activate :: proc "c" (plugin: ^clap.Plugin, sample_rate: f64, min_frames_count, max_frames_count: u32) -> bool {
	context = runtime.default_context()
	instance := instance_of(plugin)
	if instance == nil || !instance.initialized || instance.active {
		return false
	}
	if sample_rate <= 0 || min_frames_count < 1 || max_frames_count < min_frames_count {
		return false
	}
	if max_frames_count > 0x7FFF_FFFF {
		return false
	}
	config := Activation_Config{
		sample_rate = sample_rate,
		min_frames_count = min_frames_count,
		max_frames_count = max_frames_count,
	}
	if instance.definition.backend.activate != nil {
		if !instance.definition.backend.activate(instance.data, config) {
			return false
		}
	}
	instance.max_frames = max_frames_count
	instance.active = true
	instance.processing = false
	return true
}

@(private)
plugin_deactivate :: proc "c" (plugin: ^clap.Plugin) {
	context = runtime.default_context()
	instance := instance_of(plugin)
	if instance == nil || !instance.active {
		return
	}
	instance.processing = false
	if instance.definition.backend.deactivate != nil {
		instance.definition.backend.deactivate(instance.data)
	}
	instance.active = false
}

@(private)
plugin_start_processing :: proc "c" (plugin: ^clap.Plugin) -> bool {
	context = runtime.default_context()
	instance := instance_of(plugin)
	if instance == nil || !instance.active || instance.processing {
		return false
	}
	if instance.definition.backend.start != nil {
		if !instance.definition.backend.start(instance.data) {
			return false
		}
	}
	instance.processing = true
	return true
}

@(private)
plugin_stop_processing :: proc "c" (plugin: ^clap.Plugin) {
	context = runtime.default_context()
	instance := instance_of(plugin)
	if instance == nil || !instance.processing {
		return
	}
	if instance.definition.backend.stop != nil {
		instance.definition.backend.stop(instance.data)
	}
	instance.processing = false
}

@(private)
plugin_reset :: proc "c" (plugin: ^clap.Plugin) {
	context = runtime.default_context()
	instance := instance_of(plugin)
	if instance == nil || !instance.active {
		return
	}
	if instance.definition.backend.reset != nil {
		instance.definition.backend.reset(instance.data)
	}
}

@(private)
plugin_on_main_thread :: proc "c" (plugin: ^clap.Plugin) {
	_ = plugin
}

// ---------------------------------------------------------------------------
// Process path (real-time)
// ---------------------------------------------------------------------------

@(private)
plugin_process :: proc "c" (plugin: ^clap.Plugin, process: ^clap.Process) -> clap.Process_Status {
	process_context := runtime.default_context()
	if process_allocator.procedure != nil {
		process_context.allocator = process_allocator
		process_context.temp_allocator = process_allocator
	}
	context = process_context
	instance := instance_of(plugin)
	if instance == nil || !instance.active || !instance.processing || process == nil {
		return clap.CLAP_PROCESS_ERROR
	}
	frames := process.frames_count
	if frames > instance.max_frames {
		return clap.CLAP_PROCESS_ERROR
	}
	if frames == 0 {
		return clap.CLAP_PROCESS_CONTINUE
	}
	if process.audio_inputs_count != 1 || process.audio_outputs_count != 1 {
		return clap.CLAP_PROCESS_ERROR
	}
	if process.audio_inputs == nil || process.audio_outputs == nil {
		return clap.CLAP_PROCESS_ERROR
	}
	input := &process.audio_inputs[0]
	output := &process.audio_outputs[0]
	if input.channel_count != 2 || output.channel_count != 2 {
		return clap.CLAP_PROCESS_ERROR
	}
	// 64-bit audio is not advertised by this plugin.
	if input.data64 != nil || output.data64 != nil {
		return clap.CLAP_PROCESS_ERROR
	}
	if input.data32 == nil || output.data32 == nil {
		return clap.CLAP_PROCESS_ERROR
	}
	for channel in 0 ..< 2 {
		if input.data32[channel] == nil || output.data32[channel] == nil {
			return clap.CLAP_PROCESS_ERROR
		}
	}

	apply_events(instance, process.in_events)

	values: [MAX_PARAMS]f64
	param_count := len(instance.definition.params)
	for index in 0 ..< param_count {
		bits := sync.atomic_load_explicit(&instance.param_values[index], .Acquire)
		values[index] = transmute(f64)bits
	}
	request := Process_Request{
		steady_time = process.steady_time,
		frames = frames,
		channels = 2,
		input = input.data32,
		output = output.data32,
		params = values[:param_count],
		in_place = input.data32[0] == output.data32[0] && input.data32[1] == output.data32[1],
	}
	result := instance.definition.backend.process(instance.data, &request)
	switch result {
	case .Continue:            return clap.CLAP_PROCESS_CONTINUE
	case .Continue_If_Not_Quiet: return clap.CLAP_PROCESS_CONTINUE_IF_NOT_QUIET
	case .Sleep:               return clap.CLAP_PROCESS_SLEEP
	case .Error:               return clap.CLAP_PROCESS_ERROR
	}
	return clap.CLAP_PROCESS_ERROR
}

// apply_events copies parameter automation into the atomic value table. It
// allocates nothing. A malformed or unknown event is ignored (host error, not
// a reason to break passthrough). Values are applied at block granularity: the
// backend sees one parameter snapshot per process call.
@(private)
apply_events :: proc "c" (instance: ^Instance, list: ^clap.Input_Events) {
	if list == nil || list.size == nil || list.get == nil {
		return
	}
	count := list.size(list)
	for index in 0 ..< count {
		header := list.get(list, index)
		if header == nil || header.size < u32(size_of(clap.Event_Header)) {
			continue
		}
		if header.space_id != clap.CLAP_CORE_EVENT_SPACE_ID {
			continue
		}
		if header.type != u16(clap.Event_Type.Param_Value) ||
			header.size < u32(size_of(clap.Event_Param_Value)) {
			continue
		}
		event := cast(^clap.Event_Param_Value)header
		set_param_value(instance, event.param_id, event.value)
	}
}

@(private)
set_param_value :: proc "c" (instance: ^Instance, id: u32, raw_value: f64) -> bool {
	index := find_param(instance.definition, id)
	if index < 0 {
		return false
	}
	param := instance.definition.params[index]
	value := clamp_param(param, raw_value)
	sync.atomic_store_explicit(&instance.param_values[index], transmute(u64)value, .Release)
	return true
}

// ---------------------------------------------------------------------------
// Audio ports extension
// ---------------------------------------------------------------------------

@(private)
audio_ports_count :: proc "c" (plugin: ^clap.Plugin, is_input: bool) -> u32 {
	_ = plugin
	_ = is_input
	return 1
}

@(private)
audio_ports_get :: proc "c" (plugin: ^clap.Plugin, index: u32, is_input: bool, info: ^clap.Audio_Port_Info) -> bool {
	instance := instance_of(plugin)
	if instance == nil || info == nil || index != 0 {
		return false
	}
	definition := instance.definition
	info^ = {}
	if is_input {
		info.id = definition.input_port_id
		fill_c_array(info.name[:], definition.input_port_name)
		info.in_place_pair = definition.output_port_id
	} else {
		info.id = definition.output_port_id
		fill_c_array(info.name[:], definition.output_port_name)
		info.in_place_pair = definition.input_port_id
	}
	info.flags = clap.CLAP_AUDIO_PORT_IS_MAIN
	info.channel_count = 2
	info.port_type = cstring(clap.CLAP_PORT_STEREO)
	return true
}

@(private)
fill_c_array :: proc "c" (destination: []u8, value: string) {
	if len(destination) == 0 {
		return
	}
	count := min(len(value), len(destination) - 1)
	if count > 0 {
		copy(destination[:count], value[:count])
	}
	destination[count] = 0
}

// ---------------------------------------------------------------------------
// Parameters extension
// ---------------------------------------------------------------------------

@(private)
find_param :: proc "c" (definition: ^Definition, id: u32) -> int {
	if definition == nil {
		return -1
	}
	for param, index in definition.params {
		if param.id == id {
			return index
		}
	}
	return -1
}

@(private)
clamp_param :: proc "c" (param: Param_Descriptor, value: f64) -> f64 {
	result := clamp(value, param.min, param.max)
	if param.stepped || param.format == .Integer || param.format == .Milliseconds || param.format == .Boolean {
		result = f64(round_to_i64(result))
		result = clamp(result, param.min, param.max)
	}
	return result
}

@(private)
round_to_i64 :: proc "c" (value: f64) -> i64 {
	if value >= 0 {
		return i64(value + 0.5)
	}
	return i64(value - 0.5)
}

@(private)
params_count :: proc "c" (plugin: ^clap.Plugin) -> u32 {
	instance := instance_of(plugin)
	if instance == nil {
		return 0
	}
	return u32(len(instance.definition.params))
}

@(private)
params_get_info :: proc "c" (plugin: ^clap.Plugin, param_index: u32, info: ^clap.Param_Info) -> bool {
	instance := instance_of(plugin)
	if instance == nil || info == nil || int(param_index) >= len(instance.definition.params) {
		return false
	}
	param := instance.definition.params[param_index]
	info^ = {}
	info.id = param.id
	info.flags = param.flags
	fill_c_array(info.name[:], param.name)
	fill_c_array(info.module[:], param.module)
	info.min_value = param.min
	info.max_value = param.max
	info.default_value = param.default
	return true
}

@(private)
params_get_value :: proc "c" (plugin: ^clap.Plugin, param_id: u32, out_value: ^f64) -> bool {
	instance := instance_of(plugin)
	if instance == nil || out_value == nil {
		return false
	}
	index := find_param(instance.definition, param_id)
	if index < 0 {
		return false
	}
	bits := sync.atomic_load_explicit(&instance.param_values[index], .Acquire)
	out_value^ = transmute(f64)bits
	return true
}

@(private)
params_value_to_text :: proc "c" (
	plugin: ^clap.Plugin,
	param_id: u32,
	value: f64,
	out_buffer: [^]u8,
	out_buffer_capacity: u32,
) -> bool {
	context = runtime.default_context()
	instance := instance_of(plugin)
	if instance == nil || out_buffer == nil || out_buffer_capacity == 0 {
		return false
	}
	index := find_param(instance.definition, param_id)
	if index < 0 {
		return false
	}
	param := instance.definition.params[index]
	clamped := clamp_param(param, value)
	buffer: [128]u8
	text: string
	switch param.format {
	case .Boolean:
		text = clamped >= 0.5 ? "On" : "Off"
	case .Integer:
		text = fmt.bprintf(buffer[:], "%d", round_to_i64(clamped))
	case .Milliseconds:
		text = fmt.bprintf(buffer[:], "%d ms", round_to_i64(clamped))
	case .Decibels:
		text = fmt.bprintf(buffer[:], "%.1f dB", clamped)
	case .Decimal:
		text = fmt.bprintf(buffer[:], "%.3f", clamped)
	}
	write_c_string(out_buffer, out_buffer_capacity, text)
	return true
}

@(private)
params_text_to_value :: proc "c" (
	plugin: ^clap.Plugin,
	param_id: u32,
	param_value_text: cstring,
	out_value: ^f64,
) -> bool {
	context = runtime.default_context()
	instance := instance_of(plugin)
	if instance == nil || out_value == nil || param_value_text == nil {
		return false
	}
	index := find_param(instance.definition, param_id)
	if index < 0 {
		return false
	}
	param := instance.definition.params[index]
	text := strings.trim_space(string(param_value_text))
	if param.format == .Boolean {
		if strings.equal_fold(text, "on") || strings.equal_fold(text, "true") || text == "1" {
			out_value^ = 1
			return true
		}
		if strings.equal_fold(text, "off") || strings.equal_fold(text, "false") || text == "0" {
			out_value^ = 0
			return true
		}
		return false
	}
	if strings.has_suffix(text, "ms") {
		text = strings.trim_space(text[:len(text) - 2])
	} else if strings.has_suffix(text, "dB") {
		text = strings.trim_space(text[:len(text) - 2])
	}
	parsed, ok := strconv.parse_f64(text)
	if !ok {
		return false
	}
	out_value^ = clamp_param(param, parsed)
	return true
}

@(private)
params_flush :: proc "c" (plugin: ^clap.Plugin, input: ^clap.Input_Events, output: ^clap.Output_Events) {
	_ = output
	instance := instance_of(plugin)
	if instance == nil {
		return
	}
	apply_events(instance, input)
}

@(private)
write_c_string :: proc "c" (buffer: [^]u8, capacity: u32, text: string) {
	count := min(len(text), int(capacity) - 1)
	if count > 0 {
		copy(buffer[:count], text[:count])
	}
	buffer[count] = 0
}

// ---------------------------------------------------------------------------
// State extension
//
// State is authoring state only: stable parameter IDs and values, plus an
// optional product flag word. Processing state (windows, accumulators, clocks)
// is never serialized here. The format is:
//
//   magic[8] | u32 schema | u32 param_count | param_count * (u32 id, f64 value)
//            [| u32 product_flags]        (schema 3+ with a flags hook)
//
// Schema 1 contained parameters 1001..1003. Schema 2 adds 1004; loading a v1
// fixture leaves 1004 at its descriptor default. Schema 3 appends a product
// flag word (Pulse uses bit 0 for telemetry capture mode); loading a v1/v2
// fixture leaves the flags at the product default. All fields are
// native-endian (the supported targets are little-endian); no cross-endian
// claim is made.
//
// Processing state is a different contract: see the draft
// com.carnival-science.processing-checkpoint.draft/1 extension and
// `Checkpoint_Ops`. Schema 4 existed in the Milestone 2 preparation and
// appended a plugin-owned processing blob to this authoring stream; that
// conflated the two contracts and has been removed. Definitions are back at
// schema 3 (or lower) and a schema-4 file is rejected by the schema check.
// ---------------------------------------------------------------------------

@(private)
state_save :: proc "c" (plugin: ^clap.Plugin, stream: ^clap.OStream) -> bool {
	context = runtime.default_context()
	instance := instance_of(plugin)
	if instance == nil || stream == nil || stream.write == nil {
		return false
	}
	definition := instance.definition
	count := len(definition.params)
	if count > MAX_PARAMS {
		return false
	}
	buffer: [MAX_STATE_BYTES]u8
	offset := 0
	copy(buffer[offset:offset + 8], definition.state_magic[:])
	offset += 8
	put_u32(buffer[:], offset, definition.state_schema)
	offset += 4
	put_u32(buffer[:], offset, u32(count))
	offset += 4
	for param, index in definition.params {
		bits := sync.atomic_load_explicit(&instance.param_values[index], .Acquire)
		put_u32(buffer[:], offset, param.id)
		offset += 4
		put_f64(buffer[:], offset, transmute(f64)bits)
		offset += 8
	}
	if definition.state_flags_save != nil {
		put_u32(buffer[:], offset, definition.state_flags_save(instance.data))
		offset += 4
	}
	if !write_all(stream, buffer[:offset]) {
		return false
	}
	return true
}

@(private)
state_load :: proc "c" (plugin: ^clap.Plugin, stream: ^clap.IStream) -> bool {
	context = runtime.default_context()
	instance := instance_of(plugin)
	if instance == nil || stream == nil || stream.read == nil {
		return false
	}
	definition := instance.definition
	header: [STATE_HEADER_BYTES]u8
	if !read_all(stream, header[:]) {
		return false
	}
	for index in 0 ..< 8 {
		if header[index] != definition.state_magic[index] {
			return false
		}
	}
	schema := get_u32(header[:], 8)
	count := int(get_u32(header[:], 12))
	if schema < 1 || schema > definition.state_schema || count < 0 || count > MAX_PARAMS {
		return false
	}
	// Migrate into a defaults copy. Missing parameters (a v1 file loading into a
	// v2 definition) keep their descriptor defaults.
	values: [MAX_PARAMS]f64
	for param, index in definition.params {
		values[index] = clamp_param(param, param.default)
	}
	for _ in 0 ..< count {
		record: [12]u8
		if !read_all(stream, record[:]) {
			return false
		}
		id := get_u32(record[:], 0)
		value := get_f64(record[:], 4)
		index := find_param(definition, id)
		if index < 0 {
			continue
		}
		values[index] = clamp_param(definition.params[index], value)
	}
	flags: u32
	if definition.state_flags_save != nil && schema >= 3 {
		flag_bytes: [4]u8
		if !read_all(stream, flag_bytes[:]) {
			return false
		}
		flags = get_u32(flag_bytes[:], 0)
	}
	// Commit only after the whole stream has been validated.
	for _, index in definition.params {
		sync.atomic_store_explicit(&instance.param_values[index], transmute(u64)values[index], .Release)
	}
	if definition.state_flags_load != nil {
		definition.state_flags_load(instance.data, flags)
	}
	// CLAP state load is a main-thread authoring operation; tell the host that
	// cached parameter values changed. Some hosts (and clap-validator) require
	// this rescan rather than silently accepting a value jump.
	if instance.host_params != nil && instance.host_params.rescan != nil {
		instance.host_params.rescan(instance.host, clap.CLAP_PARAM_RESCAN_VALUES)
	}
	return true
}

@(private)
write_all :: proc "c" (stream: ^clap.OStream, bytes: []u8) -> bool {
	written := 0
	for written < len(bytes) {
		count := stream.write(stream, raw_data(bytes[written:]), u64(len(bytes) - written))
		if count <= 0 {
			return false
		}
		written += int(count)
	}
	return true
}

@(private)
read_all :: proc "c" (stream: ^clap.IStream, bytes: []u8) -> bool {
	read := 0
	for read < len(bytes) {
		count := stream.read(stream, raw_data(bytes[read:]), u64(len(bytes) - read))
		if count <= 0 {
			return false
		}
		read += int(count)
	}
	return true
}

@(private)
put_u32 :: proc "c" (buffer: []u8, offset: int, value: u32) {
	buffer[offset + 0] = u8(value)
	buffer[offset + 1] = u8(value >> 8)
	buffer[offset + 2] = u8(value >> 16)
	buffer[offset + 3] = u8(value >> 24)
}

@(private)
get_u32 :: proc "c" (buffer: []u8, offset: int) -> u32 {
	return u32(buffer[offset]) |
		u32(buffer[offset + 1]) << 8 |
		u32(buffer[offset + 2]) << 16 |
		u32(buffer[offset + 3]) << 24
}

@(private)
put_f64 :: proc "c" (buffer: []u8, offset: int, value: f64) {
	bits := transmute(u64)value
	for index in 0 ..< 8 {
		buffer[offset + index] = u8(bits >> (8 * u64(index)))
	}
}

@(private)
get_f64 :: proc "c" (buffer: []u8, offset: int) -> f64 {
	bits: u64
	for index in 0 ..< 8 {
		bits |= u64(buffer[offset + index]) << (8 * u64(index))
	}
	return transmute(f64)bits
}

// ---------------------------------------------------------------------------
// Latency and tail extensions
// ---------------------------------------------------------------------------

@(private)
latency_get :: proc "c" (plugin: ^clap.Plugin) -> u32 {
	_ = plugin
	return 0
}

@(private)
tail_get :: proc "c" (plugin: ^clap.Plugin) -> u32 {
	instance := instance_of(plugin)
	if instance == nil || instance.definition.tail_frames == nil {
		return 0
	}
	context = runtime.default_context()
	return instance.definition.tail_frames(instance.data)
}

// ---------------------------------------------------------------------------
// Draft Carnival telemetry-capture extension (private, experimental)
// ---------------------------------------------------------------------------

// The draft extension is main-thread-only. When the host offers
// clap.thread-check, enforce it; otherwise the host contract is documented but
// not observable.
@(private)
telemetry_on_main_thread :: proc(instance: ^Instance) -> bool {
	if instance.host_info.thread_check != nil && instance.host_info.thread_check.is_main_thread != nil {
		return instance.host_info.thread_check.is_main_thread(instance.host)
	}
	return true
}

@(private)
telemetry_set_enabled :: proc "c" (plugin: ^clap.Plugin, enabled: bool) -> bool {
	context = runtime.default_context()
	instance := instance_of(plugin)
	if instance == nil || instance.data == nil || instance.definition.backend.telemetry == nil {
		return false
	}
	if !telemetry_on_main_thread(instance) {
		return false
	}
	// Capture episodes require quiescent processing: start/stop_processing is
	// the host's quiescence signal, and while it is held the audio thread may
	// still be inside a publication. Refusing here is enforceable (the adapter
	// owns the processing lifecycle) and avoids a toggle racing an in-flight
	// push.
	if instance.processing {
		return false
	}
	return instance.definition.backend.telemetry.set_enabled(instance.data, enabled)
}

@(private)
telemetry_drain :: proc "c" (
	plugin: ^clap.Plugin,
	sink: clap.Carnival_Capture_Sink,
	max_records: u32,
) -> u32 {
	context = runtime.default_context()
	instance := instance_of(plugin)
	if instance == nil || instance.data == nil || instance.definition.backend.telemetry == nil {
		return 0
	}
	if !telemetry_on_main_thread(instance) {
		return 0
	}
	return instance.definition.backend.telemetry.drain(instance.data, sink, max_records)
}

@(private)
telemetry_dropped :: proc "c" (plugin: ^clap.Plugin) -> u64 {
	context = runtime.default_context()
	instance := instance_of(plugin)
	if instance == nil || instance.data == nil || instance.definition.backend.telemetry == nil {
		return 0
	}
	if !telemetry_on_main_thread(instance) {
		return 0
	}
	return instance.definition.backend.telemetry.dropped(instance.data)
}

@(private)
telemetry_valid :: proc "c" (plugin: ^clap.Plugin) -> bool {
	context = runtime.default_context()
	instance := instance_of(plugin)
	if instance == nil || instance.data == nil || instance.definition.backend.telemetry == nil {
		return false
	}
	if !telemetry_on_main_thread(instance) {
		return false
	}
	return instance.definition.backend.telemetry.valid(instance.data)
}

@(private)
telemetry_schema_version :: proc "c" (plugin: ^clap.Plugin) -> u32 {
	context = runtime.default_context()
	instance := instance_of(plugin)
	if instance == nil || instance.data == nil || instance.definition.backend.telemetry == nil {
		return 0
	}
	if !telemetry_on_main_thread(instance) {
		return 0
	}
	return instance.definition.backend.telemetry.schema_version(instance.data)
}

// ---------------------------------------------------------------------------
// Draft Carnival processing-checkpoint extension (private, experimental)
//
// This is a different contract from clap.state. The extension is always
// exposed so a host can ask `supported()`; a product that does not implement
// checkpointing reports false and the host must stop there. Main-thread only,
// enforced through clap.thread-check when the host offers it.
// ---------------------------------------------------------------------------

@(private)
checkpoint_on_main_thread :: proc(instance: ^Instance) -> bool {
	if instance.host_info.thread_check != nil && instance.host_info.thread_check.is_main_thread != nil {
		return instance.host_info.thread_check.is_main_thread(instance.host)
	}
	return true
}

@(private)
checkpoint_ext_supported :: proc "c" (plugin: ^clap.Plugin) -> bool {
	context = runtime.default_context()
	instance := instance_of(plugin)
	if instance == nil || instance.data == nil || instance.definition.checkpoint == nil {
		return false
	}
	if !checkpoint_on_main_thread(instance) {
		return false
	}
	return true
}

@(private)
checkpoint_ext_save :: proc "c" (plugin: ^clap.Plugin, stream: ^clap.OStream) -> bool {
	context = runtime.default_context()
	instance := instance_of(plugin)
	if instance == nil || instance.data == nil || instance.definition.checkpoint == nil {
		return false
	}
	if !checkpoint_on_main_thread(instance) {
		return false
	}
	if stream == nil || stream.write == nil {
		return false
	}
	return instance.definition.checkpoint.save(instance.data, stream)
}

@(private)
checkpoint_ext_load :: proc "c" (plugin: ^clap.Plugin, stream: ^clap.IStream) -> bool {
	context = runtime.default_context()
	instance := instance_of(plugin)
	if instance == nil || instance.data == nil || instance.definition.checkpoint == nil {
		return false
	}
	if !checkpoint_on_main_thread(instance) {
		return false
	}
	if stream == nil || stream.read == nil {
		return false
	}
	return instance.definition.checkpoint.load(instance.data, stream)
}

@(private)
checkpoint_ext_schema_version :: proc "c" (plugin: ^clap.Plugin) -> u32 {
	context = runtime.default_context()
	instance := instance_of(plugin)
	if instance == nil || instance.data == nil || instance.definition.checkpoint == nil {
		return 0
	}
	if !checkpoint_on_main_thread(instance) {
		return 0
	}
	return clap.CARNIVAL_CHECKPOINT_SCHEMA_VERSION
}

// ---------------------------------------------------------------------------
// Extension dispatch
// ---------------------------------------------------------------------------

@(private)
plugin_get_extension :: proc "c" (plugin: ^clap.Plugin, id: cstring) -> rawptr {
	instance := instance_of(plugin)
	if instance == nil {
		return nil
	}
	name := string(id)
	switch name {
	case clap.CLAP_EXT_AUDIO_PORTS: return &instance.ext_audio_ports
	case clap.CLAP_EXT_PARAMS:      return &instance.ext_params
	case clap.CLAP_EXT_STATE:       return &instance.ext_state
	case clap.CLAP_EXT_LATENCY:     return &instance.ext_latency
	case clap.CLAP_EXT_TAIL:        return &instance.ext_tail
	case clap.CARNIVAL_EXT_TELEMETRY_CAPTURE_DRAFT:
		if instance.definition.backend.telemetry == nil {
			return nil
		}
		return &instance.ext_telemetry
	case clap.CARNIVAL_EXT_PROCESSING_CHECKPOINT_DRAFT:
		// Always exposed: `supported()` is the capability query. A product
		// that does not checkpoint processing state reports false.
		return &instance.ext_checkpoint
	}
	return nil
}







