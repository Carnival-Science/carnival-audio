// Milestone 0 integration tests: golden vectors without binary fixtures,
// partition invariance, WAV round-trip, repeatability and a bounded-memory
// ceiling.
package tests

import "core:fmt"
import "core:math"
import "core:mem"
import "core:testing"

import analysis "pulse:core/analysis"
import audio "pulse:core/audio"
import transport "pulse:core/transport"

@(test)
test_golden_sine_rms_and_hann_bin :: proc(t: ^testing.T) {
	SAMPLE_RATE :: 48000
	FRAMES :: 4800
	samples := make([]f32, FRAMES * 2)
	defer delete(samples)
	testing.expect_value(t, audio.generate_sine(samples, SAMPLE_RATE, 2, 1000, 0.5), audio.Audio_Error.None)
	rms := analysis.rms_over(samples)
	// Closed form: amplitude 0.5 / sqrt(2). Literal, not computed by the code
	// under test.
	testing.expectf(t, math.abs(rms - 0.3535533905932738) < 1e-6, "sine RMS: %v", rms)
	expected_db := f32(-9.030899869919436)
	testing.expectf(t, math.abs(analysis.rms_to_dbfs(rms) - expected_db) < 1e-4,
		"sine dBFS: %v", analysis.rms_to_dbfs(rms))

	// Hann-windowed bin-centred tone: normalised amplitude equals the tone
	// amplitude (0.75) to within leakage tolerance.
	FFT_N :: 1024
	tone := make([]f32, FFT_N)
	defer delete(tone)
	frequency := f64(16 * SAMPLE_RATE) / f64(FFT_N)
	testing.expect_value(t, audio.generate_sine(tone, SAMPLE_RATE, 1, frequency, 0.75), audio.Audio_Error.None)
	plan: analysis.Real_FFT_Plan
	testing.expect_value(t, analysis.real_fft_plan_init(&plan, FFT_N, .Hann), analysis.FFT_Error.None)
	defer analysis.real_fft_plan_destroy(&plan)
	spectrum := make([]analysis.Complex32, FFT_N / 2 + 1)
	defer delete(spectrum)
	testing.expect(t, analysis.real_fft_forward(&plan, tone, spectrum), "forward")
	amplitude := analysis.real_fft_amplitude(&plan, spectrum, 16)
	testing.expectf(t, math.abs(amplitude - 0.75) < 1e-3, "Hann bin amplitude: %v", amplitude)
}

@(test)
test_golden_impulse_and_full_scale_square :: proc(t: ^testing.T) {
	impulse := make([]f32, 64)
	defer delete(impulse)
	testing.expect_value(t, audio.generate_impulse(impulse, 1, 0, 1), audio.Audio_Error.None)
	peak := analysis.sample_peak(audio.Audio_Block{frames = 64, channels = 1, interleaved = impulse})
	testing.expect(t, peak.valid, "impulse peak valid")
	testing.expect_value(t, peak.magnitude, f32(1))
	testing.expect_value(t, peak.frame, i64(0))

	square := make([]f32, 1000)
	defer delete(square)
	for index in 0 ..< len(square) {
		square[index] = -1
		if index % 2 == 0 {
			square[index] = 1
		}
	}
	square_rms := analysis.rms_over(square)
	testing.expect_value(t, square_rms, f32(1))
	testing.expect_value(t, analysis.rms_to_dbfs(square_rms), f32(0))
}

