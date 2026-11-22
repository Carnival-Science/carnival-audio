// DEFECTIVE reference processor: feedback delay whose save omits its delay line.
//
// The DSP is the same shape as the good delay reference, but the authoring
// state schema is 3 and there are no processing-state blob hooks. A host that
// saves, tears down and restores the plugin gets its parameters back and a
// zeroed delay line. Output after the restore therefore diverges from an
// uninterrupted run: the laboratory's state-restoration probe MUST flag it.
//
// This proves the probe detects a real omitted-state defect without claiming
// that every host must serialize processing state.
package reference_leaky_delay

import "base:runtime"

import adapter "carnival:adapters/clap"
import clap "carnival:third_party/clap/abi"

PLUGIN_ID :: "com.carnival-science.reference.leaky-delay"
PLUGIN_VERSION :: "0.1.0"

CHANNELS :: 2
DELAY_MAX_FRAMES :: 4096

PARAM_DELAY_FRAMES :: u32(2401)
PARAM_FEEDBACK :: u32(2402)
PARAM_MIX :: u32(2403)

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
	name = "Defective Leaky Delay",
	vendor = "Carnival Science",
	url = "https://carnival.science/",
	version = PLUGIN_VERSION,
	description = "Delay that omits its line from saved state (test fixture)",
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
		default = 64,
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
	if data == nil || config.sample_rate <= 0 {
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

tail_frames :: proc(data: rawptr) -> u32 {
	state := cast(^State)data
	if state == nil {
		return 0
	}
	return u32(max(state.delay_frames, 1) * 20)
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
	state_magic = {'C', 'S', 'L', 'E', 'A', 'K', '0', '1'},
	state_schema = 3,
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