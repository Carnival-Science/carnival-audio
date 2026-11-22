// Reference processor: deterministic two-channel biquad low-pass.
//
// Coefficients follow the Audio EQ Cookbook RBJ low-pass form, computed in f64
// from the cutoff and Q parameters, once per block when the parameters change.
// The filter is direct form I, per channel:
//
//   y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]
//
// The sample loop uses one fixed order of f64 operations, so the result is
// partition invariant for constant parameters: the same absolute sample sees
// the same arithmetic regardless of how blocks are cut. Parameter automation
// is control-rate (coefficients update at block boundaries), which is a
// distinct class from static partition invariance.
//
// Processing state (x1,x2,y1,y2 per channel) is a **processing checkpoint**,
// not authoring state: it resumes the sample-exact filter at the saved
// position. It is exposed through the separate draft
// com.carnival-science.processing-checkpoint.draft/1 capability; clap.state
// stays parameters-only (schema 3).
package reference_biquad

import "base:runtime"

import "core:math"

import adapter "carnival:adapters/clap"
import clap "carnival:third_party/clap/abi"

PLUGIN_ID :: "com.carnival-science.reference.biquad"
PLUGIN_VERSION :: "0.1.0"

PARAM_CUTOFF_HZ :: u32(2101)
PARAM_Q :: u32(2102)

CHANNELS :: 2

State :: struct {
	sample_rate: f64,
	cached_cutoff: f64,
	cached_q: f64,
	have_coefficients: bool,
	b0, b1, b2, a1, a2: f64,
	x1, x2, y1, y2: [CHANNELS]f64,
}

features: [3]cstring = {
	clap.CLAP_PLUGIN_FEATURE_AUDIO_EFFECT,
	clap.CLAP_PLUGIN_FEATURE_STEREO,
	nil,
}

descriptor: clap.Plugin_Descriptor = {
	clap_version = clap.CLAP_VERSION,
	id = PLUGIN_ID,
	name = "Reference Biquad",
	vendor = "Carnival Science",
	url = "https://carnival.science/",
	version = PLUGIN_VERSION,
	description = "Direct-form-I RBJ low-pass reference for verification fixtures",
	features = &features[0],
}

