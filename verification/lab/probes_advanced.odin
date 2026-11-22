// Automation, state, isolation, reset, tail, perturbation and capture probes.
//
// These probes deliberately separate observation from expectation:
//   - static partition invariance is a pass/fail structural expectation;
//   - automation partition sensitivity is a *class label* with an explicit
//     applicability note, because block-start parameter application is a
//     documented control-rate contract, not sample-exact automation;
//   - tail and perturbation report measured windows instead of claiming
//     convergence from silence.
package verification_lab

import "core:fmt"
import "core:math"

import clap "carnival:third_party/clap/abi"
import host "carnival:verification/host"

// process_range drives an existing instance over [start, start+frames) of the
// input in fixed 512-frame blocks, writing into output at out_offset. It is
// used by state/isolation/reset probes that must keep one instance alive.
process_range :: proc(
	instance: ^host.Instance,
	input: [][]f32,
	start, frames: int,
	output: [][]f32,
	out_offset: int,
) -> bool {
	if frames < 0 || start + frames > len(input[0]) {
		return false
	}
	BLOCK :: 512
	absolute := start
	written := 0
	for written < frames {
		size := min(BLOCK, frames - written)
		in_slices := [][]f32{
			input[0][absolute:absolute + size],
			input[1][absolute:absolute + size],
		}
		out_slices := [][]f32{
			output[0][out_offset + written:out_offset + written + size],
			output[1][out_offset + written:out_offset + written + size],
		}
		status, called := host.instance_process(
			instance,
			u32(size),
			in_slices,
			out_slices,
			i64(absolute),
			nil,
			nil,
		)
		if !called || status == clap.CLAP_PROCESS_ERROR {
			return false
		}
		absolute += size
		written += size
	}
	return true
}

suffix_slice_hash :: proc(output: [][]f32, start, frames: int) -> string {
	if frames <= 0 {
		return sha256_hex_string("empty")
	}
	return hash_planar([][]f32{
		output[0][start:start + frames],
		output[1][start:start + frames],
	}, frames)
}

// ---------------------------------------------------------------------------
// Automation partition classes
// ---------------------------------------------------------------------------

