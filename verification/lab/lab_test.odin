// Unit tests for the independent references and evidence plumbing.
package verification_lab

import "core:encoding/json"
import "core:math"
import "core:os"
import "core:testing"

@(test)
test_sha256_known_vector :: proc(t: ^testing.T) {
	digest := sha256_hex_string("abc")
	testing.expect_value(
		t,
		digest,
		"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
	)
	delete(digest)
}

@(test)
test_naive_dft_exact_bin_and_amplitude :: proc(t: ^testing.T) {
	n := 1024
	bin := 64
	samples := make([]f32, n)
	defer delete(samples)
	for frame in 0 ..< n {
		samples[frame] = f32(0.5 * math.sin(math.TAU * f64(bin) * f64(frame) / f64(n)))
	}
	magnitudes := naive_dft(samples)
	defer delete(magnitudes)
	peak := naive_dft_peak_bin(magnitudes)
	testing.expect_value(t, peak, bin)
	testing.expect(t, math.abs(magnitudes[bin] - 0.5) < 1e-6, "DFT amplitude equals the sine amplitude")
	testing.expect(t, magnitudes[0] < 1e-6, "DC bin is near zero (integer number of periods)")
}

@(test)
test_window_measure_closed_form :: proc(t: ^testing.T) {
	frames := 512
	input := make([][]f32, 2)
	defer destroy_input(input)
	for channel in 0 ..< 2 {
		input[channel] = make([]f32, frames)
	}
	for frame in 0 ..< frames {
		input[0][frame] = 0.5
		input[1][frame] = -0.25
	}
	measured := measure_window(input, 0, frames)
	testing.expect_value(t, measured.frames, frames)
	testing.expect_value(t, measured.peak[0], f64(0.5))
	testing.expect_value(t, measured.peak[1], f64(0.25))
	testing.expect_value(t, measured.peak_frame[0], 0)
	testing.expect_value(t, measured.rms[0], f64(0.5))
	testing.expect_value(t, measured.rms[1], f64(0.25))

	sine := make([][]f32, 2)
	defer destroy_input(sine)
	for channel in 0 ..< 2 {
		sine[channel] = make([]f32, frames)
	}
	for frame in 0 ..< frames {
		value := f32(0.8 * math.sin(math.TAU * 32.0 * f64(frame) / f64(frames)))
		sine[0][frame] = value
		sine[1][frame] = value
	}
	sine_measured := measure_window(sine, 0, frames)
	testing.expect(t, math.abs(sine_measured.peak[0] - 0.8) < 1e-6, "sine peak")
	testing.expect(
		t,
		math.abs(sine_measured.rms[0] - rms_closed_form_sine(0.8)) < 1e-6,
		"integer-bin sine RMS equals A/sqrt(2)",
	)
}

@(test)
test_nonfinite_scan_finds_nan_and_inf :: proc(t: ^testing.T) {
	input := make([][]f32, 2)
	defer destroy_input(input)
	for channel in 0 ..< 2 {
		input[channel] = make([]f32, 8)
	}
	input[0][3] = transmute(f32)u32(0x7FC0_0000)
	input[1][6] = f32(math.inf_f32(1))
	count, first, channel := nonfinite_scan(input)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, first, 3)
	testing.expect_value(t, channel, 0)
}

@(test)
test_partition_blocks_cover_frames_exactly :: proc(t: ^testing.T) {
	partitions := []Partition_Spec{
		{name = "512", block_sizes = []u32{512}},
		{name = "997", block_sizes = []u32{997}},
		{name = "irregular", irregular_seed = 987654321},
	}
	for partition in partitions {
		blocks := partition_blocks(partition, 16384)
		total := 0
		for size in blocks {
			testing.expect(t, size > 0 && size <= 1024, "block size is bounded")
			total += size
		}
		testing.expect_value(t, total, 16384)
		delete(blocks)
	}
}

@(test)
test_scenario_load_and_defaults :: proc(t: ^testing.T) {
	path := "carnival-verification-test-scenario.json"
	data := `{"schema":"carnival.verification.scenario/1","name":"t","probes":["nonfinite"]}`
	testing.expect(t, os.write_entire_file(path, data) == nil, "write scenario")
	defer os.remove(path)
	load, ok := scenario_load(path, context.temp_allocator)
	defer free_all(context.temp_allocator)
	testing.expect(t, ok, "load scenario")
	testing.expect_value(t, load.scenario.sample_rate, u32(48000))
	testing.expect_value(t, load.scenario.input.kind, "sine")
	testing.expect_value(t, len(load.scenario.partitions), 1)
	testing.expect_value(t, load.scenario.partitions[0].block_sizes[0], u32(512))
	testing.expect(t, scenario_has_probe(&load.scenario, "nonfinite"), "probe list")
	testing.expect(t, !scenario_has_probe(&load.scenario, "measurement"), "missing probe")
}

@(test)
test_wav_writer_header_and_size :: proc(t: ^testing.T) {
	path := "carnival-verification-test.wav"
	frames := 8
	input := make([][]f32, 2)
	defer destroy_input(input)
	for channel in 0 ..< 2 {
		input[channel] = make([]f32, frames)
	}
	testing.expect(t, write_wav_f32(path, input, frames, 48000), "write wav")
	defer os.remove(path)
	bytes, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil, "read wav")
	testing.expect_value(t, len(bytes), WAV_HEADER_BYTES + frames * 2 * 4)
	testing.expect_value(t, string(bytes[0:4]), "RIFF")
	testing.expect_value(t, string(bytes[8:12]), "WAVE")
	// channels at offset 22, sample rate at 24, bits at 34 (little endian).
	testing.expect_value(t, u16(bytes[22]) | u16(bytes[23]) << 8, u16(2))
	testing.expect_value(
		t,
		u32(bytes[24]) | u32(bytes[25]) << 8 | u32(bytes[26]) << 16 | u32(bytes[27]) << 24,
		u32(48000),
	)
	testing.expect_value(t, u16(bytes[34]) | u16(bytes[35]) << 8, u16(32))
}

@(test)
test_evidence_round_trips_through_json :: proc(t: ^testing.T) {
	evidence := Evidence{
		schema = EVIDENCE_SCHEMA,
		lab_revision = LAB_REVISION,
		abi = ABI_VERSION,
		probes = make([]Probe_Result, 1),
		hashes = make(map[string]string),
	}
	evidence.probes[0] = Probe_Result{
		id = "p",
		class = "c",
		status = "pass",
		applicability = "a",
		summary = "s",
	}
	evidence.hashes["scenario"] = "abc"
	defer delete(evidence.probes)
	defer delete(evidence.hashes)
	data, err := json.marshal(evidence, json.Marshal_Options{pretty = true})
	defer delete(data)
	testing.expect(t, err == nil, "read wav")
	parsed: Evidence
	defer free_all(context.temp_allocator)
	testing.expect(t, json.unmarshal(data, &parsed, allocator = context.temp_allocator) == nil, "unmarshal evidence")
	testing.expect_value(t, parsed.schema, EVIDENCE_SCHEMA)
	testing.expect_value(t, parsed.probes[0].status, "pass")
	testing.expect_value(t, parsed.hashes["scenario"], "abc")
}
