// Deterministic WAV replay.
//
// Supported input:
//   - RIFF/WAVE only (RIFX and RF64 are rejected)
//   - WAVE_FORMAT_PCM with u8 / s16 / s24 / s32
//   - WAVE_FORMAT_IEEE_FLOAT with f32 / f64
//   - WAVE_FORMAT_EXTENSIBLE whose sub-format is PCM or IEEE float and whose
//     valid bits equal the container bits
//
// Output is always interleaved f32 frames. The current decoder materializes the
// entire decoded buffer, and `wav_load_file` reads the entire file first:
// memory is O(file duration) in both input and output. This is a Milestone-0
// convenience, not a streaming decoder. Bounded-window/streaming decode is
// REMAINING WORK for long-file replay (#123); that issue's memory-independence
// requirement is not yet solved. See docs/architecture.md, "Remaining work".
//
// Strictness is deliberate: malformed headers, inconsistent block alignment /
// byte rate, data before fmt, duplicate fmt/data chunks, unsupported encodings
// and truncated chunks are explicit errors rather than guesses.
package stream

import "core:math"
import "core:mem"
import "core:os"

WAV_FORMAT_PCM        :: 1
WAV_FORMAT_IEEE_FLOAT :: 3
WAV_FORMAT_EXTENSIBLE :: 0xFFFE

// Wav_Audio owns the decoded interleaved f32 samples. Destroy with
// wav_audio_destroy; `descriptor.source` is empty for in-memory decodes and is
// the file path for wav_load_file.
Wav_Audio :: struct {
	descriptor: Audio_Stream_Descriptor,
	samples:    []f32,
	allocator:  mem.Allocator,
}

wav_audio_destroy :: proc(audio: ^Wav_Audio) {
	if audio.samples != nil {
		mem.free(raw_data(audio.samples), audio.allocator)
	}
	audio^ = {}
}

