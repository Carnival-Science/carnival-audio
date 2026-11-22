package audio

import "core:testing"

@(test)
test_descriptor_and_layout :: proc(t: ^testing.T) {
	descriptor := Audio_Stream_Descriptor{
		sample_rate = 48000,
		channels = 2,
		channel_layout = .Stereo,
		sample_format = .F32,
		total_frames = 100,
		epoch = 7,
	}
	testing.expect(t, audio_stream_descriptor_valid(descriptor), "valid stereo descriptor")
	testing.expect_value(t, channel_layout_channels(.Stereo), 2)
	testing.expect_value(t, channel_layout_for_channels(1), Channel_Layout.Mono)
	testing.expect_value(t, channel_layout_for_channels(3), Channel_Layout.Unknown)

	bad := descriptor
	bad.sample_rate = 0
	testing.expect(t, !audio_stream_descriptor_valid(bad), "zero sample rate is invalid")
	bad = descriptor
	bad.channels = MAX_CHANNELS + 1
	testing.expect(t, !audio_stream_descriptor_valid(bad), "too many channels is invalid")
	bad = descriptor
	bad.channels = 1 // layout still says Stereo
	testing.expect(t, !audio_stream_descriptor_valid(bad), "layout/channel conflict is invalid")
	bad.channel_layout = .Unknown
	testing.expect(t, audio_stream_descriptor_valid(bad), "unknown layout permits any channel count")
	bad = descriptor
	bad.sample_format = .Unknown
	testing.expect(t, !audio_stream_descriptor_valid(bad), "unknown format is invalid")
	bad = descriptor
	bad.total_frames = -2
	testing.expect(t, !audio_stream_descriptor_valid(bad), "negative total other than -1 is invalid")
}

@(test)
test_interleave_round_trip :: proc(t: ^testing.T) {
	frames := 4
	channels := 2
	planar := [][]f32{
		{0, 1, 2, 3},
		{-1, -2, -3, -4},
	}
	interleaved := make([]f32, frames * channels)
	defer delete(interleaved)
	testing.expect(t, interleave_f32(interleaved, planar, frames, channels), "interleave")
	testing.expect_value(t, interleaved[0], f32(0))
	testing.expect_value(t, interleaved[1], f32(-1))
	testing.expect_value(t, interleaved[6], f32(3))
	testing.expect_value(t, interleaved[7], f32(-4))

	out := [][]f32{make([]f32, frames), make([]f32, frames)}
	defer delete(out[0])
	defer delete(out[1])
	testing.expect(t, deinterleave_f32(out, interleaved, frames, channels), "deinterleave")
	testing.expect(t, out[0][3] == 3 && out[1][3] == -4, "channel order preserved")

	block := Audio_Block{start_frame = 10, frames = frames, channels = channels, interleaved = interleaved}
	testing.expect(t, audio_block_valid(block), "block valid")
	channel_view := make([]f32, frames)
	defer delete(channel_view)
	testing.expect(t, audio_block_deinterleave_channel(block, 1, channel_view), "channel view")
	testing.expect(t, channel_view[0] == -1 && channel_view[3] == -4, "channel view values")

	block.interleaved = interleaved[:len(interleaved) - 1]
	testing.expect(t, !audio_block_valid(block), "short block invalid")
}

@(test)
test_wav_round_trip_all_formats :: proc(t: ^testing.T) {
	values := [?]f32{-1.0, -0.75, -0.5, -0.25, 0.0, 0.25, 0.5, 0.75}
	formats := [?]Sample_Format{.U8, .S16, .S24, .S32, .F32, .F64}
	for format in formats {
		samples := make([]f32, len(values))
		defer delete(samples)
		copy(samples, values[:])
		descriptor := Audio_Stream_Descriptor{
			sample_rate = 44100,
			channels = 1,
			channel_layout = .Mono,
			sample_format = format,
			total_frames = -1,
		}
		bytes, encode_err := wav_encode(samples, descriptor)
		testing.expectf(t, encode_err == .None, "%v encode failed: %v", format, encode_err)
		if encode_err != .None {
			continue
		}
		decoded, decode_err := wav_decode(bytes)
		testing.expectf(t, decode_err == .None, "%v decode failed: %v", format, decode_err)
		if decode_err == .None {
			testing.expect_value(t, decoded.descriptor.sample_format, format)
			testing.expect_value(t, decoded.descriptor.sample_rate, 44100)
			testing.expect_value(t, decoded.descriptor.channels, 1)
			testing.expect_value(t, decoded.descriptor.total_frames, i64(len(values)))
			testing.expect_value(t, len(decoded.samples), len(values))
			for index in 0 ..< len(values) {
				testing.expectf(t,
					transmute(u32)decoded.samples[index] == transmute(u32)values[index],
					"%v sample %d not bit-exact: %v != %v",
					format, index, decoded.samples[index], values[index])
			}
			wav_audio_destroy(&decoded)
		}
		delete(bytes)
	}
}