probe_automation :: proc(ctx: ^Run_Context) -> Probe_Builder {
	builder := probe_start(
		"automation",
		"automation_partition_class",
		"Sample-timestamped parameter events are delivered inside CLAP blocks. The adapter under test applies a block's events at block start (documented control-rate semantics), so automation results are expected to be partition-sensitive. This probe labels the observed class; it does not require sample-exact automation.",
	)
	if !ctx.scenario.automation.enabled || len(ctx.scenario.automation.events) == 0 {
		builder.status = .Skip
		builder.summary = "no automation schedule in scenario"
		return builder
	}
	partitions := make([dynamic]Partition_Spec, 0, context.temp_allocator)
	for wanted in ctx.scenario.automation.partitions {
		for partition in ctx.scenario.partitions {
			if partition.name == wanted {
				append(&partitions, partition)
			}
		}
	}
	if len(partitions) < 2 {
		builder.status = .Skip
		builder.summary = "fewer than two automation partitions selected"
		return builder
	}
	static := render(ctx, Render_Request{
		partition = ctx.scenario.partitions[0],
		frames = ctx.scenario.input.frames,
		capture = ctx.scenario.telemetry.enabled,
	})
	defer destroy_render(&static)
	reference := render(ctx, Render_Request{
		partition = partitions[0],
		frames = ctx.scenario.input.frames,
		events = ctx.scenario.automation.events,
		capture = ctx.scenario.telemetry.enabled,
	})
	defer destroy_render(&reference)
	if !static.ok || !reference.ok {
		probe_fail(&builder, "automation render failed")
		return builder
	}
	changed_by_automation := static.output_hash != reference.output_hash
	metric_add(&builder, "static_output_hash", static.output_hash)
	metric_add(&builder, "automation_output_hash_0", reference.output_hash)
	metric_add(&builder, "automation_changes_output", fmt.aprintf("%v", changed_by_automation))
	max_delta := f64(0)
	differing := 0
	record_differing := 0
	for partition, index in partitions {
		if index == 0 {
			continue
		}
		result := render(ctx, Render_Request{
			partition = partition,
			frames = ctx.scenario.input.frames,
			events = ctx.scenario.automation.events,
			capture = ctx.scenario.telemetry.enabled,
		})
		defer destroy_render(&result)
		if !result.ok {
			probe_fail(&builder, fmt.aprintf("automation render failed for %s", partition.name))
			return builder
		}
		metric_add(&builder, fmt.aprintf("automation_output_hash_%s", partition.name), result.output_hash)
		if result.telemetry_available {
			metric_add(&builder, fmt.aprintf("automation_record_hash_%s", partition.name), result.record_hash)
			if result.record_hash != reference.record_hash {
				record_differing += 1
				detail_add(&builder, fmt.aprintf(
					"partition %s canonical measurement records differ (first mismatch index %d)",
					partition.name,
					first_record_difference(reference.records[:], result.records[:]),
				))
			}
		}
		if result.output_hash != reference.output_hash {
			differing += 1
			delta_index, delta := first_output_difference(
				reference.output,
				result.output,
				min(reference.output_frames, result.output_frames),
			)
			max_delta = max(max_delta, delta)
			if delta_index >= 0 {
				detail_add(&builder, fmt.aprintf(
					"partition %s differs at frame %d (max abs delta %.9g)",
					partition.name,
					delta_index,
					delta,
				))
			}
		}
	}
	metric_add_int(&builder, "automation_partitions", len(partitions))
	metric_add_int(&builder, "partition_sensitive_pairs", differing)
	metric_add_int(&builder, "record_partition_sensitive_pairs", record_differing)
	metric_add_f64(&builder, "max_output_abs_delta", max_delta, "amplitude")
	if differing > 0 || record_differing > 0 {
		builder.class = "automation_partition_sensitive_control_rate"
		builder.summary = fmt.aprintf(
			"automation changes across %d audio and %d record partition comparisons (observed control-rate class)",
			differing,
			record_differing,
		)
		detail_add(&builder, "Observed, not a defect claim: block-start parameter application is the documented adapter contract")
	} else {
		builder.class = "automation_partition_invariant_observed"
		builder.summary = "automation output and records are identical across the selected partitions for this schedule"
	}
	records_changed := static.record_hash != reference.record_hash
	if !changed_by_automation && !records_changed {
		detail_add(&builder, "automation did not change output or records relative to static parameters for this schedule")
	}
	return builder
}

// ---------------------------------------------------------------------------
// Authoring state and migration
// ---------------------------------------------------------------------------

param_value_close :: proc(a, b: f64) -> bool {
	return math.abs(a - b) <= 1e-12 * max(1.0, math.abs(b))
}

