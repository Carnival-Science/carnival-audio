// Host integration tests against the reference gain plugin.
//
// The plugin path comes from PULSE_VERIFY_GAIN_CLAP, which tools/test.ps1 sets
// after building the reference processors. Without it the test returns early:
// the package must still type-check and unit-test on machines that only build
// the core, but the laboratory run always provides a specimen.
package verification_host

import "core:math"
import "core:os"
import "core:testing"

import clap "carnival:third_party/clap/abi"

@(test)
test_host_loads_reference_gain_and_processes :: proc(t: ^testing.T) {
	path := os.get_env_alloc("PULSE_VERIFY_GAIN_CLAP", context.temp_allocator)
	if path == "" {
		return
	}
	library, opened := library_open(path)
	testing.expect(t, opened, "library_open")
	if !opened {
		return
	}
	defer library_close(&library)
	testing.expect_value(t, library_plugin_count(&library), u32(1))
	descriptor := library_descriptor(&library, 0)
	testing.expect(t, descriptor != nil, "descriptor")
	if descriptor == nil {
		return
	}
	testing.expect_value(t, string(descriptor.id), "com.carnival-science.reference.gain")

	instance, created := instance_create(&library, string(descriptor.id), 512)
	testing.expect(t, created, "instance_create")
	if !created {
		return
	}
	defer instance_destroy(instance)
	testing.expect(t, instance_init(instance), "init")
	testing.expect(t, instance_activate(instance, 48000, 1, 512), "activate")
	testing.expect(t, instance_start(instance), "start")
	testing.expect(t, instance_on_main_thread(instance), "main-thread view")
	testing.expect_value(t, instance_has_telemetry(instance), false)
	testing.expect_value(t, instance.param_count, 1)

	param_id := instance.params[0].id
	testing.expect(t, instance_set_param(instance, param_id, 0.5), "set gain")
	value, value_ok := instance_get_param(instance, param_id)
	testing.expect(t, value_ok, "get gain")
	testing.expect_value(t, value, f64(0.5))

	input := make([][]f32, 2)
	output := make([][]f32, 2)
	defer {
		delete(input[0]); delete(input[1]); delete(input)
		delete(output[0]); delete(output[1]); delete(output)
	}
	for channel in 0 ..< 2 {
		input[channel] = make([]f32, 64)
		output[channel] = make([]f32, 64)
		for frame in 0 ..< 64 {
			input[channel][frame] = 1.0
		}
	}
	status, called := instance_process(instance, 64, input, output, 0)
	testing.expect(t, called, "process called")
	testing.expect_value(t, status, i32(1)) // CLAP_PROCESS_CONTINUE
	for channel in 0 ..< 2 {
		for frame in 0 ..< 64 {
			testing.expect_value(t, output[channel][frame], f32(0.5))
		}
	}

	// The host must present a transport event and a valid empty event list.
	transport := clap.Event_Transport{
		header = clap.Event_Header{
			size = u32(size_of(clap.Event_Transport)),
			space_id = clap.CLAP_CORE_EVENT_SPACE_ID,
			type = u16(clap.Event_Type.Transport),
		},
		flags = clap.CLAP_TRANSPORT_HAS_TEMPO | clap.CLAP_TRANSPORT_IS_PLAYING,
		tempo = 120,
	}
	status_with_transport, called_with_transport := instance_process(
		instance,
		64,
		input,
		output,
		64,
		nil,
		&transport,
	)
	testing.expect(t, called_with_transport, "process with transport called")
	testing.expect_value(t, status_with_transport, i32(1))

	// Authoring state round trip through the host's memory stream.
	saved, save_ok := instance_save_state(instance)
	testing.expect(t, save_ok, "save state")
	defer delete(saved)
	testing.expect(t, instance_set_param(instance, param_id, 0.9), "change gain")
	testing.expect(t, instance_load_state(instance, saved), "load state")
	restored_value, restored_ok := instance_get_param(instance, param_id)
	testing.expect(t, restored_ok, "get restored gain")
	testing.expect_value(t, restored_value, f64(0.5))
}

@(test)
test_host_two_instances_are_independent :: proc(t: ^testing.T) {
	path := os.get_env_alloc("PULSE_VERIFY_GAIN_CLAP", context.temp_allocator)
	if path == "" {
		return
	}
	library, opened := library_open(path)
	if !opened {
		testing.fail_now(t, "library_open")
	}
	defer library_close(&library)
	descriptor := library_descriptor(&library, 0)
	instance_a, created_a := instance_create(&library, string(descriptor.id), 256)
	instance_b, created_b := instance_create(&library, string(descriptor.id), 256)
	testing.expect(t, created_a && created_b, "two instances")
	if !created_a || !created_b {
		return
	}
	defer instance_destroy(instance_a)
	defer instance_destroy(instance_b)
	_ = instance_init(instance_a)
	_ = instance_init(instance_b)
	_ = instance_activate(instance_a, 48000, 1, 256)
	_ = instance_activate(instance_b, 48000, 1, 256)
	_ = instance_start(instance_a)
	_ = instance_start(instance_b)
	_ = instance_set_param(instance_a, instance_a.params[0].id, 0.5)
	_ = instance_set_param(instance_b, instance_b.params[0].id, 0.25)

	input := make([][]f32, 2)
	output_a := make([][]f32, 2)
	output_b := make([][]f32, 2)
	defer {
		for channel in 0 ..< 2 {
			delete(input[channel]); delete(output_a[channel]); delete(output_b[channel])
		}
		delete(input); delete(output_a); delete(output_b)
	}
	for channel in 0 ..< 2 {
		input[channel] = make([]f32, 32)
		output_a[channel] = make([]f32, 32)
		output_b[channel] = make([]f32, 32)
		for frame in 0 ..< 32 {
			input[channel][frame] = f32(0.8)
		}
	}
	_, called_a := instance_process(instance_a, 32, input, output_a, 0)
	_, called_b := instance_process(instance_b, 32, input, output_b, 0)
	testing.expect(t, called_a && called_b, "interleaved process")
	for frame in 0 ..< 32 {
		testing.expect(t, math.abs(f64(output_a[0][frame]) - 0.4) < 1e-7, "A gain")
		testing.expect(t, math.abs(f64(output_b[0][frame]) - 0.2) < 1e-7, "B gain")
	}
}