params: [2]adapter.Param_Descriptor = {
	{
		id = PARAM_CUTOFF_HZ,
		name = "Cutoff",
		module = "Filter",
		flags = clap.CLAP_PARAM_IS_AUTOMATABLE,
		min = 20,
		max = 20000,
		default = 1000,
		format = .Decimal,
	},
	{
		id = PARAM_Q,
		name = "Q",
		module = "Filter",
		flags = clap.CLAP_PARAM_IS_AUTOMATABLE,
		min = 0.1,
		max = 10,
		default = 0.7071067811865476,
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
	state.sample_rate = config.sample_rate
	state.have_coefficients = false
	reset(data)
	return true
}

reset :: proc(data: rawptr) {
	state := cast(^State)data
	if state == nil {
		return
	}
	state.x1 = {}
	state.x2 = {}
	state.y1 = {}
	state.y2 = {}
}

update_coefficients :: proc(state: ^State, cutoff: f64, q: f64) {
	if state.have_coefficients && state.cached_cutoff == cutoff && state.cached_q == q {
		return
	}
	frequency := clamp(cutoff, 10.0, state.sample_rate * 0.49)
	q_value := max(q, 0.001)
	w0 := math.TAU * frequency / state.sample_rate
	cos_w0 := math.cos(w0)
	sin_w0 := math.sin(w0)
	alpha := sin_w0 / (2.0 * q_value)
	b0 := (1.0 - cos_w0) * 0.5
	b1 := 1.0 - cos_w0
	b2 := b0
	a0 := 1.0 + alpha
	a1 := -2.0 * cos_w0
	a2 := 1.0 - alpha
	state.b0 = b0 / a0
	state.b1 = b1 / a0
	state.b2 = b2 / a0
	state.a1 = a1 / a0
	state.a2 = a2 / a0
	state.cached_cutoff = cutoff
	state.cached_q = q
	state.have_coefficients = true
}

process :: proc(data: rawptr, request: ^adapter.Process_Request) -> adapter.Process_Result {
	state := cast(^State)data
	if state == nil || request == nil || len(request.params) < 2 || request.channels != CHANNELS {
		return .Error
	}
	update_coefficients(state, request.params[0], request.params[1])
	for channel in 0 ..< CHANNELS {
		input := cast([^]f32)request.input[channel]
		output := cast([^]f32)request.output[channel]
		x1 := state.x1[channel]
		x2 := state.x2[channel]
		y1 := state.y1[channel]
		y2 := state.y2[channel]
		for frame in 0 ..< int(request.frames) {
			x := f64(input[frame])
			y := state.b0 * x + state.b1 * x1 + state.b2 * x2 - state.a1 * y1 - state.a2 * y2
			x2 = x1
			x1 = x
			y2 = y1
			y1 = y
			output[frame] = f32(y)
		}
		state.x1[channel] = x1
		state.x2[channel] = x2
		state.y1[channel] = y1
		state.y2[channel] = y2
	}
	return .Continue
}

// ---------------------------------------------------------------------------
// Processing checkpoint (draft extension; separate from clap.state)
//
// Payload: magic "CSBQCK01" | u32 version | 8 * f64 history words.
// ---------------------------------------------------------------------------

CHECKPOINT_MAGIC: [8]u8 = {'C', 'S', 'B', 'Q', 'C', 'K', '0', '1'}
CHECKPOINT_VERSION :: u32(1)
CHECKPOINT_HISTORY_WORDS :: 8

checkpoint_save :: proc(data: rawptr, stream: ^clap.OStream) -> bool {
	state := cast(^State)data
	if state == nil || stream == nil || stream.write == nil {
		return false
	}
	bytes: [8 + 4 + CHECKPOINT_HISTORY_WORDS * 8]u8
	copy(bytes[:8], CHECKPOINT_MAGIC[:])
	put_u32(bytes[:], 8, CHECKPOINT_VERSION)
	values := [CHECKPOINT_HISTORY_WORDS]f64{
		state.x1[0], state.x2[0], state.y1[0], state.y2[0],
		state.x1[1], state.x2[1], state.y1[1], state.y2[1],
	}
	for value, index in values {
		put_f64(bytes[:], 12 + index * 8, value)
	}
	return stream.write(stream, &bytes[0], u64(len(bytes))) == i64(len(bytes))
}

checkpoint_load :: proc(data: rawptr, stream: ^clap.IStream) -> bool {
	state := cast(^State)data
	if state == nil || stream == nil || stream.read == nil {
		return false
	}
	bytes: [8 + 4 + CHECKPOINT_HISTORY_WORDS * 8]u8
	if !read_all(stream, bytes[:]) {
		return false
	}
	for index in 0 ..< 8 {
		if bytes[index] != CHECKPOINT_MAGIC[index] {
			return false
		}
	}
	if get_u32(bytes[:], 8) != CHECKPOINT_VERSION {
		return false
	}
	values: [CHECKPOINT_HISTORY_WORDS]f64
	for index in 0 ..< CHECKPOINT_HISTORY_WORDS {
		values[index] = get_f64(bytes[:], 12 + index * 8)
	}
	// Commit only after the whole payload validated.
	state.x1[0] = values[0]
	state.x2[0] = values[1]
	state.y1[0] = values[2]
	state.y2[0] = values[3]
	state.x1[1] = values[4]
	state.x2[1] = values[5]
	state.y1[1] = values[6]
	state.y2[1] = values[7]
	return true
}

checkpoint_ops: adapter.Checkpoint_Ops = {
	save = checkpoint_save,
	load = checkpoint_load,
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

put_f64 :: proc(buffer: []u8, offset: int, value: f64) {
	bits := transmute(u64)value
	for index in 0 ..< 8 {
		buffer[offset + index] = u8(bits >> (8 * u64(index)))
	}
}

get_f64 :: proc(buffer: []u8, offset: int) -> f64 {
	bits: u64
	for index in 0 ..< 8 {
		bits |= u64(buffer[offset + index]) << (8 * u64(index))
	}
	return transmute(f64)bits
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
	state_magic = {'C', 'S', 'B', 'I', 'Q', 'U', 'A', '1'},
	state_schema = 3,
	checkpoint = &checkpoint_ops,
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