// Minimal 32-bit float WAV writer for laboratory artifacts.
//
// Verification writes its own inputs and outputs as IEEE-float WAV so an
// external tool can inspect them. This is not `core/stream`'s WAV decoder: the
// writer is independent and only ever writes.
package verification_lab

import "core:os"

WAV_HEADER_BYTES :: 44

write_u16 :: proc(data: ^[dynamic]u8, value: u16) {
	append(data, u8(value), u8(value >> 8))
}

write_u32 :: proc(data: ^[dynamic]u8, value: u32) {
	append(data, u8(value), u8(value >> 8), u8(value >> 16), u8(value >> 24))
}

write_f32 :: proc(data: ^[dynamic]u8, value: f32) {
	bits := transmute(u32)value
	write_u32(data, bits)
}

// write_wav_f32 writes interleaved stereo float WAV. `channels` must be 1 or 2.
write_wav_f32 :: proc(
	path: string,
	planar: [][]f32,
	frames: int,
	sample_rate: u32,
) -> bool {
	channels := len(planar)
	if channels < 1 || channels > 2 || frames < 0 {
		return false
	}
	data_bytes := frames * channels * 4
	data := make([dynamic]u8, 0, WAV_HEADER_BYTES + data_bytes, context.temp_allocator)
	defer delete(data)
	append(&data, "RIFF")
	write_u32(&data, u32(36 + data_bytes))
	append(&data, "WAVE")
	append(&data, "fmt ")
	write_u32(&data, 16)
	write_u16(&data, 3) // IEEE float
	write_u16(&data, u16(channels))
	write_u32(&data, sample_rate)
	write_u32(&data, sample_rate * u32(channels) * 4)
	write_u16(&data, u16(channels * 4))
	write_u16(&data, 32)
	append(&data, "data")
	write_u32(&data, u32(data_bytes))
	for frame in 0 ..< frames {
		for channel in 0 ..< channels {
			value := channel < len(planar) && frame < len(planar[channel]) ? planar[channel][frame] : 0
			write_f32(&data, value)
		}
	}
	return os.write_entire_file(path, data[:]) == nil
}
