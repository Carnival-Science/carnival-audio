// Capture-mode probes for the draft telemetry extension.
//
// These probes exercise the verification seam itself: enable/disable episodes,
// bounded-queue overflow and the dropped counter, and audio discontinuities
// injected through the host clock. They apply only to specimens that expose the
// extension (currently Pulse).
package verification_lab

import "core:fmt"

import clap "carnival:third_party/clap/abi"
import host "carnival:verification/host"

probe_capture_toggle :: proc(ctx: ^Run_Context) -> Probe_Builder {
	builder := probe_start(
		"capture_toggle",
		"capture_episode_semantics",
		"Enabling capture starts a fresh episode (queue cleared, dropped zeroed); disabling stops record production; re-enabling starts another episode. An episode switch requires quiescent processing: the host stops processing first. Live audio is unaffected. Main-thread calls only.",
	)
	if !ctx.scenario.telemetry.enabled {
		builder.status = .Skip
		builder.summary = "telemetry disabled in scenario"
		return builder
	}
	instance, opened := open_instance(ctx, ctx.scenario.max_block_frames, nil, false)
	if !opened {
		probe_fail(&builder, "could not open instance")
		return builder
	}
	defer host.instance_destroy(instance)
	if !host.instance_has_telemetry(instance) {
		builder.status = .Skip
		builder.summary = "specimen has no telemetry extension"
		return builder
	}
	// An episode switch requires quiescent processing.
	host.instance_stop(instance)
	if !host.instance_capture_enable(instance, true) {
		probe_fail(&builder, "capture enable failed")
		return builder
	}
	_ = host.instance_start(instance)
	metric_add_int(&builder, "schema_version", int(host.instance_capture_schema_version(instance)))
	quarter := ctx.scenario.input.frames / 4
	if quarter <= 0 {
		quarter = ctx.scenario.input.frames
	}
	output := make([][]f32, 2)
	for channel in 0 ..< 2 {
		output[channel] = make([]f32, ctx.scenario.input.frames)
	}
	defer destroy_input(output)
	collector := host.Capture_Collector{records = make([dynamic]clap.Carnival_Measurement_Record, 0, 64)}
	defer delete(collector.records)

	_ = process_range(instance, ctx.input, 0, quarter, output, 0)
	first_count := host.instance_capture_drain(instance, &collector)
	metric_add(&builder, "capture_valid_first_episode", fmt.aprintf("%v", host.instance_capture_valid(instance)))
	// An episode switch requires quiescent processing: stop, toggle, restart.
	host.instance_stop(instance)
	disable_ok := host.instance_capture_enable(instance, false)
	_ = host.instance_start(instance)
	_ = process_range(instance, ctx.input, quarter, quarter, output, quarter)
	second_count := host.instance_capture_drain(instance, &collector)
	host.instance_stop(instance)
	enable_ok := host.instance_capture_enable(instance, true)
	_ = host.instance_start(instance)
	_ = process_range(instance, ctx.input, quarter * 2, quarter, output, quarter * 2)
	third_count := host.instance_capture_drain(instance, &collector)
	metric_add_int(&builder, "records_first_episode", int(first_count))
	metric_add_int(&builder, "records_while_disabled", int(second_count))
	metric_add_int(&builder, "records_second_episode", int(third_count))
	metric_add(&builder, "disable_succeeded", fmt.aprintf("%v", disable_ok))
	metric_add(&builder, "reenable_succeeded", fmt.aprintf("%v", enable_ok))

	processed := quarter * 3
	if processed > ctx.scenario.input.frames {
		processed = ctx.scenario.input.frames
	}
	instance_output_hash := hash_planar([][]f32{
		output[0][:processed],
		output[1][:processed],
	}, processed)
	input_hash := hash_planar([][]f32{
		ctx.input[0][:processed],
		ctx.input[1][:processed],
	}, processed)
	metric_add(&builder, "input_hash", input_hash)
	metric_add(&builder, "output_hash", instance_output_hash)
	if !disable_ok || !enable_ok {
		probe_fail(&builder, "capture enable/disable returned false")
	}
	if first_count == 0 || third_count == 0 {
		probe_fail(&builder, "an enabled capture episode produced no records")
	}
	if second_count != 0 {
		probe_fail(&builder, "records were produced while capture was disabled")
	}
	if instance_output_hash != input_hash {
		probe_fail(&builder, "capture mode changed the audio output of a passthrough specimen")
	}
	if builder.status == .Pass {
		builder.summary = fmt.aprintf(
			"episode records %d / %d, disabled produced %d",
			first_count,
			third_count,
			second_count,
		)
	}
	return builder
}