probe_state :: proc(ctx: ^Run_Context) -> Probe_Builder {
	builder := probe_start(
		"state",
		"authoring_state_and_migration",
		"Authoring state is versioned parameter state. Processing state is not authoring state; processors may additionally serialize a schema-4 processing blob. Migration expectations are declared per historical fixture.",
	)
	instance, opened := open_instance(ctx, ctx.scenario.max_block_frames, nil, false)
	if !opened {
		probe_fail(&builder, "could not open instance for state probe")
		return builder
	}
	defer host.instance_destroy(instance)

	// 1. Authoring round trip: save, change a parameter, load, compare.
	saved, saved_ok := host.instance_save_state(instance)
	if !saved_ok {
		probe_fail(&builder, "state save failed")
		return builder
	}
	defer delete(saved)
	metric_add(&builder, "saved_state_sha256", sha256_hex(saved))
	metric_add_int(&builder, "saved_state_bytes", len(saved))
	restored_params := 0
	for setting in ctx.scenario.params {
		_ = host.instance_set_param(instance, setting.id, setting.value)
	}
	if len(ctx.scenario.params) > 0 {
		first := ctx.scenario.params[0]
		_ = host.instance_set_param(instance, first.id, first.value * 0.5)
		if !host.instance_load_state(instance, saved) {
			probe_fail(&builder, "state load of a just-saved blob failed")
			return builder
		}
		for setting in ctx.scenario.params {
			value, ok := host.instance_get_param(instance, setting.id)
			if !ok || !param_value_close(value, setting.value) {
				probe_fail(&builder, fmt.aprintf(
					"authoring state round trip changed parameter %d (got %.12g, expected %.12g)",
					setting.id,
					value,
					setting.value,
				))
				break
			}
			restored_params += 1
		}
	}
	metric_add_int(&builder, "restored_authoring_params", restored_params)

	// 2. Continuous restore: prefix -> save -> (fresh instance) load -> suffix.
	prefix := min(ctx.scenario.input.frames / 2, 8192)
	suffix := ctx.scenario.input.frames - prefix
	if suffix > 0 {
		continuous := make([][]f32, 2)
		for channel in 0 ..< 2 {
			continuous[channel] = make([]f32, ctx.scenario.input.frames)
		}
		defer destroy_input(continuous)

		continuous_ok := true
		// A: one instance processes prefix and suffix continuously.
		instance_a, opened_a := open_instance(ctx, ctx.scenario.max_block_frames, nil, ctx.scenario.telemetry.enabled)
		if !opened_a {
			continuous_ok = false
		} else {
			if !process_range(instance_a, ctx.input, 0, prefix, continuous, 0) {
				continuous_ok = false
			}
			state_a, state_a_ok := host.instance_save_state(instance_a)
			if state_a_ok {
				metric_add(&builder, "processing_state_sha256", sha256_hex(state_a))
				delete(state_a)
			}
			if !process_range(instance_a, ctx.input, prefix, suffix, continuous, prefix) {
				continuous_ok = false
			}
			host.instance_destroy(instance_a)
		}

		restored := make([][]f32, 2)
		for channel in 0 ..< 2 {
			restored[channel] = make([]f32, ctx.scenario.input.frames)
		}
		defer destroy_input(restored)
		if continuous_ok {
			// B: a fresh instance restores the saved state before the suffix.
			instance_b, opened_b := open_instance(ctx, ctx.scenario.max_block_frames, nil, ctx.scenario.telemetry.enabled)
			if !opened_b {
				continuous_ok = false
			} else {
				if !process_range(instance_b, ctx.input, 0, prefix, restored, 0) {
					continuous_ok = false
				}
				saved_b, saved_b_ok := host.instance_save_state(instance_b)
				if !saved_b_ok {
					continuous_ok = false
				} else {
					// The fresh instance must start from no processing state. A
					// new instance has that property; load the saved authoring
					// plus processing blob.
					host.instance_destroy(instance_b)
					instance_c, opened_c := open_instance(ctx, ctx.scenario.max_block_frames, nil, false)
					if !opened_c {
						continuous_ok = false
					} else {
						if !host.instance_load_state(instance_c, saved_b) {
							continuous_ok = false
						} else if !process_range(instance_c, ctx.input, prefix, suffix, restored, prefix) {
							continuous_ok = false
						}
						host.instance_destroy(instance_c)
					}
					delete(saved_b)
				}
			}
		}
		if continuous_ok {
			left := suffix_slice_hash(continuous, prefix, suffix)
			right := suffix_slice_hash(restored, prefix, suffix)
			metric_add(&builder, "continuous_suffix_hash", left)
			metric_add(&builder, "restored_suffix_hash", right)
			if left != right {
				probe_fail(&builder, "output after a state restore diverges from the uninterrupted run (processing state missing)")
			}
		}
	}

	// 3. Historical fixture migration.
	for fixture in ctx.scenario.state.fixtures {
		bytes, decoded := hex_decode(fixture.hex, context.temp_allocator)
		if !decoded {
			probe_fail(&builder, fmt.aprintf("fixture %s is not valid hex", fixture.name))
			continue
		}
		fixture_instance, fixture_opened := open_instance(ctx, ctx.scenario.max_block_frames, nil, false)
		if !fixture_opened {
			probe_fail(&builder, fmt.aprintf("could not open instance for fixture %s", fixture.name))
			continue
		}
		loaded := host.instance_load_state(fixture_instance, bytes)
		if !loaded {
			probe_fail(&builder, fmt.aprintf("fixture %s (schema %d) failed to load", fixture.name, fixture.schema))
			host.instance_destroy(fixture_instance)
			continue
		}
		metric_add(&builder, fmt.aprintf("fixture_%s_load", fixture.name), "ok")
		for expected in fixture.expect_params {
			value, ok := host.instance_get_param(fixture_instance, expected.id)
			fixture_ok := ok && param_value_close(value, expected.value)
			metric_add(
				&builder,
				fmt.aprintf("fixture_%s_param_%d", fixture.name, expected.id),
				fmt.aprintf("%.12g", value),
			)
			if !fixture_ok {
				probe_fail(&builder, fmt.aprintf(
					"fixture %s restored parameter %d to %.12g, expected %.12g",
					fixture.name,
					expected.id,
					value,
					expected.value,
				))
			}
		}
		// Capture mode is observed by processing without an explicit enable: a
		// schema-3 fixture that stored the flag on produces canonical records.
		short := make([][]f32, 2)
		for channel in 0 ..< 2 {
			short[channel] = make([]f32, 4096)
		}
		out := make([][]f32, 2)
		for channel in 0 ..< 2 {
			out[channel] = make([]f32, 4096)
		}
		_ = host.instance_start(fixture_instance)
		_ = process_range(fixture_instance, short, 0, 4096, out, 0)
		collector := host.Capture_Collector{records = make([dynamic]clap.Carnival_Measurement_Record, 0, 16)}
		_ = host.instance_capture_drain(fixture_instance, &collector)
		capture_on := len(collector.records) > 0
		delete(collector.records)
		metric_add(&builder, fmt.aprintf("fixture_%s_capture_on", fixture.name), fmt.aprintf("%v", capture_on))
		if capture_on != fixture.expect_capture {
			probe_fail(&builder, fmt.aprintf(
				"fixture %s capture mode %v, expected %v",
				fixture.name,
				capture_on,
				fixture.expect_capture,
			))
		}
		destroy_input(short)
		destroy_input(out)

		// Render equality with the current-schema equivalent: load the fixture
		// into one fresh instance (audio state is fresh after activation) and
		// compare its output with a fresh instance whose parameters are set
		// explicitly to the expected values.
		reference_instance, reference_opened := open_instance(
			ctx,
			ctx.scenario.max_block_frames,
			fixture.expect_params,
			false,
		)
		if reference_opened {
			fixture_output := make([][]f32, 2)
			reference_output := make([][]f32, 2)
			for channel in 0 ..< 2 {
				fixture_output[channel] = make([]f32, ctx.scenario.input.frames)
				reference_output[channel] = make([]f32, ctx.scenario.input.frames)
			}
			fixture_render_instance, fixture_render_opened := open_instance(
				ctx,
				ctx.scenario.max_block_frames,
				nil,
				false,
			)
			fixture_render_ok := false
			if fixture_render_opened && host.instance_load_state(fixture_render_instance, bytes) {
				fixture_render_ok = process_range(
					fixture_render_instance,
					ctx.input,
					0,
					ctx.scenario.input.frames,
					fixture_output,
					0,
				)
			}
			reference_ok := process_range(
				reference_instance,
				ctx.input,
				0,
				ctx.scenario.input.frames,
				reference_output,
				0,
			)
			if fixture_render_opened {
				host.instance_destroy(fixture_render_instance)
			}
			host.instance_destroy(reference_instance)
			if fixture_render_ok && reference_ok {
				fixture_hash := hash_planar(fixture_output, ctx.scenario.input.frames)
				reference_hash := hash_planar(reference_output, ctx.scenario.input.frames)
				metric_add(&builder, fmt.aprintf("fixture_%s_render_hash", fixture.name), fixture_hash)
				if fixture_hash != reference_hash {
					probe_fail(&builder, fmt.aprintf(
						"fixture %s render differs from the current-schema equivalent",
						fixture.name,
					))
				}
			} else {
				detail_add(&builder, fmt.aprintf("fixture %s render equality could not be established", fixture.name))
			}
			destroy_input(fixture_output)
			destroy_input(reference_output)
		}
		host.instance_destroy(fixture_instance)
	}
	if builder.status == .Pass {
		builder.summary = fmt.aprintf(
			"authoring round trip restored %d parameters; %d historical fixtures migrated",
			restored_params,
			len(ctx.scenario.state.fixtures),
		)
		if len(ctx.scenario.state.fixtures) == 0 {
			builder.summary = fmt.aprintf(
				"authoring round trip restored %d parameters; continuous state restore checked",
				restored_params,
			)
		}
	}
	return builder
}

