// Independent CLAP host used by the verification laboratory.
//
// This package speaks the CLAP 1.2.10 ABI declared in `third_party/clap` and
// loads any `.clap` shared library at runtime. It deliberately does **not**
// import `adapters/clap`, `products/` or `core/dsp`: the host must not share an
// implementation with the specimen it verifies. Sharing the protocol
// declaration is required and is not sharing an implementation.
//
// Scope:
//   - library load/unload, entry init/deinit, factory and descriptor queries;
//   - instance create/init/activate/start/process/stop/deactivate/destroy;
//   - variable block sizes, planar stereo audio, parameter events with sample
//     timestamps, and a transport event;
//   - authoring state save/load through host memory streams;
//   - audio-ports/params/state/latency/tail/thread-check host extensions;
//   - the draft Carnival telemetry-capture extension (record drain).
//
// Thread discipline: the host identifies the main thread and marks the audio
// thread for the duration of a process call. `clap.thread-check` reports those
// identities, so a plugin that honors the extension rejects main-thread-only
// calls made from a worker thread. Calls made by this package are main-thread
// calls unless a test explicitly says otherwise.
package verification_host

import "base:runtime"
import "core:dynlib"
import "core:mem"
import "core:strings"
import "core:sync"

import clap "carnival:third_party/clap/abi"

MAX_HOST_CHANNELS :: 2

// ---------------------------------------------------------------------------
// Library
// ---------------------------------------------------------------------------

Library :: struct {
	handle:      dynlib.Library,
	path:        string,
	path_c:      cstring,
	entry:       ^clap.Entry,
	loaded:      bool,
	initialized: bool,
	allocator:   mem.Allocator,
}

// library_open loads a CLAP shared library, resolves `clap_entry` and calls the
// entry init. The library stays loaded until library_close.
library_open :: proc(path: string, allocator := context.allocator) -> (Library, bool) {
	library: Library
	library.allocator = allocator
	library.path = strings.clone(path, allocator)
	handle, loaded := dynlib.load_library(library.path, false, allocator)
	if !loaded {
		return library, false
	}
	library.handle = handle
	symbol, found := dynlib.symbol_address(handle, "clap_entry")
	if !found || symbol == nil {
		dynlib.unload_library(handle)
		return library, false
	}
	library.entry = cast(^clap.Entry)symbol
	if library.entry == nil || !clap.version_is_compatible(library.entry.clap_version) {
		dynlib.unload_library(handle)
		return library, false
	}
	if library.entry.init == nil || library.entry.deinit == nil || library.entry.get_factory == nil {
		dynlib.unload_library(handle)
		return library, false
	}
	library.path_c = strings.clone_to_cstring(library.path, allocator)
	if !library.entry.init(library.path_c) {
		dynlib.unload_library(handle)
		return library, false
	}
	library.loaded = true
	library.initialized = true
	return library, true
}

library_close :: proc(library: ^Library) {
	if library == nil || !library.loaded {
		return
	}
	if library.entry != nil && library.entry.deinit != nil {
		library.entry.deinit()
	}
	if library.path_c != nil {
		delete(library.path_c, library.allocator)
	}
	if library.handle != nil {
		dynlib.unload_library(library.handle)
	}
	if library.path != "" {
		delete(library.path, library.allocator)
	}
	library^ = {}
}

library_factory :: proc(library: ^Library) -> ^clap.Plugin_Factory {
	if library == nil || library.entry == nil {
		return nil
	}
	return cast(^clap.Plugin_Factory)library.entry.get_factory(
		cstring(clap.CLAP_PLUGIN_FACTORY_ID),
	)
}

library_plugin_count :: proc(library: ^Library) -> u32 {
	factory := library_factory(library)
	if factory == nil || factory.get_plugin_count == nil {
		return 0
	}
	return factory.get_plugin_count(factory)
}