probe_capture_overflow :: proc(ctx: ^Run_Context) -> Probe_Builder {
	builder := probe_start(
		"capture_overflow",
		"capture_queue_overflow",
		"Forces more canonical windows than the bounded queue holds without draining. Expect 4096 delivered records, a non-zero dropped counter, capture_valid false, and recovery on a new episode. Audio-domain validity is not touched.",
	)
	if !ctx.scenario.telemetry.enabled {
		builder.status = .Skip
		builder.summary = "telemetry disabled in scenario"
		return builder
	}
	window := ctx.scenario.measurement.window_frames
	QUEUE_CAPACITY :: 4096
	total_windows := QUEUE_CAPACITY + 104
	frames := window * total_windows
	input := generate_input(
		frames,
		f64(ctx.scenario.sample_rate),
		.Sine,
		997,
		0.1,
		{1, 1},
		0x1234,
		0,
		0,
	)
	defer destroy_input(input)
	result := render(ctx, Render_Request{
		partition = Partition_Spec{name = "overflow", block_sizes = []u32{512}},
		input = input,
		frames = frames,
		capture = true,
		drain_per_block = false,
	})
	defer destroy_render(&result)
	if !result.ok {
		probe_fail(&builder, "overflow render failed")
		return builder
	}
	if !result.telemetry_available {
		builder.status = .Skip
		builder.summary = "specimen has no telemetry extension"
		return builder
	}
	metric_add_int(&builder, "windows_requested", total_windows)
	metric_add_int(&builder, "records_delivered", len(result.records))
	metric_add_int(&builder, "dropped", int(result.dropped))
	metric_add(&builder, "capture_valid_after_overflow", fmt.aprintf("%v", result.capture_valid))
	expected_dropped := u64(total_windows - QUEUE_CAPACITY)
	if len(result.records) != QUEUE_CAPACITY {
		probe_fail(&builder, fmt.aprintf(
			"drained %d records, expected the bounded queue capacity %d",
			len(result.records),
			QUEUE_CAPACITY,
		))
	}
	if result.dropped != expected_dropped {
		probe_fail(&builder, fmt.aprintf(
			"dropped counter %d, expected %d",
			result.dropped,
			expected_dropped,
		))
	}
	if result.capture_valid {
		probe_fail(&builder, "capture_valid stayed true after records were dropped")
	}

	// A new episode must clear the queue, dropped counter and capture validity.
	instance, opened := open_instance(ctx, ctx.scenario.max_block_frames, nil, false)
	if opened {
		defer host.instance_destroy(instance)
		_ = host.instance_capture_enable(instance, true)
		metric_add_int(&builder, "dropped_after_new_episode", int(host.instance_capture_dropped(instance)))
		metric_add(&builder, "valid_after_new_episode", fmt.aprintf("%v", host.instance_capture_valid(instance)))
		if host.instance_capture_dropped(instance) != 0 || !host.instance_capture_valid(instance) {
			probe_fail(&builder, "a new capture episode did not reset dropped/capture_valid")
		}
	}
	if builder.status == .Pass {
		builder.summary = fmt.aprintf(
			"%d windows, %d delivered, %d dropped, capture invalid as expected",
			total_windows,
			len(result.records),
			result.dropped,
		)
	}
	return builder
}

