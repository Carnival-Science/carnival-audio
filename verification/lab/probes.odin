// Probe implementations: rendering, measurement verification, partition.
//
// Every probe creates its own plugin instance(s) from the loaded library, so a
// probe cannot inherit processing state from another probe. Cross-process
// repeatability is the runner's job (it invokes the same scenario twice and
// compares artifact hashes); in-process repeatability uses fresh instances.
package verification_lab

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

import clap "carnival:third_party/clap/abi"
import host "carnival:verification/host"

Run_Context :: struct {
	scenario:      ^Scenario,
	library:       ^host.Library,
	out_dir:       string,
	scenario_hash: string,
	plugin_hash:   string,
	input:         [][]f32,
	artifacts:     [dynamic]Artifact,
	results:       [dynamic]Probe_Result,
}

Probe_Builder :: struct {
	id:            string,
	class:         string,
	status:        Probe_Status,
	applicability: string,
	summary:       string,
	metrics:       [dynamic]Metric,
	details:       [dynamic]string,
}

probe_start :: proc(id, class, applicability: string) -> Probe_Builder {
	return Probe_Builder{
		id = id,
		class = class,
		status = .Pass,
		applicability = applicability,
	}
}

metric_add :: proc(builder: ^Probe_Builder, name: string, value: string, unit := "") {
	append(&builder.metrics, Metric{name = name, value = value, unit = unit})
}

metric_add_f64 :: proc(builder: ^Probe_Builder, name: string, value: f64, unit := "") {
	metric_add(builder, name, fmt.aprintf("%.12g", value), unit)
}

metric_add_int :: proc(builder: ^Probe_Builder, name: string, value: int, unit := "") {
	metric_add(builder, name, fmt.aprintf("%d", value), unit)
}

detail_add :: proc(builder: ^Probe_Builder, text: string) {
	append(&builder.details, text)
}

probe_fail :: proc(builder: ^Probe_Builder, summary: string) {
	builder.status = .Fail
	builder.summary = summary
}

probe_finish :: proc(ctx: ^Run_Context, builder: ^Probe_Builder) {
	append(&ctx.results, Probe_Result{
		id = builder.id,
		class = builder.class,
		status = probe_status_name(builder.status),
		applicability = builder.applicability,
		summary = builder.summary,
		metrics = builder.metrics[:],
		details = builder.details[:],
	})
}

// ---------------------------------------------------------------------------
// Instance and rendering helpers
// ---------------------------------------------------------------------------

open_instance :: proc(
	ctx: ^Run_Context,
	max_frames: u32,
	params: []Param_Setting,
	capture: bool,
) -> (^host.Instance, bool) {
	instance, created := host.instance_create(
		ctx.library,
		ctx.scenario.specimen.id,
		max_frames,
		context.allocator,
	)
	if !created {
		return nil, false
	}
	if !host.instance_init(instance) {
		host.instance_destroy(instance)
		return nil, false
	}
	if !host.instance_activate(instance, f64(ctx.scenario.sample_rate), 1, max_frames) {
		host.instance_destroy(instance)
		return nil, false
	}
	for setting in ctx.scenario.params {
		_ = host.instance_set_param(instance, setting.id, setting.value)
	}
	for setting in params {
		_ = host.instance_set_param(instance, setting.id, setting.value)
	}
	if capture && host.instance_has_telemetry(instance) {
		if !host.instance_capture_enable(instance, true) {
			host.instance_destroy(instance)
			return nil, false
		}
	}
	if !host.instance_start(instance) {
		host.instance_destroy(instance)
		return nil, false
	}
	return instance, true
}

Render_Request :: struct {
	partition:       Partition_Spec,
	input:           [][]f32,
	frames:          int,
	events:          []Event_Spec,
	gaps:            []Gap_Spec,
	capture:         bool,
	drain_per_block: bool,
	silence_frames:  int,
	params:          []Param_Setting,
}

Render_Result :: struct {
	output:             [][]f32,
	output_frames:      int,
	records:            [dynamic]clap.Carnival_Measurement_Record,
	output_hash:        string,
	record_hash:        string,
	dropped:             u64,
	capture_valid:       bool,
	telemetry_available: bool,
	schema_version:      u32,
	declared_tail_frames: u32,
	ok:                  bool,
}