@(test)
test_wav_odd_data_padding :: proc(t: ^testing.T) {
	// Mono u8 with three frames yields a three-byte data chunk, which must be
	// followed by one pad byte.
	samples := [3]f32{0.0, 0.5, -0.5}
	descriptor := Audio_Stream_Descriptor{
		sample_rate = 8000,
		channels = 1,
		channel_layout = .Mono,
		sample_format = .U8,
	}
	bytes, err := wav_encode(samples[:], descriptor)
	testing.expect_value(t, err, Audio_Error.None)
	testing.expect_value(t, len(bytes), 44 + 3 + 1)
	decoded, decode_err := wav_decode(bytes)
	testing.expect_value(t, decode_err, Audio_Error.None)
	testing.expect_value(t, decoded.descriptor.total_frames, i64(3))
	testing.expect(t, decoded.samples[0] == 0 && decoded.samples[1] == 0.5 && decoded.samples[2] == -0.5,
		"odd u8 data round-trips")
	wav_audio_destroy(&decoded)
	delete(bytes)
}

@(test)
test_wav_rejects_malformed :: proc(t: ^testing.T) {
	valid_samples := [4]f32{0, 0.25, -0.25, 0.5}
	descriptor := Audio_Stream_Descriptor{
		sample_rate = 48000,
		channels = 2,
		channel_layout = .Stereo,
		sample_format = .S16,
	}
	valid_bytes, err := wav_encode(valid_samples[:], descriptor)
	testing.expect_value(t, err, Audio_Error.None)

	expect_wav_error(t, {}, .Truncated, "empty")
	expect_wav_error(t, valid_bytes[:11], .Truncated, "short header")

	bad := clone_bytes(valid_bytes)
	wav_put_tag(bad, 8, "AVI ")
	expect_wav_error(t, bad, .Invalid_Header, "wrong WAVE tag")
	delete(bad)

	bad = clone_bytes(valid_bytes)
	wav_put_tag(bad, 0, "RF64")
	expect_wav_error(t, bad, .Unsupported_Encoding, "RF64")
	delete(bad)

	bad = clone_bytes(valid_bytes)
	wav_put_u16(bad, 20, 6) // A-law
	expect_wav_error(t, bad, .Unsupported_Encoding, "A-law")
	delete(bad)

	bad = clone_bytes(valid_bytes)
	wav_put_u16(bad, 32, 3) // block align no longer channels * 2
	expect_wav_error(t, bad, .Invalid_Chunk, "bad block align")
	delete(bad)

	bad = clone_bytes(valid_bytes)
	wav_put_u32(bad, 28, 123) // byte rate inconsistent with sample rate
	expect_wav_error(t, bad, .Invalid_Chunk, "bad byte rate")
	delete(bad)

	bad = clone_bytes(valid_bytes)
	wav_put_u32(bad, 40, 3) // data size not a multiple of block align
	expect_wav_error(t, bad, .Invalid_Chunk, "partial frame")
	delete(bad)

	bad = clone_bytes(valid_bytes)
	wav_put_u32(bad, 4, u32(len(bad))) // RIFF size claiming more bytes than present
	expect_wav_error(t, bad, .Truncated, "declared RIFF size too large")
	delete(bad)

	bad = clone_bytes(valid_bytes)
	wav_put_u32(bad, 16, 17) // impossible fmt payload size
	expect_wav_error(t, bad, .Invalid_Chunk, "fmt size 17")
	delete(bad)

	// Data before fmt.
	data_first := make([]byte, 12 + (8 + 4) + (8 + 16))
	defer delete(data_first)
	wav_put_tag(data_first, 0, "RIFF")
	wav_put_u32(data_first, 4, u32(len(data_first) - 8))
	wav_put_tag(data_first, 8, "WAVE")
	wav_put_tag(data_first, 12, "data")
	wav_put_u32(data_first, 16, 4)
	wav_put_tag(data_first, 24, "fmt ")
	wav_put_u32(data_first, 28, 16)
	expect_wav_error(t, data_first, .Invalid_Chunk, "data before fmt")

	// Duplicate data chunk.
	duplicate := make([]byte, len(valid_bytes) + 8 + 4)
	defer delete(duplicate)
	copy(duplicate, valid_bytes)
	wav_put_tag(duplicate, len(valid_bytes), "data")
	wav_put_u32(duplicate, len(valid_bytes) + 4, 4)
	wav_put_u32(duplicate, 4, u32(len(duplicate) - 8))
	expect_wav_error(t, duplicate, .Invalid_Chunk, "duplicate data chunk")

	delete(valid_bytes)
}

