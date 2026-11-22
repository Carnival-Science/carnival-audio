// Pure-Odin radix-2 FFT with preallocated plans.
//
// Determinism:
//   - twiddles and windows are computed once at plan time using explicit
//     sin/cos (no runtime transcendental calls in a transform);
//   - butterflies are written as explicit multiply/add expressions, with no
//     FMA intrinsic;
//   - the forward transform is unnormalised; the inverse divides by N.
//
// Window formulas are the periodic (DFT-even) forms from Harris, "On the Use of
// Windows for Harmonic Analysis with the Discrete Fourier Transform", 1978:
//
//	Hann:          0.5    - 0.5    cos(2*pi*k/N)
//	Hamming:       0.54   - 0.46   cos(2*pi*k/N)
//	Blackman-Harris (4-term minimum):
//	               0.35875 - 0.48829 cos(2*pi*k/N)
//	                       + 0.14128 cos(4*pi*k/N)
//	                       - 0.01168 cos(6*pi*k/N)
package dsp

import "core:math"
import "core:mem"

Complex32 :: struct {
	re: f32,
	im: f32,
}

FFT_Error :: enum u8 {
	None,
	Invalid_Size,
	Allocation_Failed,
}

Window_Kind :: enum u8 {
	Rectangular,
	Hann,
	Hamming,
	Blackman_Harris,
}

// FFT_MAX_SIZE bounds plan allocations. Raising it requires re-checking the
// memory ceiling in docs/determinism.md and tests/integration_test.odin.
FFT_MAX_SIZE :: 1 << 20

// FFT_Plan owns all transform tables. Build it during setup; the transform path
// only reads the tables and never allocates.
FFT_Plan :: struct {
	n:             int,
	bits:          int,
	bit_reverse:   []int,
	cos_table:     []f32,
	sin_table:     []f32,
	scratch:       []Complex32,
	window:        []f32,
	window_kind:   Window_Kind,
	coherent_gain: f32,
	allocator:     mem.Allocator,
}

fft_plan_init :: proc(plan: ^FFT_Plan, n: int, kind: Window_Kind = .Rectangular, allocator := context.allocator) -> FFT_Error {
	if n < 2 || n > FFT_MAX_SIZE || n & (n - 1) != 0 {
		return .Invalid_Size
	}
	plan^ = FFT_Plan{n = n, bits = fft_log2(n), window_kind = kind, allocator = allocator}
	half := n / 2
	ok: bool
	plan.cos_table, ok = analysis_alloc_f32(half, allocator)
	if !ok { fft_plan_destroy(plan); return .Allocation_Failed }
	plan.sin_table, ok = analysis_alloc_f32(half, allocator)
	if !ok { fft_plan_destroy(plan); return .Allocation_Failed }
	plan.bit_reverse, ok = analysis_alloc_int(n, allocator)
	if !ok { fft_plan_destroy(plan); return .Allocation_Failed }
	plan.scratch, ok = analysis_alloc_complex(n, allocator)
	if !ok { fft_plan_destroy(plan); return .Allocation_Failed }
	plan.window, ok = analysis_alloc_f32(n, allocator)
	if !ok { fft_plan_destroy(plan); return .Allocation_Failed }

	for index in 0 ..< n {
		plan.bit_reverse[index] = fft_reverse_bits(index, plan.bits)
	}
	for index in 0 ..< half {
		angle := -2.0 * math.PI * f64(index) / f64(n)
		plan.cos_table[index] = f32(math.cos(angle))
		plan.sin_table[index] = f32(math.sin(angle))
	}
	fft_fill_window(plan.window, kind)
	gain_sum := f64(0)
	for coefficient in plan.window {
		gain_sum += f64(coefficient)
	}
	plan.coherent_gain = f32(gain_sum / f64(n))
	return .None
}