destroy_render :: proc(result: ^Render_Result) {
	if result.output != nil {
		destroy_input(result.output)
	}
	if result.records != nil {
		delete(result.records)
	}
}

// render drives one fresh instance through the request. Gaps are absolute input
// ranges that are never fed to the plugin; the host steady clock jumps over
// them, which is how a source discontinuity reaches the plugin.
render :: proc(ctx: ^Run_Context, request: Render_Request) -> Render_Result {
	result: Render_Result
	input := request.input
	if input == nil {
		input = ctx.input
	}
	frames := request.frames
	if frames <= 0 {
		frames = ctx.scenario.input.frames
	}
	total_output := frames + request.silence_frames
	result.output = make([][]f32, 2, context.allocator)
	for channel in 0 ..< 2 {
		result.output[channel] = make([]f32, total_output, context.allocator)
	}
	max_frames := ctx.scenario.max_block_frames
	instance, opened := open_instance(ctx, max_frames, request.params, request.capture)
	if !opened {
		return result
	}
	defer host.instance_destroy(instance)
	result.telemetry_available = host.instance_has_telemetry(instance)
	result.schema_version = host.instance_capture_schema_version(instance)

	blocks := partition_blocks(request.partition, frames, context.allocator)
	defer delete(blocks)
	absolute := 0
	out_index := 0
	block_index := 0
	collector := host.Capture_Collector{records = make([dynamic]clap.Carnival_Measurement_Record, 0, 64)}
	defer delete(collector.records)

	for absolute < frames {
		// Find the next gap that starts at or after the current frame.
		gap_start := -1
		gap_frames := 0
		for gap in request.gaps {
			if gap.frames <= 0 {
				continue
			}
			end := gap.start_frame + gap.frames
			if absolute >= gap.start_frame && absolute < end {
				// Inside a gap: skip the remainder and continue.
				absolute = end
				gap_start = -1
				break
			}
			if gap.start_frame > absolute && (gap_start < 0 || gap.start_frame < gap_start) {
				gap_start = gap.start_frame
				gap_frames = gap.frames
			}
		}
		if absolute >= frames {
			break
		}
		if gap_start == absolute {
			absolute += gap_frames
			continue
		}
		if block_index >= len(blocks) {
			break
		}
		size := blocks[block_index]
		block_index += 1
		if gap_start > absolute {
			size = min(size, gap_start - absolute)
		}
		if size <= 0 {
			break
		}
		input_slices := [][]f32{input[0][absolute:absolute + size], input[1][absolute:absolute + size]}
		output_slices := [][]f32{
			result.output[0][out_index:out_index + size],
			result.output[1][out_index:out_index + size],
		}
		events := build_block_events(request.events, absolute, size, context.allocator)
		transport := make_transport(ctx, absolute)
		transport_ptr: ^clap.Event_Transport
		if ctx.scenario.transport.enabled {
			transport_ptr = &transport
		}
		status, called := host.instance_process(
			instance,
			u32(size),
			input_slices,
			output_slices,
			i64(absolute),
			events,
			transport_ptr,
		)
		delete(events)
		if !called || status == clap.CLAP_PROCESS_ERROR {
			result.ok = false
			return result
		}
		out_index += size
		absolute += size
		if request.drain_per_block {
			_ = host.instance_capture_drain(instance, &collector)
		}
	}

	// Tail/silence rendering: feed zeros after the program material. This is
	// part of the output artifact only for tail probes.
	if request.silence_frames > 0 {
		zeroes := make([][]f32, 2, context.temp_allocator)
		zeroes[0] = make([]f32, int(max_frames), context.temp_allocator)
		zeroes[1] = make([]f32, int(max_frames), context.temp_allocator)
		defer {
			delete(zeroes[0], context.temp_allocator)
			delete(zeroes[1], context.temp_allocator)
		}
		remaining := request.silence_frames
		for remaining > 0 {
			size := min(int(max_frames), remaining)
			output_slices := [][]f32{
				result.output[0][out_index:out_index + size],
				result.output[1][out_index:out_index + size],
			}
			transport := make_transport(ctx, absolute)
			transport_ptr: ^clap.Event_Transport
			if ctx.scenario.transport.enabled {
				transport_ptr = &transport
			}
			status, called := host.instance_process(
				instance,
				u32(size),
				zeroes,
				output_slices,
				i64(absolute),
				nil,
				transport_ptr,
			)
			if !called || status == clap.CLAP_PROCESS_ERROR {
				result.ok = false
				return result
			}
			out_index += size
			absolute += size
			remaining -= size
			if request.drain_per_block {
				_ = host.instance_capture_drain(instance, &collector)
			}
		}
	}

	_ = host.instance_capture_drain(instance, &collector)
	result.declared_tail_frames = host.instance_tail_frames(instance)
	result.records = collector.records
	collector.records = nil
	result.dropped = host.instance_capture_dropped(instance)
	result.capture_valid = host.instance_capture_valid(instance)
	result.output_frames = out_index
	result.output_hash = hash_planar(result.output, out_index, context.allocator)
	result.record_hash = hash_records(result.records[:], context.allocator)
	result.ok = true
	return result
}

