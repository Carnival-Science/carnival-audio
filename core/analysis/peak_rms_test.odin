package analysis

import "core:math"
import "core:testing"

import audio "pulse:core/audio"

RMS_Test_Context :: struct {
	count:    int,
	last:     RMS_Record,
	start_ok: bool,
}

rms_test_callback :: proc(user: rawptr, record: RMS_Record) {
	ctx := cast(^RMS_Test_Context)user
	expected_start := i64(ctx.count * record.frames)
	ctx.start_ok = ctx.start_ok && record.start_frame == expected_start
	ctx.count += 1
	ctx.last = record
}

RMS_Count_Context :: struct {
	record: RMS_Record
}

rms_count_callback :: proc(user: rawptr, record: RMS_Record) {
	ctx := cast(^RMS_Count_Context)user
	ctx.record = record
}

Correlation_Test_Context :: struct {
	count:  int,
	values: [4]f32,
	valids: [4]bool,
}

correlation_test_callback :: proc(user: rawptr, record: Correlation_Record) {
	ctx := cast(^Correlation_Test_Context)user
	if ctx.count < 4 {
		ctx.values[ctx.count] = record.value
		ctx.valids[ctx.count] = record.valid
	}
	ctx.count += 1
}

@(test)
test_sample_peak_exact_and_partition_independent :: proc(t: ^testing.T) {
	samples := [?]f32{0.1, -0.2, 0.8, 0.3, -0.8, 0.4}
	block := audio.Audio_Block{start_frame = 100, frames = 2, channels = 2, interleaved = samples[:4]}
	peak := sample_peak(block)
	testing.expect(t, peak.valid, "peak valid")
	testing.expect_value(t, peak.magnitude, f32(0.8))
	testing.expect_value(t, peak.frame, i64(101))
	testing.expect_value(t, peak.channel, 0)

	acc: Peak_Accumulator
	testing.expect(t, peak_accumulator_init(&acc, 2), "init")
	testing.expect(t, peak_accumulator_process(&acc, block), "process first")
	rest := audio.Audio_Block{start_frame = 102, frames = 1, channels = 2, interleaved = samples[4:]}
	testing.expect(t, peak_accumulator_process(&acc, rest), "process second")
	testing.expect_value(t, acc.overall.magnitude, f32(0.8))
	testing.expect_value(t, acc.overall.frame, i64(101))
	testing.expect_value(t, acc.per_channel[1].magnitude, f32(0.4))
	testing.expect_value(t, acc.per_channel[1].frame, i64(102))

	peak_accumulator_reset(&acc)
	testing.expect(t, !acc.overall.valid, "reset clears overall")
	testing.expect(t, !acc.per_channel[0].valid, "reset clears channels")
}

@(test)
test_dbfs_conventions :: proc(t: ^testing.T) {
	// Full-scale square wave: RMS 1.0 => 0 dBFS.
	testing.expect(t, rms_to_dbfs(1.0) == 0.0, "full-scale square is 0 dBFS")
	// Full-scale sine: RMS 1/sqrt(2) => -3.010299956639812 dBFS.
	sine_rms := f32(1.0 / math.sqrt_f64(2.0))
	testing.expectf(t, math.abs(rms_to_dbfs(sine_rms) - (-3.010299956639812)) < 1e-5,
		"sine RMS in dBFS: %v", rms_to_dbfs(sine_rms))
	testing.expect_value(t, rms_to_dbfs(0), DBFS_FLOOR)
	testing.expect_value(t, peak_amplitude_to_dbfs(1), f32(0))
	testing.expectf(t, math.abs(peak_amplitude_to_dbfs(0.5) - (-6.020599913279624)) < 1e-5,
		"half amplitude: %v", peak_amplitude_to_dbfs(0.5))
}

@(test)
test_rms_window_closed_form :: proc(t: ^testing.T) {
	frames := 4800
	channels := 2
	samples := make([]f32, frames * channels)
	defer delete(samples)
	testing.expect_value(t, audio.generate_sine(samples, 48000, channels, 1000, 1.0), audio.Audio_Error.None)

	window: RMS_Window
	testing.expect(t, rms_window_init(&window, 480, channels), "init")
	ctx := RMS_Test_Context{start_ok = true}
	block := audio.Audio_Block{start_frame = 0, frames = frames, channels = channels, interleaved = samples}
	testing.expect(t, rms_window_process(&window, block, rms_test_callback, &ctx), "process")
	testing.expect_value(t, ctx.count, 10)
	testing.expect(t, ctx.start_ok, "windows are sample-clock aligned")
	testing.expectf(t, math.abs(ctx.last.rms[0] - 0.70710678) < 1e-6, "sine RMS: %v", ctx.last.rms[0])
	testing.expectf(t, math.abs(rms_over(samples) - 0.70710678) < 1e-6, "direct RMS: %v", rms_over(samples))
	testing.expect(t, ctx.last.rms[0] == ctx.last.rms[1], "identical channels")

	// A non-contiguous block must be rejected, not silently accumulated.
	gap := audio.Audio_Block{start_frame = 9999, frames = 10, channels = channels, interleaved = samples[:20]}
	testing.expect(t, !rms_window_process(&window, gap, rms_test_callback, &ctx), "gap rejected")
	testing.expect_value(t, ctx.count, 10)
}