probe_gap :: proc(ctx: ^Run_Context) -> Probe_Builder {
	builder := probe_start(
		"gap",
		"audio_discontinuity_segments",
		"The host skips an absolute input range and advances the steady sample clock. The wire record has no segment id, so this probe checks observable consequences: no window straddles the lost range, post-gap windows align to the post-gap frame, the affected boundary window is audio-invalid, and later contiguous windows are valid again while capture validity is unaffected.",
	)
	if !ctx.scenario.telemetry.enabled || len(ctx.scenario.gaps) == 0 {
		builder.status = .Skip
		builder.summary = "no gap schedule or telemetry disabled"
		return builder
	}
	gap := ctx.scenario.gaps[0]
	result := render(ctx, Render_Request{
		partition = ctx.scenario.partitions[0],
		frames = ctx.scenario.input.frames,
		gaps = ctx.scenario.gaps,
		capture = true,
	})
	defer destroy_render(&result)
	if !result.ok {
		probe_fail(&builder, "gap render failed")
		return builder
	}
	if !result.telemetry_available {
		builder.status = .Skip
		builder.summary = "specimen has no telemetry extension"
		return builder
	}
	gap_start := gap.start_frame
	gap_end := gap.start_frame + gap.frames
	metric_add_int(&builder, "gap_start_frame", gap_start)
	metric_add_int(&builder, "gap_frames", gap.frames)
	metric_add_int(&builder, "records", len(result.records))

	pre_records := 0
	post_records := 0
	overlapping := 0
	first_post_start := i64(-1)
	first_post_invalid := false
	later_post_valid := 0
	later_post_invalid := 0
	for record in result.records {
		start := int(record.start_frame)
		end := start + int(record.frames)
		if end <= gap_start {
			pre_records += 1
			if !record.valid {
				probe_fail(&builder, "a pre-gap record is audio-invalid")
			}
		} else if start >= gap_end {
			post_records += 1
			if first_post_start < 0 {
				first_post_start = record.start_frame
				first_post_invalid = !record.valid && record.overrun
			} else if record.valid && !record.overrun {
				later_post_valid += 1
			} else {
				later_post_invalid += 1
			}
		} else {
			overlapping += 1
		}
	}
	metric_add_int(&builder, "pre_gap_records", pre_records)
	metric_add_int(&builder, "post_gap_records", post_records)
	metric_add_int(&builder, "records_straddling_gap", overlapping)
	metric_add_int(&builder, "first_post_gap_start", int(first_post_start))
	metric_add_int(&builder, "first_post_gap_invalid", int(first_post_invalid))
	metric_add_int(&builder, "later_post_gap_valid", later_post_valid)
	metric_add_int(&builder, "later_post_gap_invalid", later_post_invalid)
	if overlapping != 0 {
		probe_fail(&builder, "a measurement window straddles the lost range")
	}
	if first_post_start != i64(gap_end) {
		probe_fail(&builder, fmt.aprintf(
			"first post-gap window starts at %d, expected the post-gap frame %d",
			first_post_start,
			gap_end,
		))
	}
	if post_records == 0 {
		probe_fail(&builder, "no post-gap records were produced")
	}
	// Finding 3: the affected/boundary window is invalid, but the epoch does
	// not stay latched. Later windows with contiguous data are valid again.
	if post_records > 0 && !first_post_invalid {
		probe_fail(&builder, "the first post-gap (affected) window is still marked audio-valid")
	}
	if later_post_invalid != 0 {
		probe_fail(&builder, fmt.aprintf(
			"%d post-gap records after the affected window are still audio-invalid",
			later_post_invalid,
		))
	}
	if later_post_valid == 0 && post_records > 1 {
		probe_fail(&builder, "no later post-gap record became audio-valid in the new segment")
	}
	if !result.capture_valid {
		probe_fail(&builder, "lost audio must not invalidate the capture domain")
	}
	if builder.status == .Pass {
		builder.summary = fmt.aprintf(
			"gap [%d,%d) recorded; first post-gap window at %d is the invalid affected window, %d later windows are audio-valid",
			gap_start,
			gap_end,
			first_post_start,
			later_post_valid,
		)
	}
	return builder
}