// make_transport builds the optional CLAP transport event for a block. The
// timestamp is derived from the absolute frame so a scenario can describe a
// deterministic timeline even though the specimens in this census do not read
// transport yet.
make_transport :: proc(ctx: ^Run_Context, absolute: int) -> clap.Event_Transport {
	transport: clap.Event_Transport
	if !ctx.scenario.transport.enabled {
		return transport
	}
	flags := clap.CLAP_TRANSPORT_HAS_TEMPO | clap.CLAP_TRANSPORT_HAS_SECONDS_TIMELINE
	if ctx.scenario.transport.playing {
		flags |= clap.CLAP_TRANSPORT_IS_PLAYING
	}
	seconds := ctx.scenario.transport.position_seconds + f64(absolute) / f64(ctx.scenario.sample_rate)
	transport = clap.Event_Transport{
		header = clap.Event_Header{
			size = u32(size_of(clap.Event_Transport)),
			time = 0,
			space_id = clap.CLAP_CORE_EVENT_SPACE_ID,
			type = u16(clap.Event_Type.Transport),
		},
		flags = flags,
		tempo = ctx.scenario.transport.tempo,
		song_pos_seconds = clap.Sectime(seconds * f64(clap.CLAP_SECTIME_FACTOR)),
	}
	return transport
}

build_block_events :: proc(
	events: []Event_Spec,
	absolute, frames: int,
	allocator := context.allocator,
) -> []clap.Event_Param_Value {
	count := 0
	for event in events {
		frame := int(event.frame)
		if frame >= absolute && frame < absolute + frames {
			count += 1
		}
	}
	if count == 0 {
		return nil
	}
	result := make([]clap.Event_Param_Value, count, allocator)
	position := 0
	for event in events {
		frame := int(event.frame)
		if frame < absolute || frame >= absolute + frames {
			continue
		}
		result[position] = clap.Event_Param_Value{
			header = clap.Event_Header{
				size = u32(size_of(clap.Event_Param_Value)),
				time = u32(frame - absolute),
				space_id = clap.CLAP_CORE_EVENT_SPACE_ID,
				type = u16(clap.Event_Type.Param_Value),
			},
			param_id = event.param_id,
			note_id = -1,
			port_index = -1,
			channel = -1,
			key = -1,
			value = event.value,
		}
		position += 1
	}
	return result
}

hash_planar :: proc(planar: [][]f32, frames: int, allocator := context.allocator) -> string {
	if planar == nil || frames <= 0 {
		return sha256_hex_string("empty", allocator)
	}
	channels := len(planar)
	bytes := make([]u8, frames * channels * 4, allocator)
	defer delete(bytes, allocator)
	position := 0
	for frame in 0 ..< frames {
		for channel in 0 ..< channels {
			bits := transmute(u32)planar[channel][frame]
			bytes[position + 0] = u8(bits)
			bytes[position + 1] = u8(bits >> 8)
			bytes[position + 2] = u8(bits >> 16)
			bytes[position + 3] = u8(bits >> 24)
			position += 4
		}
	}
	return sha256_hex(bytes, allocator)
}

