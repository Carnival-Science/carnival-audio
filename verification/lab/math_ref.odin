// Independent numerical references used by the laboratory.
//
// Nothing here calls Pulse, `core/dsp`, `core/stream` generators or any
// plugin code. Signal generation, peak/RMS and the naive DFT are implemented
// here from their definitions so a measurement comparison is not two copies of
// the same implementation agreeing with itself.
//
// The naive DFT is deliberately O(n^2). Callers bound n (the scenarios and
// probes use 256..1024) and the cost is documented in the report.
package verification_lab

import "core:math"

Input_Kind :: enum {
	Sine,
	DC,
	Impulse,
	Noise,
	Silence,
	Sine_Impulse,
}

input_kind_from_string :: proc(text: string) -> Input_Kind {
	switch text {
	case "dc":           return .DC
	case "impulse":      return .Impulse
	case "noise":        return .Noise
	case "silence":      return .Silence
	case "sine_impulse": return .Sine_Impulse
	}
	return .Sine
}

// XorShift64* with a fixed seed. Verification-local: not core/stream's PRNG.
prng_next :: proc(state: ^u64) -> u64 {
	x := state^
	x ~= x >> 12
	x ~= x << 25
	x ~= x >> 27
	state^ = x
	return x * 0x2545_F491_4F6C_DD1D
}

prng_unit :: proc(state: ^u64) -> f64 {
	// 53-bit uniform in [0, 1).
	value := prng_next(state) >> 11
	return f64(value) * (1.0 / 9007199254740992.0)
}

// generate_input builds planar stereo samples. `channel_scale` lets a scenario
// put different amplitudes on left and right while sharing the same waveform.
generate_input :: proc(
	frames: int,
	sample_rate: f64,
	kind: Input_Kind,
	frequency_hz: f64,
	amplitude: f64,
	channel_scale: [2]f64,
	seed: u64,
	impulse_frame: int,
	dc_value: f64,
	allocator := context.allocator,
) -> [][]f32 {
	result := make([][]f32, 2, allocator)
	for channel in 0 ..< 2 {
		result[channel] = make([]f32, frames, allocator)
	}
	prng := seed
	if prng == 0 {
		prng = 0x9E37_79B9_7F4A_7C15
	}
	for channel in 0 ..< 2 {
		scale := channel_scale[channel]
		state := prng + u64(channel) * 0x1234_5678_9ABC_DEF0
		for frame in 0 ..< frames {
			value: f64
			switch kind {
			case .Sine:
				value = amplitude * math.sin(math.TAU * frequency_hz * f64(frame) / sample_rate)
			case .DC:
				value = dc_value
			case .Impulse:
				value = frame == impulse_frame ? amplitude : 0
			case .Noise:
				value = amplitude * (prng_unit(&state) * 2.0 - 1.0)
			case .Silence:
				value = 0
			case .Sine_Impulse:
				value = amplitude * math.sin(math.TAU * frequency_hz * f64(frame) / sample_rate)
				if frame == impulse_frame {
					value += amplitude
				}
			}
			result[channel][frame] = f32(value * scale)
		}
	}
	return result
}

destroy_input :: proc(input: [][]f32) {
	for channel in input {
		delete(channel)
	}
	delete(input)
}

Window_Measure :: struct {
	peak:       [2]f64,
	peak_frame: [2]int,
	rms:        [2]f64,
	frames:     int,
}

// measure_window computes sample peak, first peak frame and RMS directly from
// the definition. The RMS accumulation is f64, matching the precision a
// well-behaved meter should use; the reference is the arithmetic itself, not a
// reimplementation of the meter.
measure_window :: proc(input: [][]f32, start, frames: int) -> Window_Measure {
	result: Window_Measure
	result.frames = frames
	if frames <= 0 {
		return result
	}
	for channel in 0 ..< 2 {
		peak := f64(0)
		peak_frame := start
		sum := f64(0)
		available := 0
		if channel < len(input) {
			available = min(frames, len(input[channel]) - start)
		}
		for frame in 0 ..< max(available, 0) {
			value := f64(input[channel][start + frame])
			magnitude := math.abs(value)
			if magnitude > peak {
				peak = magnitude
				peak_frame = start + frame
			}
			sum += value * value
		}
		result.peak[channel] = peak
		result.peak_frame[channel] = peak_frame
		if available > 0 {
			result.rms[channel] = math.sqrt(sum / f64(available))
		}
	}
	return result
}

// rms_closed_form_sine is a published closed-form value for a full-scale sine.
rms_closed_form_sine :: proc(amplitude: f64) -> f64 {
	return amplitude / math.sqrt(2.0)
}

amplitude_to_dbfs :: proc(amplitude: f64) -> f64 {
	if amplitude <= 0 {
		return -144
	}
	return max(20.0 * math.log10(amplitude), -144)
}

// naive_dft returns f64 magnitudes for bins 0..n/2 inclusive. O(n^2), no FFT,
// no windowing and no shared transform code. Callers bound n.
naive_dft :: proc(samples: []f32, allocator := context.allocator) -> []f64 {
	n := len(samples)
	if n == 0 {
		return nil
	}
	bins := n / 2 + 1
	magnitudes := make([]f64, bins, allocator)
	for bin in 0 ..< bins {
		real := f64(0)
		imag := f64(0)
		angle := math.TAU * f64(bin) / f64(n)
		for frame in 0 ..< n {
			value := f64(samples[frame])
			real += value * math.cos(angle * f64(frame))
			imag -= value * math.sin(angle * f64(frame))
		}
		magnitudes[bin] = math.sqrt(real * real + imag * imag) * 2.0 / f64(n)
	}
	return magnitudes
}

naive_dft_peak_bin :: proc(magnitudes: []f64) -> int {
	best := 0
	best_value := f64(0)
	for value, index in magnitudes {
		if value > best_value {
			best_value = value
			best = index
		}
	}
	return best
}

nonfinite_scan :: proc(input: [][]f32) -> (nonfinite: int, first_frame: int, first_channel: int) {
	first_frame = -1
	first_channel = -1
	for channel in 0 ..< len(input) {
		for frame in 0 ..< len(input[channel]) {
			value := input[channel][frame]
			if math.is_nan_f32(value) || math.is_inf_f32(value) {
				if first_frame < 0 {
					first_frame = frame
					first_channel = channel
				}
				nonfinite += 1
			}
		}
	}
	return
}