// wav_decode decodes a complete RIFF/WAVE byte buffer into one fully
// materialized f32 buffer (O(frames)), not a streaming window. `epoch` is
// stamped into the returned descriptor.
wav_decode :: proc(
	data: []byte,
	epoch: u64 = 0,
	allocator := context.allocator,
) -> (result: Wav_Audio, err: Audio_Error) {
	if len(data) < 12 {
		return {}, .Truncated
	}
	if !wav_tag_is(data, 0, "RIFF") {
		if wav_tag_is(data, 0, "RIFX") || wav_tag_is(data, 0, "RF64") {
			return {}, .Unsupported_Encoding
		}
		return {}, .Invalid_Header
	}
	if !wav_tag_is(data, 8, "WAVE") {
		return {}, .Invalid_Header
	}
	riff_size, ok := wav_u32le(data, 4)
	if !ok {
		return {}, .Truncated
	}
	if riff_size == 0xFFFFFFFF {
		// Streaming WAV; no known length and therefore not deterministic input.
		return {}, .Unsupported_Encoding
	}
	if int(riff_size) < 4 {
		return {}, .Invalid_Header
	}
	riff_end := 8 + int(riff_size)
	if riff_end > len(data) {
		return {}, .Truncated
	}

	channels: int
	sample_rate: int
	block_align: u16
	sample_format: Sample_Format
	fmt_seen := false
	data_seen := false
	data_offset := 0
	data_size := 0

	offset := 12
	for offset + 8 <= riff_end {
		chunk_size, size_ok := wav_u32le(data, offset + 4)
		if !size_ok {
			return {}, .Truncated
		}
		payload := offset + 8
		if u64(payload) + u64(chunk_size) > u64(riff_end) {
			return {}, .Truncated
		}
		chunk_end := payload + int(chunk_size)

		switch {
		case wav_tag_is(data, offset, "fmt "):
			if fmt_seen {
				return {}, .Invalid_Chunk
			}
			if data_seen {
				// The format must precede the data chunk.
				return {}, .Invalid_Chunk
			}
			fmt, format_err := wav_parse_fmt(data[payload:chunk_end])
			if format_err != .None {
				return {}, format_err
			}
			channels = fmt.channels
			sample_rate = fmt.sample_rate
			block_align = fmt.block_align
			sample_format = fmt.sample_format
			fmt_seen = true
		case wav_tag_is(data, offset, "data"):
			if data_seen {
				return {}, .Invalid_Chunk
			}
			if !fmt_seen {
				return {}, .Invalid_Chunk
			}
			if chunk_size == 0xFFFFFFFF {
				return {}, .Unsupported_Encoding
			}
			data_offset = payload
			data_size = int(chunk_size)
			data_seen = true
		}

		offset = chunk_end
		if offset & 1 != 0 {
			// RIFF chunks are word aligned; the pad byte is part of the file.
			if offset >= riff_end {
				return {}, .Truncated
			}
			offset += 1
		}
	}

	if !fmt_seen || !data_seen {
		return {}, .Invalid_Chunk
	}
	if block_align == 0 || int(block_align) != channels * wav_sample_format_bytes(sample_format) {
		return {}, .Invalid_Chunk
	}
	if data_size % int(block_align) != 0 {
		return {}, .Invalid_Chunk
	}
	frames := data_size / int(block_align)
	total_samples := frames * channels

	bytes_per_sample := wav_sample_format_bytes(sample_format)
	sample_bytes, alloc_err := mem.alloc_bytes(total_samples * size_of(f32), align_of(f32), allocator)
	if alloc_err != .None {
		return {}, .Allocation_Failed
	}
	samples := mem.slice_data_cast([]f32, sample_bytes)

	src := data[data_offset : data_offset + data_size]
	for index in 0 ..< total_samples {
		samples[index] = wav_decode_sample(src[index * bytes_per_sample : (index + 1) * bytes_per_sample], sample_format)
	}

	result = Wav_Audio{
		descriptor = Audio_Stream_Descriptor{
			sample_rate = sample_rate,
			channels = channels,
			channel_layout = channel_layout_for_channels(channels),
			sample_format = sample_format,
			total_frames = i64(frames),
			epoch = epoch,
		},
		samples = samples,
		allocator = allocator,
	}
	if !audio_stream_descriptor_valid(result.descriptor) {
		wav_audio_destroy(&result)
		return {}, .Invalid_Descriptor
	}
	return result, .None
}

// wav_load_file reads and decodes a WAV file. The returned descriptor's source
// is the path; it remains borrowed from the caller's string.
wav_load_file :: proc(
	path: string,
	epoch: u64 = 0,
	allocator := context.allocator,
) -> (result: Wav_Audio, err: Audio_Error) {
	data, read_err := os.read_entire_file_from_path(path, allocator)
	if read_err != nil {
		return {}, .Io_Error
	}
	defer delete(data, allocator)
	result, err = wav_decode(data, epoch, allocator)
	if err == .None {
		result.descriptor.source = path
	}
	return
}