// ---------------------------------------------------------------------------
// Instance isolation
// ---------------------------------------------------------------------------

derive_alt_params :: proc(ctx: ^Run_Context) -> []Param_Setting {
	if len(ctx.scenario.isolation.alt_params) > 0 {
		return ctx.scenario.isolation.alt_params
	}
	instance, opened := open_instance(ctx, ctx.scenario.max_block_frames, nil, false)
	if !opened {
		return nil
	}
	defer host.instance_destroy(instance)
	if instance.param_count == 0 {
		return nil
	}
	info := instance.params[0]
	midpoint := clamp(info.default * 0.5, info.min, info.max)
	result := make([]Param_Setting, 1)
	result[0] = Param_Setting{id = info.id, value = midpoint}
	return result
}

probe_isolation :: proc(ctx: ^Run_Context) -> Probe_Builder {
	builder := probe_start(
		"isolation",
		"instance_isolation",
		"Two instances in one host process with different parameter states, processed interleaved, must match their solo runs. Applicability: separate instances, not separate processes.",
	)
	if !ctx.scenario.isolation.enabled {
		builder.status = .Skip
		builder.summary = "isolation disabled in scenario"
		return builder
	}
	alt_params := derive_alt_params(ctx)
	defer if alt_params != nil { delete(alt_params) }
	solo_a := render(ctx, Render_Request{
		partition = Partition_Spec{name = "isolation", block_sizes = []u32{256}},
		frames = ctx.scenario.input.frames,
	})
	defer destroy_render(&solo_a)
	solo_b := render(ctx, Render_Request{
		partition = Partition_Spec{name = "isolation", block_sizes = []u32{256}},
		frames = ctx.scenario.input.frames,
		params = alt_params,
	})
	defer destroy_render(&solo_b)
	if !solo_a.ok || !solo_b.ok {
		probe_fail(&builder, "solo isolation render failed")
		return builder
	}

	out_a := make([][]f32, 2)
	out_b := make([][]f32, 2)
	for channel in 0 ..< 2 {
		out_a[channel] = make([]f32, ctx.scenario.input.frames)
		out_b[channel] = make([]f32, ctx.scenario.input.frames)
	}
	defer destroy_input(out_a)
	defer destroy_input(out_b)
	instance_a, opened_a := open_instance(ctx, ctx.scenario.max_block_frames, nil, false)
	instance_b, opened_b := open_instance(ctx, ctx.scenario.max_block_frames, alt_params, false)
	if !opened_a || !opened_b {
		if opened_a { host.instance_destroy(instance_a) }
		if opened_b { host.instance_destroy(instance_b) }
		probe_fail(&builder, "could not open two instances")
		return builder
	}
	defer host.instance_destroy(instance_a)
	defer host.instance_destroy(instance_b)
	BLOCK :: 256
	absolute := 0
	written := 0
	ok := true
	for written < ctx.scenario.input.frames {
		size := min(BLOCK, ctx.scenario.input.frames - written)
		// A and B are processed block-by-block in pairs; the call order is part
		// of the isolation test.
		in_slices := [][]f32{
			ctx.input[0][absolute:absolute + size],
			ctx.input[1][absolute:absolute + size],
		}
		out_slices_a := [][]f32{
			out_a[0][written:written + size],
			out_a[1][written:written + size],
		}
		out_slices_b := [][]f32{
			out_b[0][written:written + size],
			out_b[1][written:written + size],
		}
		status_a, called_a := host.instance_process(instance_a, u32(size), in_slices, out_slices_a, i64(absolute))
		status_b, called_b := host.instance_process(instance_b, u32(size), in_slices, out_slices_b, i64(absolute))
		if !called_a || !called_b || status_a == clap.CLAP_PROCESS_ERROR || status_b == clap.CLAP_PROCESS_ERROR {
			ok = false
			break
		}
		absolute += size
		written += size
	}
	if !ok {
		probe_fail(&builder, "interleaved processing failed")
		return builder
	}
	hash_a := hash_planar(out_a, ctx.scenario.input.frames)
	hash_b := hash_planar(out_b, ctx.scenario.input.frames)
	metric_add(&builder, "solo_a_hash", solo_a.output_hash)
	metric_add(&builder, "interleaved_a_hash", hash_a)
	metric_add(&builder, "solo_b_hash", solo_b.output_hash)
	metric_add(&builder, "interleaved_b_hash", hash_b)
	if hash_a != solo_a.output_hash {
		probe_fail(&builder, "instance A output changed when a second instance processed interleaved")
	}
	if hash_b != solo_b.output_hash {
		probe_fail(&builder, "instance B output changed when a second instance processed interleaved")
	}
	if builder.status == .Pass {
		builder.summary = "both interleaved instances match their solo runs"
	}
	return builder
}

