// Deterministic, allocation-free test-signal generators.
//
// These are offline fixture builders, not real-time analysis. They write
// interleaved f32 frames and must be given a destination of exactly
// `frames * channels` samples. All formulas are sample-exact and repeated calls
// with the same arguments produce bit-identical output on the same platform.
//
// The white-noise PRNG is xorshift64* (Marsaglia / Vigna), implemented here so
// fixtures never depend on core:math/rand's unspecified sequence or on the
// process-global random state.
package stream

import "core:math"

// generate_silence zeroes the destination.
generate_silence :: proc(dst: []f32) {
	for index in 0 ..< len(dst) {
		dst[index] = 0
	}
}

// generate_sine fills every channel with
//
//	amplitude * sin(2*pi*frequency*n/sample_rate + phase) + dc
//
// where `phase` is in radians at frame 0.
generate_sine :: proc(
	dst: []f32,
	sample_rate: int,
	channels: int,
	frequency: f64,
	amplitude: f64 = 1.0,
	phase: f64 = 0.0,
	dc: f64 = 0.0,
) -> Audio_Error {
	frames, err := signal_frames_for(dst, channels)
	if err != .None {
		return err
	}
	if sample_rate <= 0 {
		return .Invalid_Descriptor
	}
	step := 2.0 * math.PI * frequency / f64(sample_rate)
	for frame in 0 ..< frames {
		value := f32(amplitude * math.sin(step * f64(frame) + phase) + dc)
		for channel in 0 ..< channels {
			dst[frame * channels + channel] = value
		}
	}
	return .None
}

// generate_two_tone fills every channel with the sum of two sines plus DC.
generate_two_tone :: proc(
	dst: []f32,
	sample_rate: int,
	channels: int,
	frequency_a: f64,
	amplitude_a: f64,
	frequency_b: f64,
	amplitude_b: f64,
	phase_a: f64 = 0.0,
	phase_b: f64 = 0.0,
	dc: f64 = 0.0,
) -> Audio_Error {
	frames, err := signal_frames_for(dst, channels)
	if err != .None {
		return err
	}
	if sample_rate <= 0 {
		return .Invalid_Descriptor
	}
	step_a := 2.0 * math.PI * frequency_a / f64(sample_rate)
	step_b := 2.0 * math.PI * frequency_b / f64(sample_rate)
	for frame in 0 ..< frames {
		n := f64(frame)
		value := f32(
			amplitude_a * math.sin(step_a * n + phase_a) +
			amplitude_b * math.sin(step_b * n + phase_b) +
			dc,
		)
		for channel in 0 ..< channels {
			dst[frame * channels + channel] = value
		}
	}
	return .None
}

Sweep_Kind :: enum u8 {
	Exponential,
	Linear,
}

// generate_sweep fills every channel with a phase-continuous sweep.
//
// Exponential (default): frequency rises from f_start to f_end geometrically.
// The instantaneous phase is
//
//	phase0 + 2*pi*f_start*T/K * (exp(K*t/T) - 1),  K = ln(f_end/f_start)
//
// Linear: instantaneous frequency rises linearly;
//
//	phase0 + 2*pi*(f_start*t + (f_end-f_start)*t^2/(2*T))
//
// If the start and end frequencies are equal the sweep degenerates to a
// constant sine at f_start. The exponential form additionally requires both
// frequencies to be positive; otherwise it falls back to the constant sine.
// The linear form accepts any distinct frequencies.
generate_sweep :: proc(
	dst: []f32,
	sample_rate: int,
	channels: int,
	f_start: f64,
	f_end: f64,
	amplitude: f64 = 1.0,
	phase: f64 = 0.0,
	dc: f64 = 0.0,
	kind: Sweep_Kind = .Exponential,
) -> Audio_Error {
	frames, err := signal_frames_for(dst, channels)
	if err != .None {
		return err
	}
	if sample_rate <= 0 {
		return .Invalid_Descriptor
	}
	if frames == 0 {
		return .None
	}
	duration := f64(frames) / f64(sample_rate)
	exponential := kind == .Exponential && f_start > 0 && f_end > 0 && f_start != f_end
	linear := kind == .Linear && f_start != f_end
	ln_ratio := 0.0
	exp_scale := 0.0
	linear_slope := 0.0
	switch {
	case exponential:
		ln_ratio = math.ln(f_end / f_start)
		exp_scale = 2.0 * math.PI * f_start * duration / ln_ratio
	case linear:
		linear_slope = (f_end - f_start) / duration
	}

	for frame in 0 ..< frames {
		t := f64(frame) / f64(sample_rate)
		phase_now := phase
		switch {
		case exponential:
			phase_now += exp_scale * (math.exp(ln_ratio * t / duration) - 1.0)
		case linear:
			phase_now += 2.0 * math.PI * (f_start * t + 0.5 * linear_slope * t * t)
		case:
			phase_now += 2.0 * math.PI * f_start * t
		}
		value := f32(amplitude * math.sin(phase_now) + dc)
		for channel in 0 ..< channels {
			dst[frame * channels + channel] = value
		}
	}
	return .None
}

