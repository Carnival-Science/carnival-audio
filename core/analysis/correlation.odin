// Stereo correlation / phase-scope data feed.
//
// Pearson correlation r is computed over frames of a two-channel stream. The
// window is sample-clock aligned and non-overlapping, matching RMS_Window.
//
// Degenerate windows: if either channel's variance is below
// CORRELATION_VARIANCE_EPSILON (including digital silence and DC), the result is
// value 0 with valid=false. A valid result is clamped to [-1, 1]. NaN is never
// returned.
package analysis

import "core:math"

import audio "pulse:core/audio"

// Correlation_Record is one complete, non-overlapping stereo correlation window.
Correlation_Record :: struct {
	start_frame: i64,
	frames:      int,
	value:       f32,
	valid:       bool,
}

// Correlation_Window accumulates Pearson moments on frames of a two-channel
// stream. It performs no allocation.
Correlation_Window :: struct {
	window_frames: int,
	frames_filled: int,
	next_frame:    i64,
	window_start:  i64,
	sum_l:         f64,
	sum_r:         f64,
	sum_ll:        f64,
	sum_rr:        f64,
	sum_lr:        f64,
}

correlation_window_init :: proc(window: ^Correlation_Window, window_frames: int, origin_frame: i64 = 0) -> bool {
	if window_frames < 1 || origin_frame < 0 {
		return false
	}
	window^ = Correlation_Window{
		window_frames = window_frames,
		next_frame = origin_frame,
		window_start = origin_frame,
	}
	return true
}

correlation_window_reset :: proc(window: ^Correlation_Window, origin_frame: i64 = 0) {
	window_frames := window.window_frames
	window^ = Correlation_Window{
		window_frames = window_frames,
		next_frame = origin_frame,
		window_start = origin_frame,
	}
}

Correlation_Window_Callback :: #type proc(user_data: rawptr, record: Correlation_Record)

correlation_window_process :: proc(
	window: ^Correlation_Window,
	block: audio.Audio_Block,
	callback: Correlation_Window_Callback,
	user_data: rawptr = nil,
) -> bool {
	if !audio.audio_block_valid(block) || block.channels != 2 || window.window_frames < 1 {
		return false
	}
	if block.start_frame != window.next_frame {
		return false
	}
	for frame in 0 ..< block.frames {
		left := f64(block.interleaved[frame * 2])
		right := f64(block.interleaved[frame * 2 + 1])
		window.sum_l += left
		window.sum_r += right
		window.sum_ll += left * left
		window.sum_rr += right * right
		window.sum_lr += left * right
		window.frames_filled += 1
		window.next_frame += 1
		if window.frames_filled == window.window_frames {
			record := Correlation_Record{
				start_frame = window.window_start,
				frames = window.window_frames,
				valid = true,
			}
			record.value, record.valid = correlation_from_moments(
				window.sum_l, window.sum_r, window.sum_ll, window.sum_rr, window.sum_lr,
				window.window_frames,
			)
			if callback != nil {
				callback(user_data, record)
			}
			window.frames_filled = 0
			window.window_start += i64(window.window_frames)
			window.sum_l = 0
			window.sum_r = 0
			window.sum_ll = 0
			window.sum_rr = 0
			window.sum_lr = 0
		}
	}
	return true
}

// stereo_correlation computes Pearson r for two equal-length channel slices.
stereo_correlation :: proc(left, right: []f32) -> (value: f32, valid: bool) {
	frames := min(len(left), len(right))
	if frames == 0 {
		return 0, false
	}
	sum_l := f64(0)
	sum_r := f64(0)
	sum_ll := f64(0)
	sum_rr := f64(0)
	sum_lr := f64(0)
	for frame in 0 ..< frames {
		l := f64(left[frame])
		r := f64(right[frame])
		sum_l += l
		sum_r += r
		sum_ll += l * l
		sum_rr += r * r
		sum_lr += l * r
	}
	return correlation_from_moments(sum_l, sum_r, sum_ll, sum_rr, sum_lr, frames)
}

correlation_from_moments :: proc(
	sum_l, sum_r, sum_ll, sum_rr, sum_lr: f64,
	frames: int,
) -> (value: f32, valid: bool) {
	if frames < 1 {
		return 0, false
	}
	n := f64(frames)
	cov := (sum_lr - sum_l * sum_r / n) / n
	var_l := (sum_ll - sum_l * sum_l / n) / n
	var_r := (sum_rr - sum_r * sum_r / n) / n
	if var_l <= CORRELATION_VARIANCE_EPSILON || var_r <= CORRELATION_VARIANCE_EPSILON {
		return 0, false
	}
	denominator := math.sqrt(var_l * var_r)
	if denominator <= 0 {
		return 0, false
	}
	r := f32(cov / denominator)
	return clamp(r, -1, 1), true
}