@(test)
test_wav_extensible_pcm :: proc(t: ^testing.T) {
	// One stereo s16 frame using WAVE_FORMAT_EXTENSIBLE with the PCM sub-format.
	total := 12 + (8 + 40) + (8 + 4)
	bytes := make([]byte, total)
	defer delete(bytes)
	wav_put_tag(bytes, 0, "RIFF")
	wav_put_u32(bytes, 4, u32(total - 8))
	wav_put_tag(bytes, 8, "WAVE")
	wav_put_tag(bytes, 12, "fmt ")
	wav_put_u32(bytes, 16, 40)
	wav_put_u16(bytes, 20, WAV_FORMAT_EXTENSIBLE)
	wav_put_u16(bytes, 22, 2)
	wav_put_u32(bytes, 24, 48000)
	wav_put_u32(bytes, 28, 48000 * 4)
	wav_put_u16(bytes, 32, 4)
	wav_put_u16(bytes, 34, 16)
	wav_put_u16(bytes, 36, 22) // cbSize
	wav_put_u16(bytes, 38, 16) // valid bits
	wav_put_u32(bytes, 40, 0x3) // left | right
	wav_put_u16(bytes, 44, WAV_FORMAT_PCM)
	// GUID tail after the 16-bit data1 field (bytes 46..60).
	tail := [?]byte{0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xAA, 0, 0x38, 0x9B, 0x71}
	for value, index in tail {
		bytes[46 + index] = value
	}
	wav_put_tag(bytes, 60, "data")
	wav_put_u32(bytes, 64, 4)
	wav_put_u16(bytes, 68, 0x4000)  // +0.5
	wav_put_u16(bytes, 70, 0xC000)  // -0.5

	decoded, err := wav_decode(bytes)
	testing.expect_value(t, err, Audio_Error.None)
	testing.expect_value(t, decoded.descriptor.sample_format, Sample_Format.S16)
	testing.expect_value(t, decoded.descriptor.channels, 2)
	testing.expect_value(t, decoded.descriptor.total_frames, i64(1))
	testing.expect(t, decoded.samples[0] == 0.5 && decoded.samples[1] == -0.5, "extensible PCM decodes")
	wav_audio_destroy(&decoded)
}

@(test)
test_signal_sine_closed_form :: proc(t: ^testing.T) {
	frames := 480
	channels := 2
	dst := make([]f32, frames * channels)
	defer delete(dst)
	err := generate_sine(dst, 48000, channels, 1000, 0.5, 0, 0)
	testing.expect_value(t, err, Audio_Error.None)
	testing.expect_value(t, dst[0], f32(0))
	// 1 kHz at 48 kHz has a 48-sample period; sample 12 is the positive peak.
	testing.expectf(t, abs_f32(dst[12 * channels] - 0.5) < 1e-7, "quarter-period peak: %v", dst[12 * channels])
	testing.expectf(t, abs_f32(dst[36 * channels] + 0.5) < 1e-7, "three-quarter-period trough: %v", dst[36 * channels])
	for frame in 0 ..< frames {
		testing.expect(t, dst[frame * channels] == dst[frame * channels + 1], "channels identical")
	}
}