// ---------------------------------------------------------------------------
// Reset / restart
// ---------------------------------------------------------------------------

probe_reset :: proc(ctx: ^Run_Context) -> Probe_Builder {
	builder := probe_start(
		"reset",
		"reset_clean_state",
		"CLAP reset must clear processing state so reprocessing the same input matches a fresh instance. Authoring parameters are unchanged by reset. Tail state from before the reset is intentionally discarded.",
	)
	baseline := render(ctx, Render_Request{
		partition = Partition_Spec{name = "reset", block_sizes = []u32{512}},
		frames = ctx.scenario.input.frames,
	})
	defer destroy_render(&baseline)
	if !baseline.ok {
		probe_fail(&builder, "baseline render failed")
		return builder
	}
	output := make([][]f32, 2)
	restarted := make([][]f32, 2)
	for channel in 0 ..< 2 {
		output[channel] = make([]f32, ctx.scenario.input.frames)
		restarted[channel] = make([]f32, ctx.scenario.input.frames)
	}
	defer destroy_input(output)
	defer destroy_input(restarted)
	instance, opened := open_instance(ctx, ctx.scenario.max_block_frames, nil, false)
	if !opened {
		probe_fail(&builder, "could not open instance")
		return builder
	}
	defer host.instance_destroy(instance)
	if !process_range(instance, ctx.input, 0, ctx.scenario.input.frames, output, 0) {
		probe_fail(&builder, "first pass failed")
		return builder
	}
	host.instance_reset(instance)
	if !process_range(instance, ctx.input, 0, ctx.scenario.input.frames, restarted, 0) {
		probe_fail(&builder, "post-reset pass failed")
		return builder
	}
	first_hash := hash_planar(output, ctx.scenario.input.frames)
	restarted_hash := hash_planar(restarted, ctx.scenario.input.frames)
	metric_add(&builder, "first_pass_hash", first_hash)
	metric_add(&builder, "post_reset_hash", restarted_hash)
	metric_add(&builder, "fresh_hash", baseline.output_hash)
	if restarted_hash != first_hash || restarted_hash != baseline.output_hash {
		probe_fail(&builder, "reset did not restore clean-state output equivalence")
	}
	if builder.status == .Pass {
		builder.summary = "post-reset reprocessing matches a fresh instance"
	}
	return builder
}