// wav_encode writes interleaved f32 samples as a canonical RIFF/WAVE file with
// a 16-byte fmt chunk. `descriptor.total_frames` is ignored and recomputed from
// `samples`. Samples are clamped to [-1, 1] and quantized by rounding half away
// from zero for integer formats. The returned buffer is owned by the caller and
// must be freed with the same allocator.
wav_encode :: proc(
	samples: []f32,
	descriptor: Audio_Stream_Descriptor,
	allocator := context.allocator,
) -> (bytes: []byte, err: Audio_Error) {
	if !audio_stream_descriptor_valid(descriptor) || descriptor.channels < 1 {
		return nil, .Invalid_Descriptor
	}
	if len(samples) % descriptor.channels != 0 {
		return nil, .Invalid_Descriptor
	}
	bytes_per_sample := wav_sample_format_bytes(descriptor.sample_format)
	if bytes_per_sample == 0 {
		return nil, .Unsupported_Encoding
	}
	data_size := len(samples) * bytes_per_sample
	if u64(data_size) > 0xFFFF_FFFF - 64 {
		return nil, .Unsupported_Encoding
	}
	padding := data_size & 1
	total := 44 + data_size + padding
	raw, alloc_err := mem.alloc_bytes(total, 8, allocator)
	if alloc_err != .None {
		return nil, .Allocation_Failed
	}
	bytes = raw

	wav_put_tag(bytes, 0, "RIFF")
	wav_put_u32(bytes, 4, u32(total - 8))
	wav_put_tag(bytes, 8, "WAVE")
	wav_put_tag(bytes, 12, "fmt ")
	wav_put_u32(bytes, 16, 16) // fmt chunk payload size
	format_tag: u16 = WAV_FORMAT_PCM
	if descriptor.sample_format == .F32 || descriptor.sample_format == .F64 {
		format_tag = WAV_FORMAT_IEEE_FLOAT
	}
	wav_put_u16(bytes, 20, format_tag)
	wav_put_u16(bytes, 22, u16(descriptor.channels))
	wav_put_u32(bytes, 24, u32(descriptor.sample_rate))
	block_align := u16(descriptor.channels * bytes_per_sample)
	if i64(descriptor.sample_rate) * i64(block_align) > 0xFFFF_FFFF {
		return nil, .Unsupported_Encoding
	}
	wav_put_u32(bytes, 28, u32(descriptor.sample_rate * int(block_align)))
	wav_put_u16(bytes, 32, block_align)
	wav_put_u16(bytes, 34, u16(bytes_per_sample * 8))
	wav_put_tag(bytes, 36, "data")
	wav_put_u32(bytes, 40, u32(data_size))

	for index in 0 ..< len(samples) {
		wav_encode_sample(bytes[44 + index * bytes_per_sample : 44 + (index + 1) * bytes_per_sample], samples[index], descriptor.sample_format)
	}
	return bytes, .None
}

wav_write_file :: proc(
	path: string,
	samples: []f32,
	descriptor: Audio_Stream_Descriptor,
	allocator := context.allocator,
) -> Audio_Error {
	bytes, err := wav_encode(samples, descriptor, allocator)
	if err != .None {
		return err
	}
	defer mem.free(raw_data(bytes), allocator)
	if write_err := os.write_entire_file(path, bytes); write_err != nil {
		return .Io_Error
	}
	return .None
}

@(private)
Wav_Format :: struct {
	tag:           u16,
	channels:      int,
	sample_rate:   int,
	byte_rate:     u32,
	block_align:   u16,
	bits:          u16,
	sample_format: Sample_Format,
}