library_descriptor :: proc(library: ^Library, index: u32) -> ^clap.Plugin_Descriptor {
	factory := library_factory(library)
	if factory == nil || factory.get_plugin_descriptor == nil {
		return nil
	}
	return factory.get_plugin_descriptor(factory, index)
}

// ---------------------------------------------------------------------------
// Host extensions
// ---------------------------------------------------------------------------

Host_Context :: struct {
	host:              clap.Host,
	main_thread:       int,
	audio_thread:      int,
	audio_active:      bool,
	param_rescans:     u64,
	restart_requests:  u64,
	process_requests:  u64,
	callback_requests: u64,
}

host_is_main_thread :: proc "c" (host: ^clap.Host) -> bool {
	ctx := cast(^Host_Context)host.host_data
	return ctx != nil && sync.current_thread_id() == ctx.main_thread
}

host_is_audio_thread :: proc "c" (host: ^clap.Host) -> bool {
	ctx := cast(^Host_Context)host.host_data
	return ctx != nil && ctx.audio_active && sync.current_thread_id() == ctx.audio_thread
}

host_params_rescan :: proc "c" (host: ^clap.Host, flags: u32) {
	_ = flags
	ctx := cast(^Host_Context)host.host_data
	if ctx != nil {
		ctx.param_rescans += 1
	}
}

host_params_clear :: proc "c" (host: ^clap.Host, param_id: u32, flags: u32) {
	_ = host
	_ = param_id
	_ = flags
}

host_params_request_flush :: proc "c" (host: ^clap.Host) {}

host_audio_ports_is_rescan_flag_supported :: proc "c" (host: ^clap.Host, flag: u32) -> bool {
	_ = host
	_ = flag
	return false
}

host_audio_ports_rescan :: proc "c" (host: ^clap.Host, flags: u32) {
	_ = host
	_ = flags
}

host_tail_changed :: proc "c" (host: ^clap.Host) {}

host_latency_changed :: proc "c" (host: ^clap.Host) {}

host_state_mark_dirty :: proc "c" (host: ^clap.Host) {}

host_request_restart :: proc "c" (host: ^clap.Host) {
	ctx := cast(^Host_Context)host.host_data
	if ctx != nil {
		ctx.restart_requests += 1
	}
}

host_request_process :: proc "c" (host: ^clap.Host) {
	ctx := cast(^Host_Context)host.host_data
	if ctx != nil {
		ctx.process_requests += 1
	}
}

host_request_callback :: proc "c" (host: ^clap.Host) {
	ctx := cast(^Host_Context)host.host_data
	if ctx != nil {
		ctx.callback_requests += 1
	}
}

host_thread_check: clap.Host_Thread_Check = {
	is_main_thread = host_is_main_thread,
	is_audio_thread = host_is_audio_thread,
}

host_params_ext: clap.Host_Params = {
	rescan = host_params_rescan,
	clear = host_params_clear,
	request_flush = host_params_request_flush,
}

host_audio_ports_ext: clap.Host_Audio_Ports = {
	is_rescan_flag_supported = host_audio_ports_is_rescan_flag_supported,
	rescan = host_audio_ports_rescan,
}

host_tail_ext: clap.Host_Tail = {changed = host_tail_changed}
host_latency_ext: clap.Host_Latency = {changed = host_latency_changed}
host_state_ext: clap.Host_State = {mark_dirty = host_state_mark_dirty}

