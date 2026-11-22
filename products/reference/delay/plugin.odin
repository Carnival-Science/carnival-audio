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
// Processing state (write cursor and both delay lines) is exposed through the
// separate draft processing-checkpoint capability, not clap.state. A checkpoint
// resumes the exact delay tail; authoring state (schema 3) only reopens the
// parameters.
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

// ---------------------------------------------------------------------------
// Processing checkpoint (draft extension; separate from clap.state)
//
// Payload: magic "CSDLCK01" | u32 version | u32 write_index |
//          CHANNELS * DELAY_MAX_FRAMES f32 bit patterns (little-endian).
// ---------------------------------------------------------------------------

CHECKPOINT_MAGIC: [8]u8 = {'C', 'S', 'D', 'L', 'C', 'K', '0', '1'}
CHECKPOINT_VERSION :: u32(1)
CHECKPOINT_SAMPLES :: CHANNELS * DELAY_MAX_FRAMES

checkpoint_save :: proc(data: rawptr, stream: ^clap.OStream) -> bool {
	state := cast(^State)data
	if state == nil || stream == nil || stream.write == nil {
		return false
	}
	header: [16]u8
	copy(header[:8], CHECKPOINT_MAGIC[:])
	put_u32(header[:], 8, CHECKPOINT_VERSION)
	put_u32(header[:], 12, u32(state.write_index))
	if !write_all(stream, header[:]) {
		return false
	}
	bits: [CHECKPOINT_SAMPLES]u32
	position := 0
	for channel in 0 ..< CHANNELS {
		for frame in 0 ..< DELAY_MAX_FRAMES {
			bits[position] = transmute(u32)state.lines[channel][frame]
			position += 1
		}
	}
	return write_all(stream, ([^]u8)(&bits[0])[:CHECKPOINT_SAMPLES * 4])
}

checkpoint_load :: proc(data: rawptr, stream: ^clap.IStream) -> bool {
	state := cast(^State)data
	if state == nil || stream == nil || stream.read == nil {
		return false
	}
	header: [16]u8
	if !read_all(stream, header[:]) {
		return false
	}
	for index in 0 ..< 8 {
		if header[index] != CHECKPOINT_MAGIC[index] {
			return false
		}
	}
	if get_u32(header[:], 8) != CHECKPOINT_VERSION {
		return false
	}
	write_index := int(get_u32(header[:], 12))
	if write_index < 0 || write_index >= DELAY_MAX_FRAMES {
		return false
	}
	// Read into a temporary so a truncated payload leaves the live delay line
	// untouched (all-or-nothing restore).
	bits: [CHECKPOINT_SAMPLES]u32
	if !read_all(stream, ([^]u8)(&bits[0])[:CHECKPOINT_SAMPLES * 4]) {
		return false
	}
	position := 0
	for channel in 0 ..< CHANNELS {
		for frame in 0 ..< DELAY_MAX_FRAMES {
			state.lines[channel][frame] = transmute(f32)bits[position]
			position += 1
		}
	}
	state.write_index = write_index
	return true
}

checkpoint_ops: adapter.Checkpoint_Ops = {
	save = checkpoint_save,
	load = checkpoint_load,
}

write_all :: proc(stream: ^clap.OStream, bytes: []u8) -> bool {
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

read_all :: proc(stream: ^clap.IStream, bytes: []u8) -> bool {
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
	state_schema = 3,
	checkpoint = &checkpoint_ops,
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