hash_records :: proc(records: []clap.Carnival_Measurement_Record, allocator := context.allocator) -> string {
	if len(records) == 0 {
		return sha256_hex_string("no-records", allocator)
	}
	builder := strings.builder_make(allocator)
	defer strings.builder_destroy(&builder)
	for record in records {
		fmt.sbprintf(
			&builder,
			"%d,%d,%d,%d,%d,%d,%d,%08x,%d,%08x,%d,%08x,%08x,%08x,%d,%d,%08x\n",
			record.schema_version,
			record.epoch,
			record.generation,
			record.start_frame,
			record.frames,
			record.channels,
			record.sample_rate,
			transmute(u32)record.peak[0],
			record.peak_frame[0],
			transmute(u32)record.peak[1],
			record.peak_frame[1],
			transmute(u32)record.rms[0],
			transmute(u32)record.rms[1],
			transmute(u32)record.hold[0],
			int(record.valid),
			int(record.overrun),
			transmute(u32)record.hold[1],
		)
		fmt.sbprintf(
			&builder,
			"  capture_valid=%d\n",
			int(record.capture_valid),
		)
	}
	return sha256_hex_string(strings.to_string(builder), allocator)
}

records_equal :: proc(a, b: clap.Carnival_Measurement_Record) -> bool {
	if a.schema_version != b.schema_version || a.epoch != b.epoch ||
		a.generation != b.generation || a.start_frame != b.start_frame ||
		a.frames != b.frames || a.channels != b.channels ||
		a.sample_rate != b.sample_rate || a.valid != b.valid ||
		a.overrun != b.overrun || a.capture_valid != b.capture_valid {
		return false
	}
	for channel in 0 ..< 2 {
		if transmute(u32)a.peak[channel] != transmute(u32)b.peak[channel] ||
			a.peak_frame[channel] != b.peak_frame[channel] ||
			transmute(u32)a.rms[channel] != transmute(u32)b.rms[channel] ||
			transmute(u32)a.hold[channel] != transmute(u32)b.hold[channel] {
			return false
		}
	}
	return true
}

first_record_difference :: proc(a, b: []clap.Carnival_Measurement_Record) -> int {
	common := min(len(a), len(b))
	for index in 0 ..< common {
		if !records_equal(a[index], b[index]) {
			return index
		}
	}
	if len(a) != len(b) {
		return common
	}
	return -1
}

first_output_difference :: proc(
	a, b: [][]f32,
	frames: int,
) -> (index: int, max_delta: f64) {
	index = -1
	for channel in 0 ..< min(len(a), len(b)) {
		for frame in 0 ..< frames {
			delta := math.abs(f64(a[channel][frame]) - f64(b[channel][frame]))
			if delta > max_delta {
				max_delta = delta
			}
			if index < 0 && transmute(u32)a[channel][frame] != transmute(u32)b[channel][frame] {
				index = frame
			}
		}
	}
	return
}

