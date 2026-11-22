// Product definition and CLAP entry for Pulse.
//
// The entry point is compiled only for the plugin target
// (`-define:PULSE_PLUGIN_BUILD=true`) so `odin test products/pulse` does not
// export a second DSO entry symbol. The test harness registers
// `pulse_definition` with the adapter directly.
package pulse

import "base:runtime"

import adapter "carnival:adapters/clap"
import clap "carnival:third_party/clap/abi"

PULSE_PLUGIN_ID :: "com.carnival-science.pulse.meter"
PLUGIN_VERSION :: "0.1.0"

pulse_features: [4]cstring = {
	clap.CLAP_PLUGIN_FEATURE_AUDIO_EFFECT,
	clap.CLAP_PLUGIN_FEATURE_ANALYZER,
	clap.CLAP_PLUGIN_FEATURE_STEREO,
	nil,
}

pulse_descriptor: clap.Plugin_Descriptor = {
	clap_version = clap.CLAP_VERSION,
	id = PULSE_PLUGIN_ID,
	name = "Pulse Meter",
	vendor = "Carnival Science",
	url = "https://carnival.science/",
	manual_url = "",
	support_url = "https://carnival.science/",
	version = PLUGIN_VERSION,
	description = "Headless stereo sample peak, RMS and peak-hold meter",
	features = &pulse_features[0],
}

pulse_params: [4]adapter.Param_Descriptor = {
	{
		id = PARAM_WINDOW_FRAMES,
		name = "Window Frames",
		module = "Analysis",
		flags = clap.CLAP_PARAM_IS_AUTOMATABLE | clap.CLAP_PARAM_IS_STEPPED,
		min = 128,
		max = 8192,
		default = 1024,
		format = .Integer,
		stepped = true,
	},
	{
		id = PARAM_HOLD_FRAMES,
		name = "Hold Frames",
		module = "Hold",
		flags = clap.CLAP_PARAM_IS_AUTOMATABLE | clap.CLAP_PARAM_IS_STEPPED,
		min = 0,
		max = 96000,
		default = 4800,
		format = .Integer,
		stepped = true,
	},
	{
		id = PARAM_HOLD_DECAY_ENABLED,
		name = "Hold Decay",
		module = "Hold",
		flags = clap.CLAP_PARAM_IS_AUTOMATABLE | clap.CLAP_PARAM_IS_STEPPED,
		min = 0,
		max = 1,
		default = 1,
		format = .Boolean,
		stepped = true,
	},
	{
		id = PARAM_HOLD_DECAY_DB,
		name = "Hold Decay Rate",
		module = "Hold",
		flags = clap.CLAP_PARAM_IS_AUTOMATABLE,
		min = 0,
		max = 120,
		default = 20,
		format = .Decibels,
	},
}

pulse_backend: adapter.Backend_VTable = {
	create = pulse_backend_create,
	destroy = pulse_backend_destroy,
	init = pulse_backend_init,
	activate = pulse_backend_activate,
	deactivate = pulse_backend_deactivate,
	start = pulse_backend_start,
	stop = pulse_backend_stop,
	reset = pulse_backend_reset,
	process = pulse_backend_process,
}

pulse_definition: adapter.Definition = {
	descriptor = &pulse_descriptor,
	backend = &pulse_backend,
	params = pulse_params[:],
	input_port_id = 1,
	output_port_id = 2,
	input_port_name = "Input",
	output_port_name = "Output",
	state_magic = {'C', 'S', 'P', 'U', 'L', 'S', 'E', '1'},
	state_schema = STATE_SCHEMA,
}

// ---------------------------------------------------------------------------
// Backend vtable implementation
// ---------------------------------------------------------------------------

pulse_backend_create :: proc() -> rawptr {
	context = runtime.default_context()
	return meter_create()
}

pulse_backend_destroy :: proc(data: rawptr) {
	context = runtime.default_context()
	meter_destroy(cast(^Meter)data)
}

pulse_backend_init :: proc(data: rawptr, host: ^adapter.Host_Info) -> bool {
	context = runtime.default_context()
	_ = host
	return data != nil
}

pulse_backend_activate :: proc(data: rawptr, config: adapter.Activation_Config) -> bool {
	context = runtime.default_context()
	return meter_activate(cast(^Meter)data, config)
}

pulse_backend_deactivate :: proc(data: rawptr) {
	context = runtime.default_context()
	meter_deactivate(cast(^Meter)data)
}

pulse_backend_start :: proc(data: rawptr) -> bool {
	return data != nil
}

pulse_backend_stop :: proc(data: rawptr) {
	_ = data
}

pulse_backend_reset :: proc(data: rawptr) {
	context = runtime.default_context()
	meter_reset(cast(^Meter)data)
}

pulse_backend_process :: proc(data: rawptr, request: ^adapter.Process_Request) -> adapter.Process_Result {
	return meter_process(cast(^Meter)data, request)
}

// ---------------------------------------------------------------------------
// Exported CLAP entry (plugin build only)
// ---------------------------------------------------------------------------

when #config(PULSE_PLUGIN_BUILD, false) {
	pulse_entry_init :: proc "c" (plugin_path: cstring) -> bool {
		context = runtime.default_context()
		_ = plugin_path
		adapter.register_definition(&pulse_definition)
		return adapter.entry_init(plugin_path)
	}

	pulse_entry_deinit :: proc "c" () {
		context = runtime.default_context()
		adapter.entry_deinit()
	}

	pulse_entry_get_factory :: proc "c" (factory_id: cstring) -> rawptr {
		context = runtime.default_context()
		return adapter.entry_get_factory(factory_id)
	}

	@(export)
	clap_entry: clap.Entry = {
		clap_version = clap.CLAP_VERSION,
		init = pulse_entry_init,
		deinit = pulse_entry_deinit,
		get_factory = pulse_entry_get_factory,
	}
}
