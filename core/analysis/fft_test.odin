package analysis

import "core:math"
import "core:testing"

import audio "pulse:core/audio"

// Naive O(n^2) DFT used only as a test oracle.
dft_naive :: proc(input: []Complex32) -> []Complex32 {
	n := len(input)
	output := make([]Complex32, n)
	for k in 0 ..< n {
		sum_re := f64(0)
		sum_im := f64(0)
		for sample_index in 0 ..< n {
			angle := -2.0 * math.PI * f64(k * sample_index) / f64(n)
			c := math.cos(angle)
			s := math.sin(angle)
			re := f64(input[sample_index].re)
			im := f64(input[sample_index].im)
			sum_re += re * c - im * s
			sum_im += re * s + im * c
		}
		output[k] = Complex32{re = f32(sum_re), im = f32(sum_im)}
	}
	return output
}

fft_test_random :: proc(state: ^u64) -> f32 {
	state^ ~= state^ >> 12
	state^ ~= state^ << 25
	state^ ~= state^ >> 27
	random := state^ * 2685821657736338717
	return f32(f64(random >> 40) / 8388608.0 - 1.0)
}

@(test)
test_fft_plan_twiddles_match_direct_evaluation :: proc(t: ^testing.T) {
	plan: FFT_Plan
	testing.expect_value(t, fft_plan_init(&plan, 64, .Rectangular), FFT_Error.None)
	defer fft_plan_destroy(&plan)
	for index in 0 ..< plan.n / 2 {
		angle := -2.0 * math.PI * f64(index) / f64(plan.n)
		expected_re := f32(math.cos(angle))
		expected_im := f32(math.sin(angle))
		testing.expectf(t, math.abs(plan.cos_table[index] - expected_re) <= 1e-7,
			"twiddle %d re: %v != %v", index, plan.cos_table[index], expected_re)
		testing.expectf(t, math.abs(plan.sin_table[index] - expected_im) <= 1e-7,
			"twiddle %d im: %v != %v", index, plan.sin_table[index], expected_im)
	}
	testing.expect_value(t, plan.coherent_gain, f32(1))
	testing.expect_value(t, plan.bit_reverse[1], 32)
	testing.expect_value(t, plan.bit_reverse[3], 48)
}

@(test)
test_fft_matches_naive_dft :: proc(t: ^testing.T) {
	n := 64
	plan: FFT_Plan
	testing.expect_value(t, fft_plan_init(&plan, n, .Rectangular), FFT_Error.None)
	defer fft_plan_destroy(&plan)

	input := make([]Complex32, n)
	defer delete(input)
	state: u64 = 0xDEAD_BEEF_CAFE_F00D
	for index in 0 ..< n {
		input[index] = Complex32{re = fft_test_random(&state), im = fft_test_random(&state)}
	}
	expected := dft_naive(input)
	defer delete(expected)

	actual := make([]Complex32, n)
	defer delete(actual)
	copy(actual, input)
	testing.expect(t, fft_forward(&plan, actual), "forward")

	max_error := f64(0)
	for index in 0 ..< n {
		diff_re := math.abs(f64(actual[index].re) - f64(expected[index].re))
		diff_im := math.abs(f64(actual[index].im) - f64(expected[index].im))
		scale := max(math.abs(f64(expected[index].re)), math.abs(f64(expected[index].im)), f64(1))
		error := max(diff_re, diff_im) / scale
		max_error = max(max_error, error)
	}
	testing.expectf(t, max_error <= 1e-5, "FFT vs naive DFT relative error: %v", max_error)
}

@(test)
test_fft_inverse_round_trip :: proc(t: ^testing.T) {
	n := 128
	plan: FFT_Plan
	testing.expect_value(t, fft_plan_init(&plan, n, .Rectangular), FFT_Error.None)
	defer fft_plan_destroy(&plan)
	input := make([]Complex32, n)
	defer delete(input)
	state: u64 = 12345
	for index in 0 ..< n {
		input[index] = Complex32{re = fft_test_random(&state), im = fft_test_random(&state)}
	}
	work := make([]Complex32, n)
	defer delete(work)
	copy(work, input)
	testing.expect(t, fft_forward(&plan, work), "forward")
	testing.expect(t, fft_inverse(&plan, work), "inverse")
	for index in 0 ..< n {
		testing.expectf(t, math.abs(work[index].re - input[index].re) < 1e-6 &&
			math.abs(work[index].im - input[index].im) < 1e-6,
			"round trip %d: %v != %v", index, work[index], input[index])
	}
}