add_output_artifact :: proc(
	ctx: ^Run_Context,
	kind, filename: string,
	planar: [][]f32,
	frames: int,
) {
	path := fmt.aprintf("%s/%s", ctx.out_dir, filename)
	if !write_wav_f32(path, planar, frames, ctx.scenario.sample_rate) {
		return
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	digest := ""
	if err == nil {
		digest = sha256_hex(data, context.temp_allocator)
	}
	artifact_add(
		&ctx.artifacts,
		kind,
		filename,
		digest,
		len(data),
		frames,
		2,
		ctx.scenario.sample_rate,
	)
}

// ---------------------------------------------------------------------------
// Measurement probe (Pulse canonical records)
// ---------------------------------------------------------------------------

probe_measurement :: proc(ctx: ^Run_Context) -> Probe_Builder {
	builder := probe_start(
		"measurement",
		"canonical_measurement",
		"Applies to specimens exposing the draft telemetry extension. Expected values come from verification-local peak/RMS arithmetic over the input WAV, not from the plugin.",
	)
	if !ctx.scenario.measurement.enabled {
		builder.status = .Skip
		builder.summary = "measurement disabled in scenario"
		return builder
	}
	partition := ctx.scenario.partitions[0]
	result := render(ctx, Render_Request{
		partition = partition,
		frames = ctx.scenario.input.frames,
		capture = true,
		drain_per_block = false,
	})
	defer destroy_render(&result)
	if !result.ok {
		probe_fail(&builder, "render failed or plugin returned CLAP_PROCESS_ERROR")
		return builder
	}
	if !result.telemetry_available {
		builder.status = .Skip
		builder.summary = "specimen does not expose the draft telemetry extension"
		return builder
	}
	window := ctx.scenario.measurement.window_frames
	expected_records := ctx.scenario.input.frames / window
	metric_add_int(&builder, "records", len(result.records))
	metric_add_int(&builder, "expected_records", expected_records)
	if len(result.records) != expected_records {
		probe_fail(&builder, fmt.aprintf(
			"record count %d, expected %d complete windows",
			len(result.records),
			expected_records,
		))
	}
	if result.schema_version != ctx.scenario.measurement.schema_version {
		probe_fail(&builder, "telemetry schema version differs from the scenario expectation")
	}
	metric_add_int(&builder, "schema_version", int(result.schema_version))

	max_peak_diff := f64(0)
	max_rms_diff := f64(0)
	max_hold_diff := f64(0)
	peak_frame_mismatches := 0
	invalid_records := 0
	running_peak: [2]f64
	hold_decay := ctx.scenario.measurement.hold_decay
	for record, index in result.records {
		if index >= expected_records {
			break
		}
		measured := measure_window(ctx.input, int(record.start_frame), int(record.frames))
		if int(record.start_frame) != index * window {
			probe_fail(&builder, fmt.aprintf(
				"record %d start_frame %d, expected %d",
				index,
				record.start_frame,
				index * window,
			))
			break
		}
		for channel in 0 ..< 2 {
			peak_diff := math.abs(f64(record.peak[channel]) - measured.peak[channel])
			rms_diff := math.abs(f64(record.rms[channel]) - measured.rms[channel])
			max_peak_diff = max(max_peak_diff, peak_diff)
			max_rms_diff = max(max_rms_diff, rms_diff)
			if int(record.peak_frame[channel]) != measured.peak_frame[channel] {
				peak_frame_mismatches += 1
			}
			if !hold_decay {
				running_peak[channel] = max(running_peak[channel], measured.peak[channel])
				hold_diff := math.abs(f64(record.hold[channel]) - running_peak[channel])
				max_hold_diff = max(max_hold_diff, hold_diff)
			}
		}
		if !record.valid || record.overrun || !record.capture_valid {
			invalid_records += 1
		}
		if record.schema_version != ctx.scenario.measurement.schema_version {
			probe_fail(&builder, "a record carries an unexpected schema_version")
			break
		}
	}
	metric_add_f64(&builder, "max_sample_peak_abs_diff", max_peak_diff, "amplitude")
	metric_add_f64(&builder, "max_rms_abs_diff", max_rms_diff, "amplitude")
	if !hold_decay {
		metric_add_f64(&builder, "max_hold_abs_diff", max_hold_diff, "amplitude")
	}
	metric_add_int(&builder, "peak_frame_mismatches", peak_frame_mismatches)
	metric_add_int(&builder, "invalid_records", invalid_records)
	if max_peak_diff != 0 {
		probe_fail(&builder, "sample peak differs from independent max|sample|")
	}
	if max_rms_diff > 1e-7 {
		probe_fail(&builder, "RMS differs from independent f64 sum-of-squares reference")
	}
	if !hold_decay && max_hold_diff > 1e-7 {
		probe_fail(&builder, "peak hold differs from the running maximum (decay off)")
	}
	if peak_frame_mismatches != 0 {
		probe_fail(&builder, "peak frame is not the first maximum")
	}
	if invalid_records != 0 {
		probe_fail(&builder, "a record is invalid in a gapless continuous run")
	}

	// Perturbation applicability: the canonical records must move when the input
	// moves, and (from the repeatability probe) stay identical on a no-op
	// re-render. This is the measurement-domain version of the perturbation
	// probe, so a meter that ignores its input cannot pass by being deterministic.
	perturbed := make([][]f32, 2, context.allocator)
	for channel in 0 ..< 2 {
		perturbed[channel] = make([]f32, ctx.scenario.input.frames, context.allocator)
		copy(perturbed[channel], ctx.input[channel])
	}
	defer destroy_input(perturbed)
	perturb_frame := clamp(ctx.scenario.perturbation.delta_frame, 0, ctx.scenario.input.frames - 1)
	perturbed[0][perturb_frame] += f32(ctx.scenario.perturbation.delta)
	perturbed_result := render(ctx, Render_Request{
		partition = partition,
		frames = ctx.scenario.input.frames,
		input = perturbed,
		capture = true,
	})
	defer destroy_render(&perturbed_result)
	if !perturbed_result.ok {
		probe_fail(&builder, "perturbation render failed")
	} else {
		changed := perturbed_result.record_hash != result.record_hash
		metric_add(&builder, "record_hash_changed_by_perturbation", fmt.aprintf("%v", changed))
		if !changed {
			probe_fail(&builder, "canonical records did not change when the input changed")
		}
	}
	detail_add(&builder, "RMS reference: sqrt(sum(x^2)/N) accumulated in f64 from the input samples")
	detail_add(&builder, "Peak reference: max|x| and its first frame, computed from the input samples")
	detail_add(&builder, "Tolerance: peak and peak_frame exact; RMS and hold 1e-7 absolute; observed environment recorded separately")
	if builder.status == .Pass {
		builder.summary = fmt.aprintf(
			"%d records match independent peak/RMS/hold references",
			len(result.records),
		)
	}
	add_output_artifact(ctx, "output", "output.wav", result.output, result.output_frames)
	add_records_artifact(ctx, "records.csv", result.records[:])
	return builder
}

// write_canonical_artifacts renders the first static partition once and writes
// `output.wav` and (when telemetry exists) `records.csv`. The runner uses these
// hashes to check repeatability across fresh worker processes.
write_canonical_artifacts :: proc(ctx: ^Run_Context) {
	result := render(ctx, Render_Request{
		partition = ctx.scenario.partitions[0],
		frames = ctx.scenario.input.frames,
		capture = ctx.scenario.telemetry.enabled,
	})
	defer destroy_render(&result)
	if !result.ok {
		return
	}
	add_output_artifact(ctx, "output", "output.wav", result.output, result.output_frames)
	if result.telemetry_available {
		add_records_artifact(ctx, "records.csv", result.records[:])
	}
}

add_records_artifact :: proc(
	ctx: ^Run_Context,
	filename: string,
	records: []clap.Carnival_Measurement_Record,
) {
	builder := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&builder)
	fmt.sbprintln(
		&builder,
		"schema,epoch,generation,start_frame,frames,channels,sample_rate,peak0,peak_frame0,peak1,peak_frame1,rms0,rms1,hold0,hold1,valid,overrun,capture_valid",
	)
	for record in records {
		fmt.sbprintf(
			&builder,
			"%d,%d,%d,%d,%d,%d,%d,%.9g,%d,%.9g,%d,%.9g,%.9g,%.9g,%.9g,%d,%d,%d\n",
			record.schema_version,
			record.epoch,
			record.generation,
			record.start_frame,
			record.frames,
			record.channels,
			record.sample_rate,
			record.peak[0],
			record.peak_frame[0],
			record.peak[1],
			record.peak_frame[1],
			record.rms[0],
			record.rms[1],
			record.hold[0],
			record.hold[1],
			int(record.valid),
			int(record.overrun),
			int(record.capture_valid),
		)
	}
	path := fmt.aprintf("%s/%s", ctx.out_dir, filename)
	text := strings.to_string(builder)
	if os.write_entire_file(path, text) != nil {
		return
	}
	artifact_add(
		&ctx.artifacts,
		"records",
		filename,
		sha256_hex_string(text, context.temp_allocator),
		len(text),
		len(records),
		0,
		ctx.scenario.sample_rate,
	)
}

