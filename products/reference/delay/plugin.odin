// Reference processor: feedback delay with a preallocated delay line.
//
// Persistent temporal dependency is the point: the output at frame n depends
// on earlier samples through a per-channel delay line and feedback. The delay
// line is allocated at activation and never reallocated in process.
//
// The per-sample order is fixed, so constant-parameter processing is partition
// invariant: the same absolute sample performs the same f32 read, write,
// multiply and add regardless of host block boundaries.
//
// Processing state (write cursor and both delay lines) is included in the
// schema-4 state blob, so a save/load restore continues the same tail.
package reference_delay

import "base:runtime"

import adapter "carnival:adapters/clap"
import clap "carnival:third_party/clap/abi"

PLUGIN_ID :: "com.carnival-science.reference.delay"
PLUGIN_VERSION :: "0.1.0"

CHANNELS :: 2
DELAY_MAX_FRAMES :: 4096

PARAM_DELAY_FRAMES :: u32(2201)
PARAM_FEEDBACK :: u32(2202)
PARAM_MIX :: u32(2203)

State :: struct {
	lines: [CHANNELS][DELAY_MAX_FRAMES]f32,
	write_index: int,
	delay_frames: int,
}

features: [3]cstring = {
	clap.CLAP_PLUGIN_FEATURE_AUDIO_EFFECT,
	clap.CLAP_PLUGIN_FEATURE_STEREO,
	nil,
}

descriptor: clap.Plugin_Descriptor = {
	clap_version = clap.CLAP_VERSION,
	id = PLUGIN_ID,
	name = "Reference Delay",
	vendor = "Carnival Science",
	url = "https://carnival.science/",
	version = PLUGIN_VERSION,
	description = "Feedback delay reference for tail and state fixtures",
	features = &features[0],
}

params: [3]adapter.Param_Descriptor = {
	{
		id = PARAM_DELAY_FRAMES,
		name = "Delay Frames",
		module = "Delay",
		flags = clap.CLAP_PARAM_IS_AUTOMATABLE | clap.CLAP_PARAM_IS_STEPPED,
		min = 1,
		max = DELAY_MAX_FRAMES - 1,
		default = 1000,
		format = .Integer,
		stepped = true,
	},
	{
		id = PARAM_FEEDBACK,
		name = "Feedback",
		module = "Delay",
		flags = clap.CLAP_PARAM_IS_AUTOMATABLE,
		min = 0,
		max = 0.95,
		default = 0.5,
		format = .Decimal,
	},
	{
		id = PARAM_MIX,
		name = "Mix",
		module = "Delay",
		flags = clap.CLAP_PARAM_IS_AUTOMATABLE,
		min = 0,
		max = 1,
		default = 1,
		format = .Decimal,
	},
}

create :: proc() -> rawptr {
	return new(State)
}

destroy :: proc(data: rawptr) {
	if data != nil {
		free(cast(^State)data)
	}
}

activate :: proc(data: rawptr, config: adapter.Activation_Config) -> bool {
	state := cast(^State)data
	if state == nil || config.sample_rate <= 0 {
		return false
	}
	reset(data)
	return true
}

reset :: proc(data: rawptr) {
	state := cast(^State)data
	if state == nil {
		return
	}
	for channel in 0 ..< CHANNELS {
		for frame in 0 ..< DELAY_MAX_FRAMES {
			state.lines[channel][frame] = 0
		}
	}
	state.write_index = 0
}

process :: proc(data: rawptr, request: ^adapter.Process_Request) -> adapter.Process_Result {
	state := cast(^State)data
	if state == nil || request == nil || len(request.params) < 3 || request.channels != CHANNELS {
		return .Error
	}
	delay := clamp(int(request.params[0]), 1, DELAY_MAX_FRAMES - 1)
	state.delay_frames = delay
	feedback := f32(request.params[1])
	mix := f32(request.params[2])
	inputs: [CHANNELS][^]f32
	outputs: [CHANNELS][^]f32
	for channel in 0 ..< CHANNELS {
		inputs[channel] = cast([^]f32)request.input[channel]
		outputs[channel] = cast([^]f32)request.output[channel]
	}
	write := state.write_index
	for frame in 0 ..< int(request.frames) {
		read := write - delay
		if read < 0 {
			read += DELAY_MAX_FRAMES
		}
		for channel in 0 ..< CHANNELS {
			x := inputs[channel][frame]
			delayed := state.lines[channel][read]
			state.lines[channel][write] = x + feedback * delayed
			outputs[channel][frame] = x + mix * (delayed - x)
		}
		write += 1
		if write >= DELAY_MAX_FRAMES {
			write = 0
		}
	}
	state.write_index = write
	return .Continue
}