// ---------------------------------------------------------------------------
// Tail and paired-input perturbation
// ---------------------------------------------------------------------------

last_non_silent_frame :: proc(planar: [][]f32, frames: int, threshold: f64) -> int {
	for frame := frames - 1; frame >= 0; frame -= 1 {
		for channel in 0 ..< 2 {
			if math.abs(f64(planar[channel][frame])) > threshold {
				return frame
			}
		}
	}
	return -1
}

probe_tail :: proc(ctx: ^Run_Context) -> Probe_Builder {
	builder := probe_start(
		"tail",
		"tail_boundedness",
		"Renders the program material then silence and measures the last frame above a documented threshold. Boundedness is an observation for this input and threshold, never a claim that the processor reached mathematical zero.",
	)
	silence_frames := ctx.scenario.tail.silence_frames
	result := render(ctx, Render_Request{
		partition = ctx.scenario.partitions[0],
		frames = ctx.scenario.input.frames,
		silence_frames = silence_frames,
		capture = ctx.scenario.telemetry.enabled,
	})
	defer destroy_render(&result)
	if !result.ok {
		probe_fail(&builder, "tail render failed")
		return builder
	}
	amplitude := math.abs(ctx.scenario.input.amplitude * ctx.scenario.input.channel_scale[0])
	threshold := max(1e-9, amplitude * math.pow(10.0, ctx.scenario.tail.threshold_db / 20.0))
	last := last_non_silent_frame(result.output, result.output_frames, threshold)
	tail_frames := max(last - ctx.scenario.input.frames + 1, 0)
	count, _, _ := nonfinite_scan(result.output)
	metric_add_int(&builder, "program_frames", ctx.scenario.input.frames)
	metric_add_int(&builder, "silence_frames", silence_frames)
	metric_add_int(&builder, "last_non_silent_frame", last)
	metric_add_int(&builder, "measured_tail_frames", tail_frames)
	metric_add_int(&builder, "declared_tail_frames", int(result.declared_tail_frames))
	metric_add_int(&builder, "nonfinite_samples", count)
	metric_add_f64(&builder, "threshold", threshold, "amplitude")
	metric_add_f64(&builder, "threshold_db", ctx.scenario.tail.threshold_db, "dBFS")
	if count != 0 {
		probe_fail(&builder, "tail output contains NaN or Inf")
	}
	if tail_frames >= silence_frames {
		probe_fail(&builder, "output did not fall below the threshold within the declared silence window")
	}
	if result.declared_tail_frames == 0 && tail_frames > 0 {
		detail_add(&builder, "declared clap.tail is 0 but the measured tail is non-zero; report both, do not infer convergence")
	} else if result.declared_tail_frames > 0 && tail_frames > int(result.declared_tail_frames) {
		detail_add(&builder, "measured tail exceeds the plugin's declared tail hint")
	}
	if builder.status == .Pass {
		builder.summary = fmt.aprintf(
			"tail fell below %.1f dBFS after %d frames (declared hint %d)",
			ctx.scenario.tail.threshold_db,
			tail_frames,
			result.declared_tail_frames,
		)
	}
	add_output_artifact(ctx, "tail_output", "tail.wav", result.output, result.output_frames)
	return builder
}