// generate_white_noise fills every sample with uniform noise in
// [-amplitude, +amplitude) using xorshift64*:
//
//	x ^= x >> 12; x ^= x << 25; x ^= x >> 27; r = x * 2685821657736338717
//	u = (r >> 40) / 2^23 - 1
//
// A zero seed is replaced with the golden-ratio constant so the sequence is
// never stuck at zero. Returns the PRNG state after generation.
generate_white_noise :: proc(dst: []f32, seed: u64, amplitude: f64 = 1.0) -> u64 {
	state := seed
	if state == 0 {
		state = 0x9E37_79B9_7F4A_7C15
	}
	for index in 0 ..< len(dst) {
		state ~= state >> 12
		state ~= state << 25
		state ~= state >> 27
		random := state * 2685821657736338717
		unit := f64(random >> 40) / 8388608.0 - 1.0
		dst[index] = f32(unit * amplitude)
	}
	return state
}

// generate_impulse writes one frame of `amplitude` and zero elsewhere.
// `channel` < 0 writes every channel; otherwise it must be a valid channel.
generate_impulse :: proc(
	dst: []f32,
	channels: int,
	impulse_frame: int,
	amplitude: f32 = 1.0,
	channel: int = -1,
) -> Audio_Error {
	frames, err := signal_frames_for(dst, channels)
	if err != .None {
		return err
	}
	if impulse_frame < 0 || impulse_frame >= frames {
		return .Invalid_Descriptor
	}
	if channel >= channels || channel < -1 {
		return .Invalid_Descriptor
	}
	for index in 0 ..< len(dst) {
		dst[index] = 0
	}
	if channel < 0 {
		for c in 0 ..< channels {
			dst[impulse_frame * channels + c] = amplitude
		}
	} else {
		dst[impulse_frame * channels + channel] = amplitude
	}
	return .None
}

// generate_step writes zero before `step_frame` and `amplitude` from that frame
// onward. `channel` < 0 writes every channel.
generate_step :: proc(
	dst: []f32,
	channels: int,
	step_frame: int,
	amplitude: f32 = 0.5,
	channel: int = -1,
) -> Audio_Error {
	frames, err := signal_frames_for(dst, channels)
	if err != .None {
		return err
	}
	if step_frame < 0 || step_frame > frames {
		return .Invalid_Descriptor
	}
	if channel >= channels || channel < -1 {
		return .Invalid_Descriptor
	}
	for frame in 0 ..< frames {
		value: f32 = 0
		if frame >= step_frame {
			value = amplitude
		}
		for c in 0 ..< channels {
			if channel < 0 || channel == c {
				dst[frame * channels + c] = value
			} else {
				dst[frame * channels + c] = 0
			}
		}
	}
	return .None
}

@(private = "file")
signal_frames_for :: proc(dst: []f32, channels: int) -> (int, Audio_Error) {
	if channels < 1 || channels > MAX_CHANNELS {
		return 0, .Invalid_Descriptor
	}
	if len(dst) % channels != 0 {
		return 0, .Invalid_Descriptor
	}
	return len(dst) / channels, .None
}
