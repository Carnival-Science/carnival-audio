// DEFECTIVE reference processor: emits NaN on a documented edge input.
//
// For every sample whose magnitude is at or above 0.95, the output is a quiet
// NaN instead of the sample. This is a deterministic, documented defect used to
// prove that the laboratory's non-finite probe actually scans output (and does
// not merely compare finite hashes). A pass-through of ordinary input is
// untouched.
//
// The NaN payload is fixed (0x7FC00000), so byte hashes remain deterministic
// even while the non-finite probe fails.
package reference_nan_trigger

import "base:runtime"

import "core:math"

import adapter "carnival:adapters/clap"
import clap "carnival:third_party/clap/abi"

PLUGIN_ID :: "com.carnival-science.reference.nan-trigger"
PLUGIN_VERSION :: "0.1.0"

NAN_THRESHOLD :: f32(0.95)
QUIET_NAN_BITS :: u32(0x7FC0_0000)

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
	name = "Defective NaN Trigger",
	vendor = "Carnival Science",
	url = "https://carnival.science/",
	version = PLUGIN_VERSION,
	description = "Emits NaN for documented edge input (test fixture)",
	features = &features[0],
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
	if request == nil {
		return .Error
	}
	nan := transmute(f32)QUIET_NAN_BITS
	for channel in 0 ..< request.channels {
		input := cast([^]f32)request.input[channel]
		output := cast([^]f32)request.output[channel]
		for frame in 0 ..< int(request.frames) {
			x := input[frame]
			if math.abs(x) >= NAN_THRESHOLD {
				output[frame] = nan
			} else {
				output[frame] = x
			}
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
	params = nil,
	input_port_id = 1,
	output_port_id = 2,
	input_port_name = "Input",
	output_port_name = "Output",
	state_magic = {'C', 'S', 'N', 'A', 'N', '0', '0', '1'},
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