probe_perturbation :: proc(ctx: ^Run_Context) -> Probe_Builder {
	builder := probe_start(
		"perturbation",
		"paired_input_response",
		"A single-sample input delta is applied to a copy of the input; the differing output window is measured. This is a response window for this input, not a proof of finite impulse-response support.",
	)
	delta_frame := clamp(ctx.scenario.perturbation.delta_frame, 0, ctx.scenario.input.frames - 1)
	perturbed := make([][]f32, 2)
	for channel in 0 ..< 2 {
		perturbed[channel] = make([]f32, ctx.scenario.input.frames)
		copy(perturbed[channel], ctx.input[channel])
	}
	defer destroy_input(perturbed)
	perturbed[0][delta_frame] += f32(ctx.scenario.perturbation.delta)

	baseline := render(ctx, Render_Request{
		partition = ctx.scenario.partitions[0],
		frames = ctx.scenario.input.frames,
		silence_frames = ctx.scenario.tail.silence_frames,
	})
	defer destroy_render(&baseline)
	changed := render(ctx, Render_Request{
		partition = ctx.scenario.partitions[0],
		frames = ctx.scenario.input.frames,
		input = perturbed,
		silence_frames = ctx.scenario.tail.silence_frames,
	})
	defer destroy_render(&changed)
	if !baseline.ok || !changed.ok {
		probe_fail(&builder, "perturbation render failed")
		return builder
	}
	total := min(baseline.output_frames, changed.output_frames)
	first := -1
	last := -1
	for frame in 0 ..< total {
		differ := false
		for channel in 0 ..< 2 {
			if transmute(u32)baseline.output[channel][frame] != transmute(u32)changed.output[channel][frame] {
				differ = true
				break
			}
		}
		if differ {
			if first < 0 {
				first = frame
			}
			last = frame
		}
	}
	response := last >= first && first >= 0 ? last - first + 1 : 0
	metric_add_int(&builder, "delta_frame", delta_frame)
	metric_add_f64(&builder, "delta", ctx.scenario.perturbation.delta)
	metric_add_int(&builder, "first_differing_frame", first)
	metric_add_int(&builder, "last_differing_frame", last)
	metric_add_int(&builder, "response_frames", response)
	metric_add_int(&builder, "rendered_frames", total)
	if response == 0 {
		probe_fail(&builder, "single-sample delta produced no output change")
	}
	if last >= baseline.output_frames - 1 {
		detail_add(&builder, "response still differs at the last rendered frame; the measured window is a lower bound")
	}
	metric_add_int(&builder, "declared_tail_frames", int(baseline.declared_tail_frames))
	if builder.status == .Pass {
		builder.summary = fmt.aprintf(
			"delta at frame %d affects %d output frames starting at %d",
			delta_frame,
			response,
			first,
		)
	}
	return builder
}