@(test)
test_real_fft_impulse_is_flat :: proc(t: ^testing.T) {
	n := 256
	plan: Real_FFT_Plan
	testing.expect_value(t, real_fft_plan_init(&plan, n, .Rectangular), FFT_Error.None)
	defer real_fft_plan_destroy(&plan)
	input := make([]f32, n)
	defer delete(input)
	input[0] = 1
	spectrum := make([]Complex32, n / 2 + 1)
	defer delete(spectrum)
	testing.expect(t, real_fft_forward(&plan, input, spectrum), "forward")
	for bin in 0 ..< n / 2 + 1 {
		magnitude := math.sqrt(f64(spectrum[bin].re) * f64(spectrum[bin].re) +
			f64(spectrum[bin].im) * f64(spectrum[bin].im))
		testing.expectf(t, math.abs(magnitude - 1.0) < 1e-5, "impulse bin %d magnitude %v", bin, magnitude)
	}
}

@(test)
test_real_fft_sine_amplitude_and_leakage :: proc(t: ^testing.T) {
	n := 1024
	sample_rate := 48000
	bin := 16
	frequency := f64(bin * sample_rate) / f64(n)
	input := make([]f32, n)
	defer delete(input)
	testing.expect_value(t, audio.generate_sine(input, sample_rate, 1, frequency, 1.0), audio.Audio_Error.None)

	kinds := [?]Window_Kind{.Rectangular, .Hann, .Hamming, .Blackman_Harris}
	for kind in kinds {
		plan: Real_FFT_Plan
		testing.expect_value(t, real_fft_plan_init(&plan, n, kind), FFT_Error.None)
		spectrum := make([]Complex32, n / 2 + 1)
		testing.expect(t, real_fft_forward(&plan, input, spectrum), "forward")
		amplitude := real_fft_amplitude(&plan, spectrum, bin)
		testing.expectf(t, math.abs(amplitude - 1.0) < 1e-3, "%v amplitude at bin: %v", kind, amplitude)
		// DC and Nyquist are single-sided; this sine has negligible content there.
		testing.expectf(t, real_fft_amplitude(&plan, spectrum, 0) < 1e-3, "%v DC leakage", kind)
		testing.expectf(t, real_fft_amplitude(&plan, spectrum, n / 2) < 1e-3, "%v Nyquist leakage", kind)
		if kind == .Hann {
			adjacent := real_fft_amplitude(&plan, spectrum, bin + 1)
			far := real_fft_amplitude(&plan, spectrum, bin + 4)
			testing.expectf(t, adjacent < 0.6 && adjacent > 0.3, "Hann adjacent bin: %v", adjacent)
			testing.expectf(t, far < 1e-3, "Hann far leakage: %v", far)
		}
		delete(spectrum)
		real_fft_plan_destroy(&plan)
	}
}

@(test)
test_real_fft_round_trip :: proc(t: ^testing.T) {
	n := 256
	plan: Real_FFT_Plan
	testing.expect_value(t, real_fft_plan_init(&plan, n, .Rectangular), FFT_Error.None)
	defer real_fft_plan_destroy(&plan)
	input := make([]f32, n)
	defer delete(input)
	state: u64 = 999
	for index in 0 ..< n {
		input[index] = fft_test_random(&state) * 0.5
	}
	spectrum := make([]Complex32, n / 2 + 1)
	defer delete(spectrum)
	output := make([]f32, n)
	defer delete(output)
	testing.expect(t, real_fft_forward(&plan, input, spectrum), "forward")
	testing.expect(t, real_fft_inverse(&plan, spectrum, output), "inverse")
	max_error := f32(0)
	for index in 0 ..< n {
		max_error = max(max_error, math.abs(output[index] - input[index]))
	}
	testing.expectf(t, max_error < 1e-5, "real round-trip error: %v", max_error)
}

@(test)
test_fft_rejects_invalid_sizes :: proc(t: ^testing.T) {
	plan: FFT_Plan
	testing.expect_value(t, fft_plan_init(&plan, 0), FFT_Error.Invalid_Size)
	testing.expect_value(t, fft_plan_init(&plan, 3), FFT_Error.Invalid_Size)
	real_plan: Real_FFT_Plan
	testing.expect_value(t, real_fft_plan_init(&real_plan, 2), FFT_Error.Invalid_Size)
	testing.expect_value(t, real_fft_plan_init(&real_plan, 96), FFT_Error.Invalid_Size)
}