@(test)
test_rms_window_silence_and_dc :: proc(t: ^testing.T) {
	frames := 16
	channels := 1
	samples := make([]f32, frames)
	defer delete(samples)
	window: RMS_Window
	testing.expect(t, rms_window_init(&window, frames, channels), "init")
	ctx: RMS_Count_Context
	block := audio.Audio_Block{start_frame = 0, frames = frames, channels = channels, interleaved = samples}
	testing.expect(t, rms_window_process(&window, block, rms_count_callback, &ctx), "process silence")
	testing.expect_value(t, ctx.record.rms[0], f32(0))
	testing.expect_value(t, rms_to_dbfs(ctx.record.rms[0]), DBFS_FLOOR)

	for index in 0 ..< frames {
		samples[index] = 0.25
	}
	dc_block := audio.Audio_Block{start_frame = i64(frames), frames = frames, channels = channels, interleaved = samples}
	testing.expect(t, rms_window_process(&window, dc_block, rms_count_callback, &ctx), "process DC")
	testing.expect_value(t, ctx.record.rms[0], f32(0.25))
}

@(test)
test_peak_hold_hold_and_decay :: proc(t: ^testing.T) {
	samples := make([]f32, 2)
	defer delete(samples)
	hold: Peak_Hold
	testing.expect(t, peak_hold_init(&hold, Peak_Hold_Config{
		channels = 2,
		sample_rate = 48000,
		hold_frames = 3,
		decay = .Linear,
		linear_decay_per_second = 48000, // 1.0 amplitude per frame
	}), "init")
	history: [8]f32
	for frame in 0 ..< 8 {
		samples[0] = 1.0
		if frame > 0 {
			samples[0] = 0
		}
		samples[1] = 0
		block := audio.Audio_Block{start_frame = i64(frame), frames = 1, channels = 2, interleaved = samples}
		testing.expect(t, peak_hold_process(&hold, block), "process frame")
		history[frame] = hold.held[0]
	}
	testing.expect_value(t, history[0], f32(1))
	testing.expect_value(t, history[1], f32(1))
	testing.expect_value(t, history[2], f32(1))
	testing.expect_value(t, history[3], f32(1))
	testing.expect_value(t, history[4], f32(0))
	testing.expect_value(t, history[5], f32(0))
	peak_hold_reset(&hold)
	testing.expect_value(t, hold.held[0], f32(0))
	testing.expect_value(t, hold.hold_remaining[0], 0)

	log_hold: Peak_Hold
	testing.expect(t, peak_hold_init(&log_hold, Peak_Hold_Config{
		channels = 1,
		sample_rate = 48000,
		hold_frames = 0,
		decay = .Logarithmic,
		db_decay_per_second = 6.0205999, // halve amplitude per second
	}), "init log")
	one := [1]f32{1}
	_ = peak_hold_process(&log_hold, audio.Audio_Block{frames = 1, channels = 1, interleaved = one[:]})
	zeros := make([]f32, 48000)
	defer delete(zeros)
	_ = peak_hold_process(&log_hold, audio.Audio_Block{start_frame = 1, frames = 48000, channels = 1, interleaved = zeros})
	testing.expectf(t, math.abs(log_hold.held[0] - 0.5) < 0.001, "one second at 6.02 dB/s is ~0.5: %v", log_hold.held[0])
}

@(test)
test_correlation_cases :: proc(t: ^testing.T) {
	frames := 1024
	left := make([]f32, frames)
	defer delete(left)
	right := make([]f32, frames)
	defer delete(right)
	testing.expect_value(t, audio.generate_sine(left, 48000, 1, 997, 0.5), audio.Audio_Error.None)

	copy(right, left)
	value, valid := stereo_correlation(left, right)
	testing.expect(t, valid && value > 0.9999 && value <= 1, "identical channels correlate +1")
	for index in 0 ..< frames {
		right[index] = -left[index]
	}
	value, valid = stereo_correlation(left, right)
	testing.expect(t, valid && value < -0.9999 && value >= -1, "inverted channels correlate -1")
	testing.expect_value(t, audio.generate_sine(right, 48000, 1, 997, 0.5, math.PI / 2), audio.Audio_Error.None)
	value, valid = stereo_correlation(left, right)
	testing.expect(t, valid && math.abs(value) < 0.01, "quadrature channels correlate ~0")

	for index in 0 ..< frames {
		left[index] = 0
		right[index] = 0
	}
	value, valid = stereo_correlation(left, right)
	testing.expect(t, !valid && value == 0, "silence invalid, value 0")
	for index in 0 ..< frames {
		left[index] = 0.25
		right[index] = 0.25
	}
	value, valid = stereo_correlation(left, right)
	testing.expect(t, !valid && value == 0, "DC invalid, value 0")
	value, valid = stereo_correlation(left, right[:0])
	testing.expect(t, !valid && value == 0, "empty invalid")
}

@(test)
test_correlation_window_alignment :: proc(t: ^testing.T) {
	frames := 512
	channels := 2
	samples := make([]f32, frames * channels)
	defer delete(samples)
	testing.expect_value(t, audio.generate_sine(samples, 48000, channels, 1000, 0.5), audio.Audio_Error.None)

	window: Correlation_Window
	testing.expect(t, correlation_window_init(&window, 256), "init")
	ctx: Correlation_Test_Context
	block := audio.Audio_Block{frames = frames, channels = channels, interleaved = samples}
	testing.expect(t, correlation_window_process(&window, block, correlation_test_callback, &ctx), "process")
	testing.expect_value(t, ctx.count, 2)
	testing.expect(t, ctx.valids[0] && ctx.valids[1], "valid windows")
	testing.expect(t, ctx.values[0] > 0.9999 && ctx.values[1] > 0.9999, "identical stereo = +1")

	gap := audio.Audio_Block{start_frame = 1024, frames = 2, channels = 2, interleaved = samples[:4]}
	testing.expect(t, !correlation_window_process(&window, gap, correlation_test_callback, &ctx), "gap rejected")
}