// ---------------------------------------------------------------------------
// Independent spectral reference
// ---------------------------------------------------------------------------

probe_spectrum :: proc(ctx: ^Run_Context) -> Probe_Builder {
	builder := probe_start(
		"spectrum",
		"independent_dft",
		"Applies to passthrough specimens when the scenario uses an integer-bin sine. Uses the verification-local O(n^2) DFT over a bounded 1024-sample window.",
	)
	if !ctx.scenario.measurement.enabled {
		builder.status = .Skip
		builder.summary = "spectral probe is tied to the Pulse passthrough specimen"
		return builder
	}
	n := 1024
	if ctx.scenario.input.frames < n {
		builder.status = .Skip
		builder.summary = "input shorter than the DFT window"
		return builder
	}
	magnitudes := naive_dft(ctx.input[0][:n], context.temp_allocator)
	defer delete(magnitudes, context.temp_allocator)
	peak_bin := naive_dft_peak_bin(magnitudes)
	expected_bin := int(math.round(ctx.scenario.input.frequency_hz * f64(n) / f64(ctx.scenario.sample_rate)))
	metric_add_int(&builder, "dft_window", n)
	metric_add_int(&builder, "peak_bin", peak_bin)
	metric_add_int(&builder, "expected_bin", expected_bin)
	metric_add_f64(&builder, "peak_magnitude", magnitudes[peak_bin])
	// Integer-bin sine amplitude maps to magnitude == amplitude in this DFT
	// normalization (the +/- bin pair is folded by the *2/N factor).
	expected_magnitude := math.abs(ctx.scenario.input.amplitude * ctx.scenario.input.channel_scale[0])
	magnitude_diff := math.abs(magnitudes[peak_bin] - expected_magnitude)
	metric_add_f64(&builder, "magnitude_abs_diff", magnitude_diff)
	if peak_bin != expected_bin {
		probe_fail(&builder, "DFT peak is not at the generated sine bin")
	}
	if magnitude_diff > 1e-3 {
		probe_fail(&builder, "DFT magnitude differs from the closed-form sine amplitude")
	}
	detail_add(&builder, "naive_dft is O(n^2) by design; n=1024 here, no FFT and no shared transform code")
	if builder.status == .Pass {
		builder.summary = fmt.aprintf(
			"O(n^2) DFT peak bin %d matches the %g Hz generator bin",
			peak_bin,
			ctx.scenario.input.frequency_hz,
		)
	}
	return builder
}

