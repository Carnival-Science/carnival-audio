// Calibrated sample-domain measurements.
//
// This package works on interleaved f32 frames and never allocates in a
// per-block path. It deliberately separates:
//   - sample peak (not true peak, not oversampled)
//   - windowed RMS (explicit window length, aligned to the sample clock)
//   - peak hold (stateful envelope with configurable hold and decay)
//
// dBFS is referenced to a full-scale square wave (RMS 1.0), so a full-scale
// sine reads -3.010299956639812 dBFS. See docs/determinism.md.
package analysis

import "core:math"

import audio "pulse:core/audio"

MAX_CHANNELS :: audio.MAX_CHANNELS

// DBFS_FLOOR is reported instead of -inf for digital silence.
DBFS_FLOOR :: f32(-144.0)

// CORRELATION_VARIANCE_EPSILON is the variance floor used to reject degenerate
// correlation windows.
CORRELATION_VARIANCE_EPSILON :: f64(1e-20)

// Sample_Peak is the largest absolute sample seen. `frame` is the absolute
// stream frame of the first occurrence; `channel` is the channel of that
// occurrence. `valid` is false before any sample has been observed.
Sample_Peak :: struct {
	magnitude: f32,
	frame:     i64,
	channel:   int,
	valid:     bool,
}

// Peak_Accumulator tracks the overall and per-channel sample peak exactly.
// It is allocation-free and independent of block partitioning.
Peak_Accumulator :: struct {
	channels:    int,
	overall:     Sample_Peak,
	per_channel: [MAX_CHANNELS]Sample_Peak,
}

peak_accumulator_init :: proc(acc: ^Peak_Accumulator, channels: int) -> bool {
	if channels < 1 || channels > MAX_CHANNELS {
		return false
	}
	acc^ = Peak_Accumulator{channels = channels}
	return true
}

peak_accumulator_reset :: proc(acc: ^Peak_Accumulator) {
	channels := acc.channels
	acc^ = Peak_Accumulator{channels = channels}
}

peak_accumulator_process :: proc(acc: ^Peak_Accumulator, block: audio.Audio_Block) -> bool {
	if !audio.audio_block_valid(block) || block.channels != acc.channels {
		return false
	}
	for frame in 0 ..< block.frames {
		absolute_frame := block.start_frame + i64(frame)
		base := frame * acc.channels
		for channel in 0 ..< acc.channels {
			magnitude := math.abs(block.interleaved[base + channel])
			if !acc.per_channel[channel].valid || magnitude > acc.per_channel[channel].magnitude {
				acc.per_channel[channel] = Sample_Peak{
					magnitude = magnitude,
					frame = absolute_frame,
					channel = channel,
					valid = true,
				}
			}
			if !acc.overall.valid || magnitude > acc.overall.magnitude {
				acc.overall = Sample_Peak{
					magnitude = magnitude,
					frame = absolute_frame,
					channel = channel,
					valid = true,
				}
			}
		}
	}
	return true
}

// sample_peak computes the overall sample peak of one block.
sample_peak :: proc(block: audio.Audio_Block) -> Sample_Peak {
	acc: Peak_Accumulator
	if !peak_accumulator_init(&acc, block.channels) {
		return {}
	}
	_ = peak_accumulator_process(&acc, block)
	return acc.overall
}

// peak_amplitude_to_dbfs converts a linear sample magnitude to dBFS, where a
// full-scale magnitude (1.0) reads 0 dBFS.
peak_amplitude_to_dbfs :: proc(amplitude: f32) -> f32 {
	if amplitude <= 0 {
		return DBFS_FLOOR
	}
	db := 20.0 * f32(math.log10(f64(amplitude)))
	return max(db, DBFS_FLOOR)
}

// rms_to_dbfs converts an RMS value to dBFS with the full-scale-square
// reference. This is a reporting helper; it is not called per sample.
rms_to_dbfs :: proc(rms: f32) -> f32 {
	if rms <= 0 {
		return DBFS_FLOOR
	}
	db := 20.0 * f32(math.log10(f64(rms)))
	return max(db, DBFS_FLOOR)
}

// RMS_Record is one complete, non-overlapping window of RMS values.
RMS_Record :: struct {
	start_frame: i64,
	frames:      int,
	channels:    int,
	rms:         [MAX_CHANNELS]f32,
	valid:       bool,
}

// RMS_Window accumulates sum-of-squares over fixed, sample-clock-aligned,
// non-overlapping windows. Input blocks must be contiguous: a gap or overlap
// makes processing return false, after which the caller must reset explicitly.
// This is what prevents a dropped block from silently producing a valid value.
RMS_Window :: struct {
	window_frames: int,
	channels:      int,
	sums:          [MAX_CHANNELS]f64,
	frames_filled: int,
	next_frame:    i64,
	window_start:  i64,
}

rms_window_init :: proc(window: ^RMS_Window, window_frames, channels: int, origin_frame: i64 = 0) -> bool {
	if window_frames < 1 || channels < 1 || channels > MAX_CHANNELS || origin_frame < 0 {
		return false
	}
	window^ = RMS_Window{
		window_frames = window_frames,
		channels = channels,
		next_frame = origin_frame,
		window_start = origin_frame,
	}
	return true
}

