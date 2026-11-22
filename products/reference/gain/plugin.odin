// Reference processor: stateless linear gain.
//
// This is the simplest possible well-defined specimen: one parameter, one
// multiply per sample, no state and no tail. Its output is expected to be
// bit-exact across block partitions and across fresh processes:
//
//     out = in * gain
//
// where both operands are f32 and the multiplication is the only operation.
// Verification treats this as an exact-equality specimen, not a tolerance one.
package reference_gain

import "base:runtime"

import adapter "carnival:adapters/clap"
import clap "carnival:third_party/clap/abi"

PLUGIN_ID :: "com.carnival-science.reference.gain"
PLUGIN_VERSION :: "0.1.0"

PARAM_GAIN :: u32(2001)

features: [3]cstring = {
	clap.CLAP_PLUGIN_FEATURE_AUDIO_EFFECT,
	clap.CLAP_PLUGIN_FEATURE_STEREO,
	nil,
}

descriptor: clap.Plugin_Descriptor = {
	clap_version = clap.CLAP_VERSION,
	id = PLUGIN_ID,
	name = "Reference Gain",
	vendor = "Carnival Science",
	url = "https://carnival.science/",
	version = PLUGIN_VERSION,
	description = "Stateless reference gain for verification laboratory fixtures",
	features = &features[0],
}

params: [1]adapter.Param_Descriptor = {
	{
		id = PARAM_GAIN,
		name = "Gain",
		module = "Gain",
		flags = clap.CLAP_PARAM_IS_AUTOMATABLE,
		min = 0,
		max = 4,
		default = 0.5,
		format = .Decimal,
	},
}

State :: struct {
	// Non-zero size: the adapter rejects a plugin whose create returns nil.
	dummy: u8,
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
	gain := f32(request.params[0])
	for channel in 0 ..< request.channels {
		input := cast([^]f32)request.input[channel]
		output := cast([^]f32)request.output[channel]
		for frame in 0 ..< int(request.frames) {
			output[frame] = input[frame] * gain
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
	state_magic = {'C', 'S', 'R', 'G', 'A', 'I', 'N', '1'},
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