fft_plan_destroy :: proc(plan: ^FFT_Plan) {
	if plan.bit_reverse != nil {
		mem.free(raw_data(plan.bit_reverse), plan.allocator)
	}
	if plan.cos_table != nil {
		mem.free(raw_data(plan.cos_table), plan.allocator)
	}
	if plan.sin_table != nil {
		mem.free(raw_data(plan.sin_table), plan.allocator)
	}
	if plan.scratch != nil {
		mem.free(raw_data(plan.scratch), plan.allocator)
	}
	if plan.window != nil {
		mem.free(raw_data(plan.window), plan.allocator)
	}
	plan^ = {}
}

// fft_forward transforms `data` in place. len(data) must equal plan.n.
fft_forward :: proc(plan: ^FFT_Plan, data: []Complex32) -> bool {
	if plan.n < 2 || len(data) != plan.n {
		return false
	}
	for index in 0 ..< plan.n {
		plan.scratch[plan.bit_reverse[index]] = data[index]
	}
	size := 2
	for size <= plan.n {
		half := size / 2
		step := plan.n / size
		start := 0
		for start < plan.n {
			for offset in 0 ..< half {
				twiddle := offset * step
				w_re := plan.cos_table[twiddle]
				w_im := plan.sin_table[twiddle]
				a := plan.scratch[start + offset]
				b := plan.scratch[start + offset + half]
				t_re := b.re * w_re - b.im * w_im
				t_im := b.re * w_im + b.im * w_re
				plan.scratch[start + offset] = Complex32{re = a.re + t_re, im = a.im + t_im}
				plan.scratch[start + offset + half] = Complex32{re = a.re - t_re, im = a.im - t_im}
			}
			start += size
		}
		size *= 2
	}
	for index in 0 ..< plan.n {
		data[index] = plan.scratch[index]
	}
	return true
}

// fft_inverse performs the unnormalised-inverse transform and divides by N.
fft_inverse :: proc(plan: ^FFT_Plan, data: []Complex32) -> bool {
	if plan.n < 2 || len(data) != plan.n {
		return false
	}
	for index in 0 ..< plan.n {
		data[index].im = -data[index].im
	}
	if !fft_forward(plan, data) {
		return false
	}
	scale := f32(1.0 / f64(plan.n))
	for index in 0 ..< plan.n {
		data[index] = Complex32{re = data[index].re * scale, im = -data[index].im * scale}
	}
	return true
}

// fft_apply_window multiplies source into destination using the plan window.
fft_apply_window :: proc(plan: ^FFT_Plan, destination, source: []f32) -> bool {
	if len(destination) < plan.n || len(source) < plan.n {
		return false
	}
	for index in 0 ..< plan.n {
		destination[index] = source[index] * plan.window[index]
	}
	return true
}

// Real_FFT_Plan implements an N-point real transform using one N/2-point
// complex transform. `spectrum` has N/2 + 1 bins, bins 0..N/2.
Real_FFT_Plan :: struct {
	n:               int,
	m:               int,
	complex:         FFT_Plan,
	window:          []f32,
	window_kind:     Window_Kind,
	coherent_gain:   f32,
	scratch_real:    []f32,
	scratch_complex: []Complex32,
	cos_table:       []f32,
	sin_table:       []f32,
	allocator:       mem.Allocator,
}