rms_window_reset :: proc(window: ^RMS_Window, origin_frame: i64 = 0) {
	window_frames := window.window_frames
	channels := window.channels
	window^ = RMS_Window{
		window_frames = window_frames,
		channels = channels,
		next_frame = origin_frame,
		window_start = origin_frame,
	}
}

RMS_Window_Callback :: #type proc(user_data: rawptr, record: RMS_Record)

// rms_window_process consumes `block` and invokes `callback` once per completed
// window. It performs no allocation. Returns false on a non-contiguous block or
// invalid configuration, leaving the accumulator untouched for that block.
rms_window_process :: proc(
	window: ^RMS_Window,
	block: audio.Audio_Block,
	callback: RMS_Window_Callback,
	user_data: rawptr = nil,
) -> bool {
	if !audio.audio_block_valid(block) || block.channels != window.channels || window.window_frames < 1 {
		return false
	}
	if block.start_frame != window.next_frame {
		return false
	}
	for frame in 0 ..< block.frames {
		base := frame * window.channels
		for channel in 0 ..< window.channels {
			sample := f64(block.interleaved[base + channel])
			window.sums[channel] += sample * sample
		}
		window.frames_filled += 1
		window.next_frame += 1
		if window.frames_filled == window.window_frames {
			record := RMS_Record{
				start_frame = window.window_start,
				frames = window.window_frames,
				channels = window.channels,
				valid = true,
			}
			for channel in 0 ..< window.channels {
				record.rms[channel] = f32(math.sqrt(window.sums[channel] / f64(window.window_frames)))
				window.sums[channel] = 0
			}
			if callback != nil {
				callback(user_data, record)
			}
			window.frames_filled = 0
			window.window_start += i64(window.window_frames)
		}
	}
	return true
}

// rms_over computes the RMS of one channel slice or an interleaved buffer
// (all channels combined), using f64 accumulation and an f32 result. Provided
// for goldens and offline reference checks.
rms_over :: proc(samples: []f32) -> f32 {
	if len(samples) == 0 {
		return 0
	}
	sum := f64(0)
	for sample in samples {
		value := f64(sample)
		sum += value * value
	}
	return f32(math.sqrt(sum / f64(len(samples))))
}

// Peak_Hold_Decay selects what happens after the hold interval expires.
Peak_Hold_Decay :: enum u8 {
	None,
	Linear,
	Logarithmic,
}

Peak_Hold_Config :: struct {
	channels:                 int,
	sample_rate:              int,
	hold_frames:              int,
	decay:                    Peak_Hold_Decay,
	linear_decay_per_second:  f32,
	db_decay_per_second:      f32,
}

// Peak_Hold is a per-channel hold/decay envelope updated once per frame.
// Constants (linear step and the logarithmic multiplier) are computed at init;
// the per-frame path contains only compare/multiply/subtract.
Peak_Hold :: struct {
	channels:          int,
	sample_rate:       int,
	hold_frames:       int,
	decay:             Peak_Hold_Decay,
	linear_step:       f32,
	exponential_step:  f32,
	held:              [MAX_CHANNELS]f32,
	hold_remaining:    [MAX_CHANNELS]int,
}

peak_hold_init :: proc(hold: ^Peak_Hold, config: Peak_Hold_Config) -> bool {
	if config.channels < 1 || config.channels > MAX_CHANNELS {
		return false
	}
	if config.sample_rate <= 0 || config.hold_frames < 0 {
		return false
	}
	if config.linear_decay_per_second < 0 || config.db_decay_per_second < 0 {
		return false
	}
	hold^ = Peak_Hold{
		channels = config.channels,
		sample_rate = config.sample_rate,
		hold_frames = config.hold_frames,
		decay = config.decay,
		linear_step = config.linear_decay_per_second / f32(config.sample_rate),
	}
	if config.decay == .Logarithmic {
		hold.exponential_step = f32(math.pow(10.0, -f64(config.db_decay_per_second) / (20.0 * f64(config.sample_rate))))
	} else {
		hold.exponential_step = 1
	}
	return true
}

peak_hold_reset :: proc(hold: ^Peak_Hold) {
	for channel in 0 ..< hold.channels {
		hold.held[channel] = 0
		hold.hold_remaining[channel] = 0
	}
}

peak_hold_process :: proc(hold: ^Peak_Hold, block: audio.Audio_Block) -> bool {
	if !audio.audio_block_valid(block) || block.channels != hold.channels {
		return false
	}
	for frame in 0 ..< block.frames {
		base := frame * block.channels
		for channel in 0 ..< hold.channels {
			magnitude := math.abs(block.interleaved[base + channel])
			if magnitude >= hold.held[channel] {
				hold.held[channel] = magnitude
				hold.hold_remaining[channel] = hold.hold_frames
			} else if hold.hold_remaining[channel] > 0 {
				hold.hold_remaining[channel] -= 1
			} else {
				switch hold.decay {
				case .None:
					// Keep the held value indefinitely.
				case .Linear:
					hold.held[channel] = max(hold.held[channel] - hold.linear_step, 0)
				case .Logarithmic:
					hold.held[channel] *= hold.exponential_step
				}
			}
		}
	}
	return true
}

peak_hold_value :: proc(hold: ^Peak_Hold, channel: int) -> f32 {
	if channel < 0 || channel >= hold.channels {
		return 0
	}
	return hold.held[channel]
}