host_get_extension :: proc "c" (host: ^clap.Host, extension_id: cstring) -> rawptr {
	if host == nil || extension_id == nil {
		return nil
	}
	switch string(extension_id) {
	case clap.CLAP_EXT_THREAD_CHECK: return &host_thread_check
	case clap.CLAP_EXT_PARAMS:      return &host_params_ext
	case clap.CLAP_EXT_AUDIO_PORTS: return &host_audio_ports_ext
	case clap.CLAP_EXT_TAIL:        return &host_tail_ext
	case clap.CLAP_EXT_LATENCY:     return &host_latency_ext
	case clap.CLAP_EXT_STATE:       return &host_state_ext
	}
	return nil
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

MAX_PROCESS_EVENTS :: 256

Event_List :: struct {
	params:    []clap.Event_Param_Value,
	transport: ^clap.Event_Transport,
}

event_list_size :: proc "c" (list: ^clap.Input_Events) -> u32 {
	events := cast(^Event_List)list.ctx
	if events == nil {
		return 0
	}
	count := u32(len(events.params))
	if events.transport != nil {
		count += 1
	}
	return count
}

// host_output_try_push is the host's output-event sink. The laboratory does
// not consume plugin output events; returning false is the honest answer and
// keeps the plugin from assuming the event was stored.
host_output_try_push :: proc "c" (list: ^clap.Output_Events, event: ^clap.Event_Header) -> bool {
	_ = list
	_ = event
	return false
}

event_list_get :: proc "c" (list: ^clap.Input_Events, index: u32) -> ^clap.Event_Header {
	events := cast(^Event_List)list.ctx
	if events == nil {
		return nil
	}
	position := index
	if events.transport != nil {
		if position == 0 {
			return &events.transport.header
		}
		position -= 1
	}
	if int(position) >= len(events.params) {
		return nil
	}
	return &events.params[position].header
}

// ---------------------------------------------------------------------------
// Instance
// ---------------------------------------------------------------------------

Param_Info_Host :: struct {
	id:       u32,
	name:     string,
	module:   string,
	min:      f64,
	max:      f64,
	default:  f64,
	flags:    u32,
	is_stepped: bool,
}

Instance :: struct {
	allocator:   mem.Allocator,
	library:     ^Library,
	plugin:      ^clap.Plugin,
	descriptor:  ^clap.Plugin_Descriptor,
	ctx:         Host_Context,

	active:      bool,
	processing:  bool,
	sample_rate: f64,
	min_frames:  u32,
	max_frames:  u32,
	channels:    int,

	input_buffers:  [MAX_HOST_CHANNELS][]f32,
	output_buffers: [MAX_HOST_CHANNELS][]f32,
	audio_inputs:   [1]clap.Audio_Buffer,
	audio_outputs:  [1]clap.Audio_Buffer,
	in_ptrs:        [MAX_HOST_CHANNELS]^f32,
	out_ptrs:       [MAX_HOST_CHANNELS]^f32,

	event_storage: [MAX_PROCESS_EVENTS]clap.Event_Param_Value,
	event_list:    Event_List,
	in_events:     clap.Input_Events,
	out_events:    clap.Output_Events,

	params:      [64]Param_Info_Host,
	param_count: int,

	audio_ports: ^clap.Plugin_Audio_Ports,
	params_ext:  ^clap.Plugin_Params,
	state_ext:   ^clap.Plugin_State,
	latency:     ^clap.Plugin_Latency,
	tail:        ^clap.Plugin_Tail,
	telemetry:   ^clap.Carnival_Telemetry_Capture,

	process_calls: u64,
}

instance_create :: proc(
	library: ^Library,
	plugin_id: string,
	max_frames: u32,
	allocator := context.allocator,
) -> (^Instance, bool) {
	if library == nil || !library.loaded {
		return nil, false
	}
	factory := library_factory(library)
	if factory == nil || factory.create_plugin == nil {
		return nil, false
	}
	instance := new(Instance, allocator)
	if instance == nil {
		return nil, false
	}
	instance.allocator = allocator
	instance.library = library
	instance.max_frames = max_frames
	instance.min_frames = 1
	instance.channels = MAX_HOST_CHANNELS
	instance.ctx.main_thread = sync.current_thread_id()
	instance.ctx.host = clap.Host{
		clap_version = clap.CLAP_VERSION,
		host_data = &instance.ctx,
		name = "Carnival verification host",
		vendor = "Carnival Science",
		url = "https://carnival.science/",
		version = "0.1.0",
		get_extension = host_get_extension,
		request_restart = host_request_restart,
		request_process = host_request_process,
		request_callback = host_request_callback,
	}
	id_c := strings.clone_to_cstring(plugin_id, allocator)
	defer delete(id_c, allocator)
	plugin := factory.create_plugin(factory, &instance.ctx.host, id_c)
	if plugin == nil {
		free(instance, allocator)
		return nil, false
	}
	instance.plugin = plugin
	instance.descriptor = plugin.desc
	instance.audio_ports = cast(^clap.Plugin_Audio_Ports)plugin.get_extension(
		plugin,
		cstring(clap.CLAP_EXT_AUDIO_PORTS),
	)
	instance.params_ext = cast(^clap.Plugin_Params)plugin.get_extension(
		plugin,
		cstring(clap.CLAP_EXT_PARAMS),
	)
	instance.state_ext = cast(^clap.Plugin_State)plugin.get_extension(
		plugin,
		cstring(clap.CLAP_EXT_STATE),
	)
	instance.latency = cast(^clap.Plugin_Latency)plugin.get_extension(
		plugin,
		cstring(clap.CLAP_EXT_LATENCY),
	)
	instance.tail = cast(^clap.Plugin_Tail)plugin.get_extension(
		plugin,
		cstring(clap.CLAP_EXT_TAIL),
	)
	instance.telemetry = cast(^clap.Carnival_Telemetry_Capture)plugin.get_extension(
		plugin,
		cstring(clap.CARNIVAL_EXT_TELEMETRY_CAPTURE_DRAFT),
	)

	// Allocate planar scratch buffers once. The process path only writes into
	// these; it never allocates.
	for channel in 0 ..< instance.channels {
		input, input_err := mem.alloc_bytes(int(max_frames) * size_of(f32), align_of(f32), allocator)
		output, output_err := mem.alloc_bytes(int(max_frames) * size_of(f32), align_of(f32), allocator)
		if input_err != .None || output_err != .None || input == nil || output == nil {
			instance_destroy(instance)
			return nil, false
		}
		instance.input_buffers[channel] = mem.slice_data_cast([]f32, input)
		instance.output_buffers[channel] = mem.slice_data_cast([]f32, output)
	}
	instance_scan_params(instance)
	return instance, true
}

instance_scan_params :: proc(instance: ^Instance) {
	instance.param_count = 0
	if instance.params_ext == nil || instance.params_ext.count == nil ||
		instance.params_ext.get_info == nil {
		return
	}
	count := instance.params_ext.count(instance.plugin)
	for index in 0 ..< count {
		if instance.param_count >= len(instance.params) {
			break
		}
		info: clap.Param_Info
		if !instance.params_ext.get_info(instance.plugin, index, &info) {
			continue
		}
		entry := &instance.params[instance.param_count]
		entry.id = info.id
		entry.name = strings.clone(string(cstring(&info.name[0])), instance.allocator)
		entry.module = strings.clone(string(cstring(&info.module[0])), instance.allocator)
		entry.min = info.min_value
		entry.max = info.max_value
		entry.default = info.default_value
		entry.flags = info.flags
		entry.is_stepped = info.flags & clap.CLAP_PARAM_IS_STEPPED != 0
		instance.param_count += 1
	}
}

instance_param_index :: proc(instance: ^Instance, id: u32) -> int {
	for index in 0 ..< instance.param_count {
		if instance.params[index].id == id {
			return index
		}
	}
	return -1
}

instance_destroy :: proc(instance: ^Instance) {
	if instance == nil {
		return
	}
	if instance.plugin != nil {
		if instance.processing {
			instance.plugin.stop_processing(instance.plugin)
		}
		if instance.active {
			instance.plugin.deactivate(instance.plugin)
		}
		instance.plugin.destroy(instance.plugin)
	}
	for channel in 0 ..< instance.channels {
		if instance.input_buffers[channel] != nil {
			mem.free(raw_data(instance.input_buffers[channel]), instance.allocator)
		}
		if instance.output_buffers[channel] != nil {
			mem.free(raw_data(instance.output_buffers[channel]), instance.allocator)
		}
	}
	for index in 0 ..< instance.param_count {
		delete(instance.params[index].name, instance.allocator)
		delete(instance.params[index].module, instance.allocator)
	}
	free(instance, instance.allocator)
}

instance_init :: proc(instance: ^Instance) -> bool {
	if instance == nil || instance.plugin == nil || instance.plugin.init == nil {
		return false
	}
	return instance.plugin.init(instance.plugin)
}

instance_activate :: proc(instance: ^Instance, sample_rate: f64, min_frames, max_frames: u32) -> bool {
	if instance == nil || instance.plugin == nil || instance.plugin.activate == nil {
		return false
	}
	if max_frames > instance.max_frames || min_frames < 1 || max_frames < min_frames {
		return false
	}
	if !instance.plugin.activate(instance.plugin, sample_rate, min_frames, max_frames) {
		return false
	}
	instance.active = true
	instance.sample_rate = sample_rate
	instance.min_frames = min_frames
	instance.max_frames = max_frames
	return true
}

instance_start :: proc(instance: ^Instance) -> bool {
	if instance == nil || !instance.active || instance.plugin == nil || instance.plugin.start_processing == nil {
		return false
	}
	if !instance.plugin.start_processing(instance.plugin) {
		return false
	}
	instance.processing = true
	return true
}

instance_stop :: proc(instance: ^Instance) {
	if instance == nil || !instance.processing || instance.plugin == nil {
		return
	}
	instance.plugin.stop_processing(instance.plugin)
	instance.processing = false
}

instance_deactivate :: proc(instance: ^Instance) {
	if instance == nil || !instance.active || instance.plugin == nil {
		return
	}
	instance_stop(instance)
	instance.plugin.deactivate(instance.plugin)
	instance.active = false
}

instance_reset :: proc(instance: ^Instance) {
	if instance != nil && instance.plugin != nil && instance.plugin.reset != nil {
		instance.plugin.reset(instance.plugin)
	}
}

// instance_process feeds one block. Input/output are planar slices of frames.
// `events` are parameter events with a sample offset in `header.time`; they are
// copied into host storage, sorted stably by time, and presented through the
// CLAP input-event list. A transport event is optional.
instance_process :: proc(
	instance: ^Instance,
	frames: u32,
	input: [][]f32,
	output: [][]f32,
	steady_time: i64 = 0,
	events: []clap.Event_Param_Value = nil,
	transport: ^clap.Event_Transport = nil,
) -> (clap.Process_Status, bool) {
	if instance == nil || instance.plugin == nil || instance.plugin.process == nil {
		return clap.CLAP_PROCESS_ERROR, false
	}
	if frames == 0 || frames > instance.max_frames {
		return clap.CLAP_PROCESS_ERROR, false
	}
	if len(input) < instance.channels || len(output) < instance.channels {
		return clap.CLAP_PROCESS_ERROR, false
	}
	for channel in 0 ..< instance.channels {
		if len(input[channel]) < int(frames) || len(output[channel]) < int(frames) {
			return clap.CLAP_PROCESS_ERROR, false
		}
		instance.in_ptrs[channel] = cast(^f32)raw_data(input[channel])
		instance.out_ptrs[channel] = cast(^f32)raw_data(output[channel])
	}
	instance.audio_inputs[0] = clap.Audio_Buffer{
		data32 = &instance.in_ptrs[0],
		channel_count = u32(instance.channels),
	}
	instance.audio_outputs[0] = clap.Audio_Buffer{
		data32 = &instance.out_ptrs[0],
		channel_count = u32(instance.channels),
	}
	process := clap.Process{
		steady_time = steady_time,
		frames_count = frames,
		audio_inputs = &instance.audio_inputs[0],
		audio_outputs = &instance.audio_outputs[0],
		audio_inputs_count = 1,
		audio_outputs_count = 1,
	}
	event_count := min(len(events), len(instance.event_storage))
	if event_count > 0 {
		copy(instance.event_storage[:event_count], events[:event_count])
		// Stable insertion sort by sample offset. CLAP requires time order.
		for index in 1 ..< event_count {
			current := instance.event_storage[index]
			position := index
			for position > 0 && instance.event_storage[position - 1].header.time > current.header.time {
				instance.event_storage[position] = instance.event_storage[position - 1]
				position -= 1
			}
			instance.event_storage[position] = current
		}
	}
	instance.event_list.params = instance.event_storage[:event_count]
	instance.event_list.transport = transport
	// Always present non-nil event lists. CLAP permits a host to pass null when
	// there are no events, but some plugins dereference in_events/out_events
	// unconditionally; an empty list is the compatible choice.
	instance.in_events = clap.Input_Events{
		ctx = &instance.event_list,
		size = event_list_size,
		get = event_list_get,
	}
	process.in_events = &instance.in_events
	instance.out_events = clap.Output_Events{
		ctx = &instance.event_list,
		try_push = host_output_try_push,
	}
	process.out_events = &instance.out_events

	instance.ctx.audio_thread = sync.current_thread_id()
	instance.ctx.audio_active = true
	status := instance.plugin.process(instance.plugin, &process)
	instance.ctx.audio_active = false
	instance.process_calls += 1
	return status, true
}

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

instance_get_param :: proc(instance: ^Instance, id: u32) -> (f64, bool) {
	if instance == nil || instance.params_ext == nil || instance.params_ext.get_value == nil {
		return 0, false
	}
	value: f64
	if !instance.params_ext.get_value(instance.plugin, id, &value) {
		return 0, false
	}
	return value, true
}

instance_set_param :: proc(instance: ^Instance, id: u32, value: f64) -> bool {
	if instance == nil || instance.params_ext == nil || instance.params_ext.flush == nil {
		return false
	}
	event := clap.Event_Param_Value{
		header = clap.Event_Header{
			size = u32(size_of(clap.Event_Param_Value)),
			time = 0,
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
	storage: [1]clap.Event_Param_Value
	storage[0] = event
	events := Event_List{params = storage[:]}
	input := clap.Input_Events{ctx = &events, size = event_list_size, get = event_list_get}
	instance.params_ext.flush(instance.plugin, &input, nil)
	return true
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

State_Stream :: struct {
	data:    [dynamic]u8,
	read_at: int,
}

state_write :: proc "c" (stream: ^clap.OStream, buffer: rawptr, size: u64) -> i64 {
	context = runtime.default_context()
	state := cast(^State_Stream)stream.ctx
	if state == nil {
		return -1
	}
	bytes := ([^]u8)(buffer)[:int(size)]
	append(&state.data, ..bytes)
	return i64(size)
}

state_read :: proc "c" (stream: ^clap.IStream, buffer: rawptr, size: u64) -> i64 {
	state := cast(^State_Stream)stream.ctx
	if state == nil {
		return -1
	}
	available := len(state.data) - state.read_at
	count := min(int(size), available)
	if count <= 0 {
		return 0
	}
	copy(([^]u8)(buffer)[:count], state.data[state.read_at:state.read_at + count])
	state.read_at += count
	return i64(count)
}

// instance_save_state returns a freshly allocated state blob. The caller owns
// the slice (allocated with `allocator`).
instance_save_state :: proc(instance: ^Instance, allocator := context.allocator) -> ([]u8, bool) {
	if instance == nil || instance.state_ext == nil || instance.state_ext.save == nil {
		return nil, false
	}
	stream := State_Stream{data = make([dynamic]u8, 0, 4096, allocator)}
	ostream := clap.OStream{ctx = &stream, write = state_write}
	if !instance.state_ext.save(instance.plugin, &ostream) {
		delete(stream.data)
		return nil, false
	}
	bytes := make([]u8, len(stream.data), allocator)
	copy(bytes, stream.data[:])
	delete(stream.data)
	return bytes, true
}

instance_load_state :: proc(instance: ^Instance, bytes: []u8) -> bool {
	if instance == nil || instance.state_ext == nil || instance.state_ext.load == nil {
		return false
	}
	stream := State_Stream{data = make([dynamic]u8, 0, len(bytes))}
	defer delete(stream.data)
	append(&stream.data, ..bytes)
	istream := clap.IStream{ctx = &stream, read = state_read}
	return instance.state_ext.load(instance.plugin, &istream)
}

instance_latency_frames :: proc(instance: ^Instance) -> u32 {
	if instance == nil || instance.latency == nil || instance.latency.get == nil {
		return 0
	}
	return instance.latency.get(instance.plugin)
}

instance_tail_frames :: proc(instance: ^Instance) -> u32 {
	if instance == nil || instance.tail == nil || instance.tail.get == nil {
		return 0
	}
	return instance.tail.get(instance.plugin)
}

// ---------------------------------------------------------------------------
// Draft telemetry capture
// ---------------------------------------------------------------------------

instance_has_telemetry :: proc(instance: ^Instance) -> bool {
	return instance != nil && instance.telemetry != nil
}

instance_capture_enable :: proc(instance: ^Instance, enabled: bool) -> bool {
	if instance == nil || instance.telemetry == nil || instance.telemetry.set_enabled == nil {
		return false
	}
	return instance.telemetry.set_enabled(instance.plugin, enabled)
}

instance_capture_valid :: proc(instance: ^Instance) -> bool {
	if instance == nil || instance.telemetry == nil || instance.telemetry.valid == nil {
		return true
	}
	return instance.telemetry.valid(instance.plugin)
}

instance_capture_dropped :: proc(instance: ^Instance) -> u64 {
	if instance == nil || instance.telemetry == nil || instance.telemetry.dropped == nil {
		return 0
	}
	return instance.telemetry.dropped(instance.plugin)
}

instance_capture_schema_version :: proc(instance: ^Instance) -> u32 {
	if instance == nil || instance.telemetry == nil || instance.telemetry.schema_version == nil {
		return 0
	}
	return instance.telemetry.schema_version(instance.plugin)
}

Capture_Collector :: struct {
	records: [dynamic]clap.Carnival_Measurement_Record,
}

capture_push :: proc "c" (ctx: rawptr, record: ^clap.Carnival_Measurement_Record) -> bool {
	context = runtime.default_context()
	collector := cast(^Capture_Collector)ctx
	if collector == nil || record == nil {
		return false
	}
	append(&collector.records, record^)
	return true
}

// instance_capture_drain appends every pending record to `collector`. The
// collector owns its dynamic array; call delete(collector.records) when done.
instance_capture_drain :: proc(instance: ^Instance, collector: ^Capture_Collector) -> u32 {
	if instance == nil || instance.telemetry == nil || instance.telemetry.drain == nil {
		return 0
	}
	sink := clap.Carnival_Capture_Sink{ctx = collector, push = capture_push}
	return instance.telemetry.drain(instance.plugin, sink, 0)
}

// instance_capture_drain_one drains at most `max_records` records and returns
// the delivered count.
instance_capture_drain_max :: proc(
	instance: ^Instance,
	collector: ^Capture_Collector,
	max_records: u32,
) -> u32 {
	if instance == nil || instance.telemetry == nil || instance.telemetry.drain == nil {
		return 0
	}
	sink := clap.Carnival_Capture_Sink{ctx = collector, push = capture_push}
	return instance.telemetry.drain(instance.plugin, sink, max_records)
}

// instance_on_main_thread reports the host's own thread-check view. Tests use it
// to assert that the extension's main-thread contract is observable.
instance_on_main_thread :: proc(instance: ^Instance) -> bool {
	return instance != nil && sync.current_thread_id() == instance.ctx.main_thread
}