// ---------------------------------------------------------------------------
// Non-finite output probe
// ---------------------------------------------------------------------------

probe_nonfinite :: proc(ctx: ^Run_Context) -> Probe_Builder {
	builder := probe_start(
		"nonfinite",
		"non_finite_output",
		"Scans every rendered output sample for NaN/Inf. Applicable to every specimen; a failure is a real output defect for this input.",
	)
	result := render(ctx, Render_Request{
		partition = ctx.scenario.partitions[0],
		frames = ctx.scenario.input.frames,
	})
	defer destroy_render(&result)
	if !result.ok {
		probe_fail(&builder, "render failed")
		return builder
	}
	count, first_frame, first_channel := nonfinite_scan(result.output)
	metric_add_int(&builder, "nonfinite_samples", count)
	if count > 0 {
		metric_add_int(&builder, "first_nonfinite_frame", first_frame)
		metric_add_int(&builder, "first_nonfinite_channel", first_channel)
		probe_fail(&builder, "output contains NaN or Inf")
	}
	if builder.status == .Pass {
		builder.summary = fmt.aprintf("%d output samples, all finite", result.output_frames * 2)
	}
	return builder
}

// ---------------------------------------------------------------------------
// Static-parameter partition invariance
// ---------------------------------------------------------------------------