@(private)
wav_parse_fmt :: proc(payload: []byte) -> (result: Wav_Format, err: Audio_Error) {
	if len(payload) < 16 {
		return {}, .Invalid_Chunk
	}
	tag, _ := wav_u16le(payload, 0)
	channels_raw, _ := wav_u16le(payload, 2)
	sample_rate_raw, _ := wav_u32le(payload, 4)
	byte_rate, _ := wav_u32le(payload, 8)
	block_align, _ := wav_u16le(payload, 12)
	bits, _ := wav_u16le(payload, 14)
	if channels_raw == 0 || channels_raw > MAX_CHANNELS {
		return {}, .Invalid_Chunk
	}
	if sample_rate_raw == 0 {
		return {}, .Invalid_Chunk
	}
	if bits == 0 || bits % 8 != 0 {
		return {}, .Unsupported_Encoding
	}
	if len(payload) == 17 {
		return {}, .Invalid_Chunk
	}
	if len(payload) > 16 {
		cb_size, _ := wav_u16le(payload, 16)
		if int(cb_size) > len(payload) - 18 {
			return {}, .Invalid_Chunk
		}
		if tag == WAV_FORMAT_EXTENSIBLE {
			if cb_size < 22 || len(payload) < 40 {
				return {}, .Invalid_Chunk
			}
			valid_bits, _ := wav_u16le(payload, 18)
			channel_mask, _ := wav_u32le(payload, 20)
			subformat, _ := wav_u16le(payload, 24)
			if valid_bits != 0 && valid_bits != bits {
				return {}, .Unsupported_Encoding
			}
			if channel_mask != 0 && wav_popcount(u32(channel_mask)) != int(channels_raw) {
				return {}, .Invalid_Chunk
			}
			if subformat == WAV_FORMAT_PCM || subformat == WAV_FORMAT_IEEE_FLOAT {
				if !wav_subformat_guid_tail_is_standard(payload[24:40]) {
					return {}, .Unsupported_Encoding
				}
				tag = subformat
			} else {
				return {}, .Unsupported_Encoding
			}
		}
	}

	sample_format: Sample_Format
	switch tag {
	case WAV_FORMAT_PCM:
		switch bits {
		case 8:  sample_format = .U8
		case 16: sample_format = .S16
		case 24: sample_format = .S24
		case 32: sample_format = .S32
		case:    return {}, .Unsupported_Encoding
		}
	case WAV_FORMAT_IEEE_FLOAT:
		switch bits {
		case 32: sample_format = .F32
		case 64: sample_format = .F64
		case:    return {}, .Unsupported_Encoding
		}
	case:
		return {}, .Unsupported_Encoding
	}

	expected_align := int(channels_raw) * wav_sample_format_bytes(sample_format)
	if int(block_align) != expected_align {
		return {}, .Invalid_Chunk
	}
	if u64(byte_rate) != u64(sample_rate_raw) * u64(block_align) {
		return {}, .Invalid_Chunk
	}

	return Wav_Format{
		tag = tag,
		channels = int(channels_raw),
		sample_rate = int(sample_rate_raw),
		byte_rate = byte_rate,
		block_align = block_align,
		bits = bits,
		sample_format = sample_format,
	}, .None
}

@(private)
wav_sample_format_bytes :: proc(format: Sample_Format) -> int {
	switch format {
	case .U8:  return 1
	case .S16: return 2
	case .S24: return 3
	case .S32: return 4
	case .F32: return 4
	case .F64: return 8
	case .Unknown: return 0
	}
	return 0
}

@(private)
wav_decode_sample :: proc(p: []byte, format: Sample_Format) -> f32 {
	switch format {
	case .U8:
		return (f32(p[0]) - 128.0) / 128.0
	case .S16:
		v := i16(u16(p[0]) | u16(p[1]) << 8)
		return f32(v) / 32768.0
	case .S24:
		v := i32(u32(p[0]) | u32(p[1]) << 8 | u32(p[2]) << 16)
		if v & 0x0080_0000 != 0 {
			v |= ~i32(0x00FF_FFFF)
		}
		return f32(v) / 8388608.0
	case .S32:
		v := i32(u32(p[0]) | u32(p[1]) << 8 | u32(p[2]) << 16 | u32(p[3]) << 24)
		return f32(v) / 2147483648.0
	case .F32:
		bits := u32(p[0]) | u32(p[1]) << 8 | u32(p[2]) << 16 | u32(p[3]) << 24
		return f32(transmute(f32)bits)
	case .F64:
		lo := u64(p[0]) | u64(p[1]) << 8 | u64(p[2]) << 16 | u64(p[3]) << 24
		hi := u64(p[4]) | u64(p[5]) << 8 | u64(p[6]) << 16 | u64(p[7]) << 24
		return f32(transmute(f64)(lo | hi << 32))
	case .Unknown:
		return 0
	}
	return 0
}