real_fft_plan_init :: proc(plan: ^Real_FFT_Plan, n: int, kind: Window_Kind = .Rectangular, allocator := context.allocator) -> FFT_Error {
	if n < 4 || n > FFT_MAX_SIZE || n & (n - 1) != 0 {
		return .Invalid_Size
	}
	plan^ = Real_FFT_Plan{
		n = n,
		m = n / 2,
		window_kind = kind,
		allocator = allocator,
	}
	err := fft_plan_init(&plan.complex, n / 2, .Rectangular, allocator)
	if err != .None {
		return err
	}
	ok: bool
	plan.window, ok = analysis_alloc_f32(n, allocator)
	if !ok { real_fft_plan_destroy(plan); return .Allocation_Failed }
	plan.scratch_real, ok = analysis_alloc_f32(n, allocator)
	if !ok { real_fft_plan_destroy(plan); return .Allocation_Failed }
	plan.scratch_complex, ok = analysis_alloc_complex(n / 2, allocator)
	if !ok { real_fft_plan_destroy(plan); return .Allocation_Failed }
	plan.cos_table, ok = analysis_alloc_f32(n / 2, allocator)
	if !ok { real_fft_plan_destroy(plan); return .Allocation_Failed }
	plan.sin_table, ok = analysis_alloc_f32(n / 2, allocator)
	if !ok { real_fft_plan_destroy(plan); return .Allocation_Failed }
	for index in 0 ..< n / 2 {
		angle := -2.0 * math.PI * f64(index) / f64(n)
		plan.cos_table[index] = f32(math.cos(angle))
		plan.sin_table[index] = f32(math.sin(angle))
	}

	fft_fill_window(plan.window, kind)
	gain_sum := f64(0)
	for coefficient in plan.window {
		gain_sum += f64(coefficient)
	}
	plan.coherent_gain = f32(gain_sum / f64(n))
	return .None
}

real_fft_plan_destroy :: proc(plan: ^Real_FFT_Plan) {
	fft_plan_destroy(&plan.complex)
	if plan.window != nil {
		mem.free(raw_data(plan.window), plan.allocator)
	}
	if plan.scratch_real != nil {
		mem.free(raw_data(plan.scratch_real), plan.allocator)
	}
	if plan.scratch_complex != nil {
		mem.free(raw_data(plan.scratch_complex), plan.allocator)
	}
	if plan.cos_table != nil {
		mem.free(raw_data(plan.cos_table), plan.allocator)
	}
	if plan.sin_table != nil {
		mem.free(raw_data(plan.sin_table), plan.allocator)
	}
	plan^ = {}
}

// real_fft_forward windows `input` (n samples) and writes bins 0..n/2.
real_fft_forward :: proc(plan: ^Real_FFT_Plan, input: []f32, spectrum: []Complex32) -> bool {
	if len(input) != plan.n || len(spectrum) < plan.m + 1 {
		return false
	}
	for index in 0 ..< plan.n {
		plan.scratch_real[index] = input[index] * plan.window[index]
	}
	for index in 0 ..< plan.m {
		plan.scratch_complex[index] = Complex32{
			re = plan.scratch_real[2 * index],
			im = plan.scratch_real[2 * index + 1],
		}
	}
	if !fft_forward(&plan.complex, plan.scratch_complex) {
		return false
	}

	m := plan.m
	for k in 0 ..< m {
		z := plan.scratch_complex[k]
		mirror := plan.scratch_complex[(m - k) % m]
		// Z[k] = E[k] + i O[k]; mirror is Z[(M-k) mod M].
		e_re := (z.re + mirror.re) * 0.5
		e_im := (z.im - mirror.im) * 0.5
		o_re := (z.im + mirror.im) * 0.5
		o_im := (mirror.re - z.re) * 0.5
		w_re := plan.cos_table[k]
		w_im := plan.sin_table[k]
		t_re := o_re * w_re - o_im * w_im
		t_im := o_re * w_im + o_im * w_re
		spectrum[k] = Complex32{re = e_re + t_re, im = e_im + t_im}
	}
	spectrum[m] = Complex32{
		re = plan.scratch_complex[0].re - plan.scratch_complex[0].im,
		im = 0,
	}
	return true
}