@(test)
test_partition_invariance_peak_rms_correlation :: proc(t: ^testing.T) {
	FRAMES :: 10000
	CHANNELS :: 2
	left := make([]f32, FRAMES)
	defer delete(left)
	right := make([]f32, FRAMES)
	defer delete(right)
	testing.expect_value(t, audio.generate_sine(left, 48000, 1, 997, 0.6), audio.Audio_Error.None)
	testing.expect_value(t, audio.generate_sine(right, 48000, 1, 997, 0.3, 0.4), audio.Audio_Error.None)
	samples := make([]f32, FRAMES * CHANNELS)
	defer delete(samples)
	planar := [][]f32{left, right}
	testing.expect(t, audio.interleave_f32(samples, planar, FRAMES, CHANNELS), "interleave")

	baseline := run_partitions(samples, FRAMES, CHANNELS, 128)
	testing.expect_value(t, baseline.rms.count, 9)
	testing.expect_value(t, baseline.correlation.count, 9)

	partitions := [?]int{64, 256, 512, 997}
	max_rms_difference := f32(0)
	max_correlation_difference := f32(0)
	for partition in partitions {
		result := run_partitions(samples, FRAMES, CHANNELS, partition)
		// Sample peak is exact by construction.
		testing.expectf(t, result.peak == baseline.peak,
			"partition %d peak differs: %v vs %v", partition, result.peak, baseline.peak)
		for channel in 0 ..< CHANNELS {
			testing.expectf(t, result.peak_channels[channel] == baseline.peak_channels[channel],
				"partition %d channel %d peak differs", partition, channel)
		}
		testing.expect_value(t, result.rms.count, baseline.rms.count)
		testing.expect_value(t, result.correlation.count, baseline.correlation.count)
		for window in 0 ..< min(result.rms.count, MAX_WINDOWS) {
			for channel in 0 ..< CHANNELS {
				a := result.rms.values[window][channel]
				b := baseline.rms.values[window][channel]
				max_rms_difference = max(max_rms_difference, math.abs(a - b))
				testing.expectf(t, math.abs(a - b) <= 1e-6 * max(math.abs(b), 1),
					"partition %d RMS window %d channel %d: %v vs %v", partition, window, channel, a, b)
			}
		}
		for window in 0 ..< min(result.correlation.count, MAX_WINDOWS) {
			a := result.correlation.values[window]
			b := baseline.correlation.values[window]
			max_correlation_difference = max(max_correlation_difference, math.abs(a - b))
			testing.expectf(t, math.abs(a - b) <= 1e-6,
				"partition %d correlation window %d: %v vs %v", partition, window, a, b)
		}
	}
	fmt.printf("partition invariance: peak exact; max RMS abs diff %v, max correlation abs diff %v\n",
		max_rms_difference, max_correlation_difference)
}

@(test)
test_partition_invariance_fft :: proc(t: ^testing.T) {
	FRAMES :: 8192
	samples := make([]f32, FRAMES)
	defer delete(samples)
	testing.expect_value(t, audio.generate_sine(samples, 48000, 1, 997, 0.5), audio.Audio_Error.None)
	baseline := run_fft_partitions(t, samples, FRAMES, 1, 64)
	testing.expect_value(t, baseline.count, 8)
	partitions := [?]int{128, 256, 997}
	max_fft_difference := f32(0)
	for partition in partitions {
		result := run_fft_partitions(t, samples, FRAMES, 1, partition)
		testing.expect_value(t, result.count, baseline.count)
		for window in 0 ..< min(result.count, 8) {
			for bin in 0 ..< 513 {
				a := result.magnitudes[window][bin]
				b := baseline.magnitudes[window][bin]
				max_fft_difference = max(max_fft_difference, math.abs(a - b))
				testing.expectf(t, math.abs(a - b) <= 1e-6 * max(math.abs(b), 1),
					"partition %d FFT window %d bin %d: %v vs %v", partition, window, bin, a, b)
			}
		}
	}
	fmt.printf("FFT partition invariance: max amplitude abs diff %v\n", max_fft_difference)
}

@(test)
test_wav_round_trip_without_binary_fixtures :: proc(t: ^testing.T) {
	FRAMES :: 512
	source := make([]f32, FRAMES * 2)
	defer delete(source)
	testing.expect_value(t, audio.generate_sine(source, 48000, 2, 440, 0.8), audio.Audio_Error.None)

	formats := [?]audio.Sample_Format{.U8, .S16, .S24, .S32, .F32, .F64}
	for format in formats {
		descriptor := audio.Audio_Stream_Descriptor{
			sample_rate = 48000,
			channels = 2,
			channel_layout = .Stereo,
			sample_format = format,
			total_frames = FRAMES,
		}
		bytes, err := audio.wav_encode(source, descriptor)
		testing.expect_value(t, err, audio.Audio_Error.None)
		decoded, decode_err := audio.wav_decode(bytes)
		testing.expect_value(t, decode_err, audio.Audio_Error.None)
		testing.expect_value(t, decoded.descriptor.total_frames, i64(FRAMES))
		scale: f64 = 0
		switch format {
		case .U8:  scale = 128.0
		case .S16: scale = 32768.0
		case .S24: scale = 8388608.0
		case .S32: scale = 2147483648.0
		case .F32, .F64: scale = 0
		case .Unknown:
		}
		mismatches := 0
		first_mismatch := -1
		for index in 0 ..< len(source) {
			expected := source[index]
			if scale != 0 {
				expected = f32(math.round(f64(source[index]) * scale) / scale)
			}
			if transmute(u32)decoded.samples[index] != transmute(u32)expected {
				mismatches += 1
				if first_mismatch < 0 {
					first_mismatch = index
				}
			}
		}
		testing.expectf(t, mismatches == 0, "%v: %d mismatches, first at %d (%v vs %v)",
			format, mismatches, first_mismatch,
			decoded.samples[max(first_mismatch, 0)], source[max(first_mismatch, 0)])
		audio.wav_audio_destroy(&decoded)
		delete(bytes)
	}
}