@(private)
wav_encode_sample :: proc(dst: []byte, value: f32, format: Sample_Format) {
	v := f64(value)
	if math.is_nan(v) {
		v = 0
	}
	if v > 1.0 { v = 1.0 }
	if v < -1.0 { v = -1.0 }
	switch format {
	case .U8:
		q := i64(math.round(v * 128.0)) + 128
		q = clamp(q, 0, 255)
		dst[0] = byte(q)
	case .S16:
		q := i64(math.round(v * 32768.0))
		q = clamp(q, -32768, 32767)
		u := u16(u32(q) & 0xFFFF)
		dst[0] = byte(u)
		dst[1] = byte(u >> 8)
	case .S24:
		q := i64(math.round(v * 8388608.0))
		q = clamp(q, -8388608, 8388607)
		u := u32(q) & 0x00FF_FFFF
		dst[0] = byte(u)
		dst[1] = byte(u >> 8)
		dst[2] = byte(u >> 16)
	case .S32:
		q := i64(math.round(v * 2147483648.0))
		q = clamp(q, -2147483648, 2147483647)
		u := u32(q)
		dst[0] = byte(u)
		dst[1] = byte(u >> 8)
		dst[2] = byte(u >> 16)
		dst[3] = byte(u >> 24)
	case .F32:
		bits := transmute(u32)value
		dst[0] = byte(bits)
		dst[1] = byte(bits >> 8)
		dst[2] = byte(bits >> 16)
		dst[3] = byte(bits >> 24)
	case .F64:
		bits := transmute(u64)f64(value)
		for i in 0 ..< 8 {
			dst[i] = byte(bits >> (8 * u64(i)))
		}
	case .Unknown:
	}
}

@(private)
wav_tag_is :: proc(data: []byte, offset: int, tag: string) -> bool {
	if offset < 0 || offset + len(tag) > len(data) {
		return false
	}
	for i in 0 ..< len(tag) {
		if data[offset + i] != tag[i] {
			return false
		}
	}
	return true
}

@(private)
wav_put_tag :: proc(data: []byte, offset: int, tag: string) {
	for i in 0 ..< len(tag) {
		data[offset + i] = tag[i]
	}
}

@(private)
wav_u16le :: proc(data: []byte, offset: int) -> (u16, bool) {
	if offset < 0 || offset + 2 > len(data) {
		return 0, false
	}
	return u16(data[offset]) | u16(data[offset + 1]) << 8, true
}

@(private)
wav_u32le :: proc(data: []byte, offset: int) -> (u32, bool) {
	if offset < 0 || offset + 4 > len(data) {
		return 0, false
	}
	return u32(data[offset]) |
		u32(data[offset + 1]) << 8 |
		u32(data[offset + 2]) << 16 |
		u32(data[offset + 3]) << 24, true
}

@(private)
wav_put_u16 :: proc(data: []byte, offset: int, value: u16) {
	data[offset] = byte(value)
	data[offset + 1] = byte(value >> 8)
}

@(private)
wav_put_u32 :: proc(data: []byte, offset: int, value: u32) {
	data[offset] = byte(value)
	data[offset + 1] = byte(value >> 8)
	data[offset + 2] = byte(value >> 16)
	data[offset + 3] = byte(value >> 24)
}

@(private)
wav_popcount :: proc(value: u32) -> int {
	count := 0
	v := value
	for v != 0 {
		count += 1
		v &= v - 1
	}
	return count
}

@(private)
wav_subformat_guid_tail_is_standard :: proc(guid: []byte) -> bool {
	if len(guid) < 16 {
		return false
	}
	return guid[2] == 0 && guid[3] == 0 &&
		guid[4] == 0 && guid[5] == 0 &&
		guid[6] == 0x10 && guid[7] == 0 &&
		guid[8] == 0x80 && guid[9] == 0 &&
		guid[10] == 0 && guid[11] == 0xAA &&
		guid[12] == 0 && guid[13] == 0x38 &&
		guid[14] == 0x9B && guid[15] == 0x71
}