// real_fft_inverse reconstructs n real samples from bins 0..n/2. This is used
// for round-trip verification, not by the meter.
real_fft_inverse :: proc(plan: ^Real_FFT_Plan, spectrum: []Complex32, output: []f32) -> bool {
	if len(spectrum) < plan.m + 1 || len(output) != plan.n {
		return false
	}
	m := plan.m
	for k in 0 ..< m {
		xk := spectrum[k]
		xm := spectrum[m - k]
		e_re := (xk.re + xm.re) * 0.5
		e_im := (xk.im - xm.im) * 0.5
		d_re := (xk.re - xm.re) * 0.5
		d_im := (xk.im + xm.im) * 0.5
		w_re := plan.cos_table[k]
		w_im := plan.sin_table[k]
		// O = (D / 2) / W = (D / 2) * conj(W), since |W| = 1.
		o_re := d_re * w_re + d_im * w_im
		o_im := d_im * w_re - d_re * w_im
		plan.scratch_complex[k] = Complex32{re = e_re - o_im, im = e_im + o_re}
	}
	if !fft_inverse(&plan.complex, plan.scratch_complex) {
		return false
	}
	for index in 0 ..< m {
		output[2 * index] = plan.scratch_complex[index].re
		output[2 * index + 1] = plan.scratch_complex[index].im
	}
	return true
}

// real_fft_amplitude normalises a bin so a bin-centred full-scale sine reads
// 1.0. DC and Nyquist are single-sided; other bins are doubled.
real_fft_amplitude :: proc(plan: ^Real_FFT_Plan, spectrum: []Complex32, bin: int) -> f32 {
	if bin < 0 || bin > plan.m || len(spectrum) < plan.m + 1 {
		return 0
	}
	if plan.coherent_gain <= 0 {
		return 0
	}
	magnitude := math.sqrt(f64(spectrum[bin].re) * f64(spectrum[bin].re) + f64(spectrum[bin].im) * f64(spectrum[bin].im))
	scale := 1.0 / (f64(plan.n) * f64(plan.coherent_gain))
	if bin != 0 && bin != plan.m {
		scale *= 2.0
	}
	return f32(magnitude * scale)
}

@(private = "file")
fft_log2 :: proc(n: int) -> int {
	bits := 0
	value := n
	for value > 1 {
		value >>= 1
		bits += 1
	}
	return bits
}

@(private = "file")
fft_reverse_bits :: proc(value, bits: int) -> int {
	result := 0
	v := value
	for _ in 0 ..< bits {
		result = (result << 1) | (v & 1)
		v >>= 1
	}
	return result
}

@(private = "file")
fft_fill_window :: proc(window: []f32, kind: Window_Kind) {
	n := len(window)
	if n == 0 {
		return
	}
	for index in 0 ..< n {
		angle := 2.0 * math.PI * f64(index) / f64(n)
		value := 1.0
		switch kind {
		case .Rectangular:
			value = 1.0
		case .Hann:
			value = 0.5 - 0.5 * math.cos(angle)
		case .Hamming:
			value = 0.54 - 0.46 * math.cos(angle)
		case .Blackman_Harris:
			value = 0.35875 - 0.48829 * math.cos(angle) +
				0.14128 * math.cos(2.0 * angle) -
				0.01168 * math.cos(3.0 * angle)
		}
		window[index] = f32(value)
	}
}

@(private = "file")
analysis_alloc_f32 :: proc(count: int, allocator: mem.Allocator) -> ([]f32, bool) {
	if count <= 0 {
		return nil, count == 0
	}
	bytes, err := mem.alloc_bytes(count * size_of(f32), align_of(f32), allocator)
	if err != .None || bytes == nil {
		return nil, false
	}
	return mem.slice_data_cast([]f32, bytes), true
}

@(private = "file")
analysis_alloc_int :: proc(count: int, allocator: mem.Allocator) -> ([]int, bool) {
	if count <= 0 {
		return nil, count == 0
	}
	bytes, err := mem.alloc_bytes(count * size_of(int), align_of(int), allocator)
	if err != .None || bytes == nil {
		return nil, false
	}
	return mem.slice_data_cast([]int, bytes), true
}

@(private = "file")
analysis_alloc_complex :: proc(count: int, allocator: mem.Allocator) -> ([]Complex32, bool) {
	if count <= 0 {
		return nil, count == 0
	}
	bytes, err := mem.alloc_bytes(count * size_of(Complex32), align_of(Complex32), allocator)
	if err != .None || bytes == nil {
		return nil, false
	}
	return mem.slice_data_cast([]Complex32, bytes), true
}