probe_partition :: proc(ctx: ^Run_Context) -> Probe_Builder {
	builder := probe_start(
		"partition",
		"static_partition_invariance",
		"Same absolute input and static parameters rendered under different block partitions. Expected class for stateless and per-sample-state processors is byte-exact invariance; a difference is a specimen failure, not a tolerance question.",
	)
	if len(ctx.scenario.partitions) < 2 {
		builder.status = .Skip
		builder.summary = "scenario declares fewer than two partitions"
		return builder
	}
	first := render(ctx, Render_Request{
		partition = ctx.scenario.partitions[0],
		frames = ctx.scenario.input.frames,
		capture = ctx.scenario.telemetry.enabled,
	})
	defer destroy_render(&first)
	if !first.ok {
		probe_fail(&builder, "first partition render failed")
		return builder
	}
	metric_add(&builder, "reference_partition", ctx.scenario.partitions[0].name)
	metric_add(&builder, "reference_output_hash", first.output_hash)
	metric_add(&builder, "reference_record_hash", first.record_hash)
	differing := 0
	max_delta := f64(0)
	for partition, index in ctx.scenario.partitions {
		result := render(ctx, Render_Request{
			partition = partition,
			frames = ctx.scenario.input.frames,
			capture = ctx.scenario.telemetry.enabled,
		})
		defer destroy_render(&result)
		if !result.ok {
			probe_fail(&builder, fmt.aprintf("partition %s render failed", partition.name))
			return builder
		}
		add_output_artifact(
			ctx,
			"partition_output",
			fmt.aprintf("partition_%s.wav", partition.name),
			result.output,
			result.output_frames,
		)
		if result.telemetry_available {
			add_records_artifact(
				ctx,
				fmt.aprintf("partition_%s_records.csv", partition.name),
				result.records[:],
			)
		}
		if index == 0 {
			continue
		}
		if result.output_hash != first.output_hash {
			differing += 1
			delta_index, delta := first_output_difference(
				first.output,
				result.output,
				min(first.output_frames, result.output_frames),
			)
			max_delta = max(max_delta, delta)
			if delta_index >= 0 {
				detail_add(&builder, fmt.aprintf(
					"partition %s first differs at frame %d (max abs delta %.9g)",
					partition.name,
					delta_index,
					delta,
				))
			}
		}
		if result.telemetry_available {
			// Per-measure equality classes: a whole-record hash hides which
			// measurement moved. Report peak/RMS/hold/peak-frame deltas
			// separately when records exist on both sides.
			common := min(len(first.records), len(result.records))
			peak_delta := f64(0)
			rms_delta := f64(0)
			hold_delta := f64(0)
			peak_frame_mismatches := 0
			for record_index in 0 ..< common {
				a := first.records[record_index]
				b := result.records[record_index]
				for channel in 0 ..< 2 {
					peak_delta = max(peak_delta, math.abs(f64(a.peak[channel]) - f64(b.peak[channel])))
					rms_delta = max(rms_delta, math.abs(f64(a.rms[channel]) - f64(b.rms[channel])))
					hold_delta = max(hold_delta, math.abs(f64(a.hold[channel]) - f64(b.hold[channel])))
					if a.peak_frame[channel] != b.peak_frame[channel] {
						peak_frame_mismatches += 1
					}
				}
			}
			metric_add_f64(&builder, fmt.aprintf("measure_peak_delta_%s", partition.name), peak_delta)
			metric_add_f64(&builder, fmt.aprintf("measure_rms_delta_%s", partition.name), rms_delta)
			metric_add_f64(&builder, fmt.aprintf("measure_hold_delta_%s", partition.name), hold_delta)
			metric_add_int(
				&builder,
				fmt.aprintf("measure_peak_frame_mismatches_%s", partition.name),
				peak_frame_mismatches,
			)
			if result.record_hash != first.record_hash {
				differing += 1
				detail_add(&builder, fmt.aprintf(
					"partition %s canonical records differ (first mismatch index %d)",
					partition.name,
					first_record_difference(first.records[:], result.records[:]),
				))
			}
		}
	}
	metric_add_int(&builder, "partitions", len(ctx.scenario.partitions))
	metric_add_f64(&builder, "max_output_abs_delta", max_delta, "amplitude")
	if differing == 0 {
		builder.class = "static_partition_invariant"
		builder.summary = "byte-identical output and records across every declared partition"
	} else {
		builder.class = "static_partition_sensitive"
		probe_fail(&builder, "output or canonical records change with the block partition")
	}
	return builder
}

// ---------------------------------------------------------------------------
// In-process repeatability (fresh instances)
// ---------------------------------------------------------------------------

probe_repeatability :: proc(ctx: ^Run_Context) -> Probe_Builder {
	builder := probe_start(
		"repeatability",
		"fresh_instance_repeatability",
		"Two fresh instances in this process render the same scenario. Cross-process repeatability is checked by the runner repeating the run and comparing artifact hashes.",
	)
	first := render(ctx, Render_Request{
		partition = ctx.scenario.partitions[0],
		frames = ctx.scenario.input.frames,
	})
	defer destroy_render(&first)
	second := render(ctx, Render_Request{
		partition = ctx.scenario.partitions[0],
		frames = ctx.scenario.input.frames,
	})
	defer destroy_render(&second)
	if !first.ok || !second.ok {
		probe_fail(&builder, "a render failed")
		return builder
	}
	metric_add(&builder, "output_hash_1", first.output_hash)
	metric_add(&builder, "output_hash_2", second.output_hash)
	metric_add(&builder, "record_hash_1", first.record_hash)
	metric_add(&builder, "record_hash_2", second.record_hash)
	if first.output_hash != second.output_hash {
		probe_fail(&builder, "two fresh instances produced different output bytes")
	}
	if first.record_hash != second.record_hash {
		probe_fail(&builder, "two fresh instances produced different canonical records")
	}
	if builder.status == .Pass {
		builder.summary = "byte-identical output and records across two fresh instances"
	}
	return builder
}