@(test)
test_signal_generators_deterministic :: proc(t: ^testing.T) {
	frames := 64
	channels := 2
	first := make([]f32, frames * channels)
	defer delete(first)
	second := make([]f32, frames * channels)
	defer delete(second)

	testing.expect_value(t, generate_sweep(first, 48000, channels, 20, 20000, 0.8, 0, 0, .Exponential), Audio_Error.None)
	testing.expect_value(t, generate_sweep(second, 48000, channels, 20, 20000, 0.8, 0, 0, .Exponential), Audio_Error.None)
	testing.expect(t, slices_bit_equal(first, second), "exponential sweep repeatable")

	testing.expect_value(t, generate_sweep(first, 48000, channels, 100, 20000, 0.8, 0.25, 0, .Linear), Audio_Error.None)
	testing.expect_value(t, generate_sweep(second, 48000, channels, 100, 20000, 0.8, 0.25, 0, .Linear), Audio_Error.None)
	testing.expect(t, slices_bit_equal(first, second), "linear sweep repeatable")

	seed_a := generate_white_noise(first, 0x1234_5678_9ABC_DEF0)
	seed_b := generate_white_noise(second, 0x1234_5678_9ABC_DEF0)
	testing.expect(t, seed_a == seed_b && slices_bit_equal(first, second), "noise repeatable")
	for value in first {
		testing.expect(t, value >= -1.0 && value < 1.0, "noise in range")
	}
	// A zero seed must not produce an all-zero stream.
	_ = generate_white_noise(first, 0)
	non_zero := false
	for value in first {
		non_zero = non_zero || value != 0
	}
	testing.expect(t, non_zero, "zero seed is remapped")
}

@(test)
test_signal_impulse_and_step :: proc(t: ^testing.T) {
	frames := 8
	channels := 2
	dst := make([]f32, frames * channels)
	defer delete(dst)

	testing.expect_value(t, generate_impulse(dst, channels, 3, 0.75, 1), Audio_Error.None)
	for frame in 0 ..< frames {
		for channel in 0 ..< channels {
			expected: f32 = 0
			if frame == 3 && channel == 1 {
				expected = 0.75
			}
			testing.expect_value(t, dst[frame * channels + channel], expected)
		}
	}

	testing.expect_value(t, generate_step(dst, channels, 5, 0.25), Audio_Error.None)
	for frame in 0 ..< frames {
		expected: f32 = 0
		if frame >= 5 {
			expected = 0.25
		}
		testing.expect_value(t, dst[frame * channels], expected)
		testing.expect_value(t, dst[frame * channels + 1], expected)
	}

	testing.expect(t, generate_impulse(dst, channels, frames, 1.0) == .Invalid_Descriptor, "out-of-range impulse rejected")
	testing.expect(t, generate_step(dst, channels, -1, 1.0) == .Invalid_Descriptor, "negative step rejected")
}

@(private = "file")
expect_wav_error :: proc(t: ^testing.T, bytes: []byte, expected: Audio_Error, what: string) {
	decoded, decode_err := wav_decode(bytes)
	testing.expectf(t, decode_err == expected, "%s: expected %v, got %v", what, expected, decode_err)
	if decode_err == .None {
		wav_audio_destroy(&decoded)
	}
}

@(private = "file")
clone_bytes :: proc(source: []byte) -> []byte {
	result := make([]byte, len(source))
	copy(result, source)
	return result
}

@(private = "file")
abs_f32 :: proc(value: f32) -> f32 {
	if value < 0 {
		return -value
	}
	return value
}

@(private = "file")
slices_bit_equal :: proc(a, b: []f32) -> bool {
	if len(a) != len(b) {
		return false
	}
	for index in 0 ..< len(a) {
		if transmute(u32)a[index] != transmute(u32)b[index] {
			return false
		}
	}
	return true
}