state_blob_size :: proc(data: rawptr) -> u32 {
	_ = data
	return u32(4 + CHANNELS * DELAY_MAX_FRAMES * 4)
}

state_blob_save :: proc(data: rawptr, stream: ^clap.OStream) -> bool {
	state := cast(^State)data
	if state == nil || stream == nil || stream.write == nil {
		return false
	}
	index_bytes: [4]u8
	put_u32(index_bytes[:], 0, u32(state.write_index))
	if stream.write(stream, &index_bytes[0], 4) != 4 {
		return false
	}
	for channel in 0 ..< CHANNELS {
		bits: [DELAY_MAX_FRAMES]u32
		for frame in 0 ..< DELAY_MAX_FRAMES {
			bits[frame] = transmute(u32)state.lines[channel][frame]
		}
		if stream.write(stream, &bits[0], u64(len(bits) * 4)) != i64(len(bits) * 4) {
			return false
		}
	}
	return true
}

state_blob_load :: proc(data: rawptr, bytes: []u8) -> bool {
	state := cast(^State)data
	if state == nil || len(bytes) != 4 + CHANNELS * DELAY_MAX_FRAMES * 4 {
		return false
	}
	state.write_index = int(get_u32(bytes, 0))
	if state.write_index < 0 || state.write_index >= DELAY_MAX_FRAMES {
		return false
	}
	offset := 4
	for channel in 0 ..< CHANNELS {
		for frame in 0 ..< DELAY_MAX_FRAMES {
			bits := get_u32(bytes, offset)
			state.lines[channel][frame] = transmute(f32)bits
			offset += 4
		}
	}
	return true
}

tail_frames :: proc(data: rawptr) -> u32 {
	state := cast(^State)data
	if state == nil {
		return 0
	}
	// Bounded declarative hint, not a guarantee: 20 delay periods is the point
	// where 0.5 feedback is below one f32 lsb of the reference amplitude.
	return u32(max(state.delay_frames, 1) * 20)
}

put_u32 :: proc(buffer: []u8, offset: int, value: u32) {
	buffer[offset + 0] = u8(value)
	buffer[offset + 1] = u8(value >> 8)
	buffer[offset + 2] = u8(value >> 16)
	buffer[offset + 3] = u8(value >> 24)
}

get_u32 :: proc(buffer: []u8, offset: int) -> u32 {
	return u32(buffer[offset]) |
		u32(buffer[offset + 1]) << 8 |
		u32(buffer[offset + 2]) << 16 |
		u32(buffer[offset + 3]) << 24
}

backend: adapter.Backend_VTable = {
	create = create,
	destroy = destroy,
	activate = activate,
	reset = reset,
	process = process,
}

definition: adapter.Definition = {
	descriptor = &descriptor,
	backend = &backend,
	params = params[:],
	input_port_id = 1,
	output_port_id = 2,
	input_port_name = "Input",
	output_port_name = "Output",
	state_magic = {'C', 'S', 'D', 'L', 'A', 'Y', '0', '1'},
	state_schema = 4,
	state_blob_size = state_blob_size,
	state_blob_save = state_blob_save,
	state_blob_load = state_blob_load,
	tail_frames = tail_frames,
}

// ---------------------------------------------------------------------------
// Exported CLAP entry (one plugin per DSO)
// ---------------------------------------------------------------------------

entry_init :: proc "c" (plugin_path: cstring) -> bool {
	context = runtime.default_context()
	adapter.register_definition(&definition)
	return adapter.entry_init(plugin_path)
}

entry_deinit :: proc "c" () {
	context = runtime.default_context()
	adapter.entry_deinit()
}

entry_get_factory :: proc "c" (factory_id: cstring) -> rawptr {
	context = runtime.default_context()
	return adapter.entry_get_factory(factory_id)
}

@(export)
clap_entry: clap.Entry = {
	clap_version = clap.CLAP_VERSION,
	init = entry_init,
	deinit = entry_deinit,
	get_factory = entry_get_factory,
}