@(test)
test_repeatable_measurement_records :: proc(t: ^testing.T) {
	FRAMES :: 10000
	samples := make([]f32, FRAMES * 2)
	defer delete(samples)
	testing.expect_value(t, audio.generate_two_tone(samples, 48000, 2, 440, 0.4, 997, 0.2), audio.Audio_Error.None)

	first := run_partitions(samples, FRAMES, 2, 256)
	second := run_partitions(samples, FRAMES, 2, 256)
	testing.expect(t, first.peak == second.peak, "peak repeatable")
	for window in 0 ..< min(first.rms.count, MAX_WINDOWS) {
		for channel in 0 ..< 2 {
			testing.expect(t, transmute(u32)first.rms.values[window][channel] ==
				transmute(u32)second.rms.values[window][channel], "RMS bit-identical")
		}
	}
	for window in 0 ..< min(first.correlation.count, MAX_WINDOWS) {
		testing.expect(t, transmute(u32)first.correlation.values[window] ==
			transmute(u32)second.correlation.values[window], "correlation bit-identical")
	}

	snapshot_a := pipeline_snapshot(first)
	snapshot_b := pipeline_snapshot(second)
	testing.expect_value(t, transport.snapshot_fingerprint(snapshot_a), transport.snapshot_fingerprint(snapshot_b))

	// The publication seam preserves the record by value and latest-wins.
	publisher: transport.Snapshot_Publisher
	_ = transport.snapshot_publish(&publisher, snapshot_a)
	read_a := transport.snapshot_read(&publisher)
	testing.expect(t, read_a.frame == 10000 && read_a.valid, "snapshot read")
	updated := snapshot_a
	updated.frame = 12000
	_ = transport.snapshot_publish(&publisher, updated)
	read_b := transport.snapshot_read(&publisher)
	testing.expect_value(t, read_b.frame, i64(12000))
	testing.expect(t, read_a.frame == 10000, "previous snapshot remains a value copy")
}

@(test)
test_bounded_memory_ceiling :: proc(t: ^testing.T) {
	CEILING :: 2 * 1024 * 1024
	counter := Counting_Allocator{backing = context.allocator}
	allocator := counting_allocator(&counter)

	plan: analysis.Real_FFT_Plan
	testing.expect_value(t, analysis.real_fft_plan_init(&plan, 4096, .Blackman_Harris, allocator), analysis.FFT_Error.None)
	defer analysis.real_fft_plan_destroy(&plan)

	ring: transport.Audio_Ring
	testing.expect(t, transport.audio_ring_init(&ring, 32, 512, 2, 0, 0, allocator), "ring init")
	defer transport.audio_ring_destroy(&ring)

	samples := make([]f32, 4096 * 2, allocator)
	defer delete(samples, allocator)
	testing.expect_value(t, audio.generate_sine(samples, 48000, 2, 440, 0.5), audio.Audio_Error.None)
	descriptor := audio.Audio_Stream_Descriptor{
		sample_rate = 48000,
		channels = 2,
		channel_layout = .Stereo,
		sample_format = .F32,
	}
	bytes, err := audio.wav_encode(samples, descriptor, allocator)
	testing.expect_value(t, err, audio.Audio_Error.None)
	decoded, decode_err := audio.wav_decode(bytes, 0, allocator)
	testing.expect_value(t, decode_err, audio.Audio_Error.None)
	audio.wav_audio_destroy(&decoded)
	mem.free(raw_data(bytes), allocator)

	spectrum := make([]analysis.Complex32, 2049, allocator)
	defer delete(spectrum, allocator)
	testing.expect(t, analysis.real_fft_forward(&plan, samples[:4096], spectrum), "forward")
	window: analysis.RMS_Window
	testing.expect(t, analysis.rms_window_init(&window, 1024, 2), "rms init")

	fmt.printf("bounded-memory peak: %d bytes over %d allocations (ceiling %d)\n", counter.peak, counter.allocs, CEILING)
	testing.expectf(t, counter.peak <= CEILING, "peak %d exceeds ceiling %d", counter.peak, CEILING)
	testing.expectf(t, counter.allocs >= 6, "expected setup allocations, got %d", counter.allocs)
}
