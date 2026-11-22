// DEFECTIVE reference processor: block-boundary-resetting one-pole smoother.
//
// This specimen exists to validate the laboratory, not to sound good. Its
// smoothing state is zeroed at the start of every process call:
//
//   state = 0
//   for each sample: state += coefficient * (x - state); out = state
//
// The same absolute input sample therefore produces different output depending
// on how the host cut the blocks. A correct block-partition invariance probe
// MUST flag this processor as non-invariant. The gain, biquad and delay
// references must still pass at their own invariance classes.
//
// Declared class: intentionally partition-sensitive control/state defect.
package reference_block_smoother

import "base:runtime"

import adapter "carnival:adapters/clap"
import clap "carnival:third_party/clap/abi"

PLUGIN_ID :: "com.carnival-science.reference.block-smoother"
PLUGIN_VERSION :: "0.1.0"

PARAM_COEFFICIENT :: u32(2301)

State :: struct {
	// Non-zero size: the adapter rejects a plugin whose create returns nil.
	dummy: u8,
}

features: [3]cstring = {
	clap.CLAP_PLUGIN_FEATURE_AUDIO_EFFECT,
	clap.CLAP_PLUGIN_FEATURE_STEREO,
	nil,
}

descriptor: clap.Plugin_Descriptor = {
	clap_version = clap.CLAP_VERSION,
	id = PLUGIN_ID,
	name = "Defective Block Smoother",
	vendor = "Carnival Science",
	url = "https://carnival.science/",
	version = PLUGIN_VERSION,
	description = "Intentionally partition-sensitive one-pole smoother (test fixture)",
	features = &features[0],
}

params: [1]adapter.Param_Descriptor = {
	{
		id = PARAM_COEFFICIENT,
		name = "Coefficient",
		module = "Smoothing",
		flags = clap.CLAP_PARAM_IS_AUTOMATABLE,
		min = 0,
		max = 1,
		default = 0.25,
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

process :: proc(data: rawptr, request: ^adapter.Process_Request) -> adapter.Process_Result {
	_ = data
	if request == nil || len(request.params) < 1 {
		return .Error
	}
	coefficient := f32(request.params[0])
	for channel in 0 ..< request.channels {
		// The defect: state starts at zero for every block.
		smoother := f32(0)
		input := cast([^]f32)request.input[channel]
		output := cast([^]f32)request.output[channel]
		for frame in 0 ..< int(request.frames) {
			smoother += coefficient * (input[frame] - smoother)
			output[frame] = smoother
		}
	}
	return .Continue
}

backend: adapter.Backend_VTable = {
	create = create,
	destroy = destroy,
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
	state_magic = {'C', 'S', 'B', 'S', 'M', 'O', '0', '1'},
	state_schema = 1,
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