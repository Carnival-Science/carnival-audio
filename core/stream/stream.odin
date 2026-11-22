// Package stream defines the source-independent audio stream contract.
//
// Everything in this package is plain Odin. It must not import Alicorn, SDL,
// miniaudio, CLAP or any platform audio/graphics library (see AGENTS.md).
//
// Sample clock semantics
// ----------------------
// A stream is identified by an epoch (u64). Within one epoch, frame 0 is the
// first frame ever produced for that epoch and every frame has an absolute,
// monotonically increasing index. Blocks carry `start_frame`, so analysis can
// assign each sample to a fixed window without consulting wall-clock time or
// the block partition schedule.
//
// A new epoch is started by reset, seek, source replacement or a sample-format
// change. Events describe boundaries explicitly: `.Start` at frame 0 of an
// epoch, `.Discontinuity` at the first frame after lost input, `.Stop` at the
// first frame no longer produced. Downstream sample-complete analysis must
// invalidate itself when a discontinuity is observed unless it can account for
// every frame; Milestone 0 replay never produces discontinuities.
//
// Sample formats
// --------------
// On-disk and device formats are described by `Sample_Format`. Analysis always
// runs on interleaved f32 frames. The decode conventions are documented in
// `docs/determinism.md` and implemented in wav.odin.
package stream

// Maximum channel count accepted by the core. Fixed-size accumulators use this
// as their static bound, which keeps every analysis type allocation-free.
MAX_CHANNELS :: 32

// Sample_Format is the representation of one sample in the source.
Sample_Format :: enum u8 {
	Unknown,
	U8,
	S16,
	S24,
	S32,
	F32,
	F64,
}

// Channel_Layout is a small, portable description of the channel order. It is
// deliberately not a full speaker-mask model; layout-sensitive mixing is
// deferred until a real requirement exists.
Channel_Layout :: enum u8 {
	Unknown,
	Mono,
	Stereo,
	Quad,
	Surround_5_1,
	Surround_7_1,
}

// Audio_Error is returned by decoders, encoders and generated-signal helpers.
Audio_Error :: enum u8 {
	None,
	Invalid_Descriptor,
	Invalid_Header,
	Invalid_Chunk,
	Unsupported_Encoding,
	Truncated,
	Allocation_Failed,
	Io_Error,
}

audio_error_string :: proc(err: Audio_Error) -> string {
	switch err {
	case .None:                 return "none"
	case .Invalid_Descriptor:   return "invalid stream descriptor"
	case .Invalid_Header:       return "invalid file header"
	case .Invalid_Chunk:        return "invalid chunk"
	case .Unsupported_Encoding: return "unsupported encoding"
	case .Truncated:            return "truncated input"
	case .Allocation_Failed:    return "allocation failed"
	case .Io_Error:             return "file I/O failed"
	}
	return "unknown audio error"
}

// Audio_Stream_Descriptor describes a stream independently of any source
// implementation. `source` is borrowed: the producer keeps it alive for as long
// as the descriptor is in use. `total_frames` may be -1 for a live stream.
Audio_Stream_Descriptor :: struct {
	sample_rate:    int,
	channels:       int,
	channel_layout: Channel_Layout,
	sample_format:  Sample_Format,
	total_frames:   i64,
	epoch:          u64,
	source:         string,
}

audio_stream_descriptor_valid :: proc(d: Audio_Stream_Descriptor) -> bool {
	if d.sample_rate <= 0 || d.channels < 1 || d.channels > MAX_CHANNELS {
		return false
	}
	if d.sample_format == .Unknown {
		return false
	}
	if d.channel_layout != .Unknown && channel_layout_channels(d.channel_layout) != d.channels {
		return false
	}
	if d.total_frames < -1 {
		return false
	}
	return true
}

channel_layout_channels :: proc(layout: Channel_Layout) -> int {
	switch layout {
	case .Mono:         return 1
	case .Stereo:       return 2
	case .Quad:         return 4
	case .Surround_5_1: return 6
	case .Surround_7_1: return 8
	case .Unknown:      return 0
	}
	return 0
}

channel_layout_for_channels :: proc(channels: int) -> Channel_Layout {
	switch channels {
	case 1: return .Mono
	case 2: return .Stereo
	case 4: return .Quad
	case 6: return .Surround_5_1
	case 8: return .Surround_7_1
	}
	return .Unknown
}

// Audio_Event_Kind marks a clock/boundary event. `frame` is the absolute frame
// index at which the event takes effect (the event occurs *before* that frame),
// within `epoch`.
Audio_Event_Kind :: enum u8 {
	Start,
	Discontinuity,
	Stop,
}

Audio_Event :: struct {
	kind:  Audio_Event_Kind,
	epoch: u64,
	frame: i64,
}

// Audio_Block is one bounded, borrowed view of interleaved f32 frames.
// `interleaved` has exactly `frames * channels` samples and is owned by the
// producer for the duration of the consumer call. Analysis must not retain it.
Audio_Block :: struct {
	start_frame: i64,
	frames:      int,
	channels:    int,
	interleaved: []f32,
}

audio_block_valid :: proc(block: Audio_Block) -> bool {
	if block.start_frame < 0 || block.frames < 0 {
		return false
	}
	if block.channels < 1 || block.channels > MAX_CHANNELS {
		return false
	}
	return len(block.interleaved) == block.frames * block.channels
}

audio_block_empty :: proc(channels: int) -> Audio_Block {
	return Audio_Block{channels = channels}
}

// audio_block_channel returns a planar view of `channel` by copying every
// `channels`-th sample. `dst` must have at least `block.frames` elements.
audio_block_deinterleave_channel :: proc(block: Audio_Block, channel: int, dst: []f32) -> bool {
	if !audio_block_valid(block) || channel < 0 || channel >= block.channels {
		return false
	}
	if len(dst) < block.frames {
		return false
	}
	for frame in 0 ..< block.frames {
		dst[frame] = block.interleaved[frame * block.channels + channel]
	}
	return true
}

// deinterleave_f32 copies an interleaved buffer into planar channel slices.
// Every destination must have room for `frames`.
deinterleave_f32 :: proc(dst: [][]f32, interleaved: []f32, frames, channels: int) -> bool {
	if frames < 0 || channels < 1 || len(interleaved) != frames * channels {
		return false
	}
	if len(dst) != channels {
		return false
	}
	for channel in 0 ..< channels {
		if len(dst[channel]) < frames {
			return false
		}
	}
	for frame in 0 ..< frames {
		for channel in 0 ..< channels {
			dst[channel][frame] = interleaved[frame * channels + channel]
		}
	}
	return true
}

// interleave_f32 copies planar channel slices into an interleaved buffer.
interleave_f32 :: proc(dst: []f32, planar: [][]f32, frames, channels: int) -> bool {
	if frames < 0 || channels < 1 || len(dst) != frames * channels {
		return false
	}
	if len(planar) != channels {
		return false
	}
	for channel in 0 ..< channels {
		if len(planar[channel]) < frames {
			return false
		}
	}
	for frame in 0 ..< frames {
		for channel in 0 ..< channels {
			dst[frame * channels + channel] = planar[channel][frame]
		}
	}
	return true
}

// format_debug_string is intentionally small; it is used by tests and error
// reporting, not by real-time paths.
format_debug_string :: proc(format: Sample_Format) -> string {
	switch format {
	case .U8:  return "u8"
	case .S16: return "s16"
	case .S24: return "s24"
	case .S32: return "s32"
	case .F32: return "f32"
	case .F64: return "f64"
	case .Unknown: return "unknown"
	}
	return "unknown"
}
