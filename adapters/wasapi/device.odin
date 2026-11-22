// miniaudio WASAPI loopback backend and self-loop tone source.
//
// Only this file imports `vendor:miniaudio`; `core/` never does and
// `third_party/clap` never does. The WASAPI backend is shared-mode loopback on
// the default render endpoint (or the process-wide mix when a filter is set).
// The data callback writes whole frames into the session's bounded ring; it
// performs no allocation, locking or I/O.
package wasapi

import "base:runtime"
import "core:math"
import "core:sync"

// The Odin miniaudio bindings are version-checked at init against the vendored
// header in third_party/miniaudio (0.11.26). See that UPSTREAM.md.
import ma "vendor:miniaudio"

Loopback :: struct {
	ma_context:       ma.context_type,
	device:           ma.device,
	ring:             ^Capture_Ring,
	config:           Device_Config,
	loopback_support: bool,
	context_ready:    bool,
	device_ready:     bool,
	lost:             u32, // atomic bool bit
}

loopback_backend :: proc(state: ^Loopback) -> Backend {
	return Backend{
		ctx = rawptr(state),
		open = loopback_open,
		start = loopback_start,
		stop = loopback_stop,
		close = loopback_close,
		lost = loopback_lost,
	}
}

loopback_data_callback :: proc "c" (device: ^ma.device, output, input: rawptr, frame_count: u32) {
	context = runtime.default_context()
	_ = output
	state := cast(^Loopback)device.pUserData
	if state == nil || state.ring == nil || input == nil {
		return
	}
	samples := cast([^]f32)input
	_ = ring_write(state.ring, samples[:int(frame_count) * state.ring.channels], int(frame_count))
}

loopback_notification :: proc "c" (notification: ^ma.device_notification) {
	if notification == nil || notification.pDevice == nil {
		return
	}
	state := cast(^Loopback)notification.pDevice.pUserData
	if state == nil {
		return
	}
	switch notification.type {
	case .stopped, .rerouted, .interruption_began:
		sync.atomic_store_explicit(&state.lost, 1, .Release)
	case .started, .interruption_ended, .unlocked:
	}
}

loopback_open :: proc(
	ctx: rawptr,
	ring: ^Capture_Ring,
	config: Device_Config,
	info: ^Device_Info,
) -> bool {
	state := cast(^Loopback)ctx
	if state == nil || ring == nil {
		return false
	}
	if state.device_ready {
		loopback_close(ctx)
	}
	state.ring = ring
	state.config = config
	state.loopback_support = false
	if !state.context_ready {
		if ma.context_init(nil, 0, nil, &state.ma_context) != .SUCCESS {
			return false
		}
		state.context_ready = true
	}
	if !ma.context_is_loopback_supported(&state.ma_context) {
		return false
	}
	state.loopback_support = true
	device_config := ma.device_config_init(.loopback)
	device_config.sampleRate = config.sample_rate
	device_config.periodSizeInFrames = config.period_frames
	device_config.capture.format = .f32
	device_config.capture.channels = config.channels
	device_config.capture.shareMode = .shared
	device_config.dataCallback = loopback_data_callback
	device_config.notificationCallback = loopback_notification
	device_config.pUserData = rawptr(state)
	if ma.device_init(&state.ma_context, &device_config, &state.device) != .SUCCESS {
		return false
	}
	state.device_ready = true
	sync.atomic_store_explicit(&state.lost, 0, .Release)
	if info != nil {
		info.sample_rate = state.device.sampleRate
		if info.sample_rate == 0 {
			info.sample_rate = config.sample_rate
		}
		info.channels = state.device.capture.channels
		if info.channels == 0 {
			info.channels = config.channels
		}
		info.loopback = true
	}
	return true
}

loopback_start :: proc(ctx: rawptr) -> bool {
	state := cast(^Loopback)ctx
	if state == nil || !state.device_ready {
		return false
	}
	sync.atomic_store_explicit(&state.lost, 0, .Release)
	return ma.device_start(&state.device) == .SUCCESS
}

loopback_stop :: proc(ctx: rawptr) {
	state := cast(^Loopback)ctx
	if state == nil || !state.device_ready {
		return
	}
	_ = ma.device_stop(&state.device)
}

loopback_close :: proc(ctx: rawptr) {
	state := cast(^Loopback)ctx
	if state == nil {
		return
	}
	if state.device_ready {
		ma.device_uninit(&state.device)
		state.device_ready = false
	}
	if state.context_ready {
		ma.context_uninit(&state.ma_context)
		state.context_ready = false
	}
	state.ring = nil
}

loopback_lost :: proc(ctx: rawptr) -> bool {
	state := cast(^Loopback)ctx
	if state == nil {
		return false
	}
	return sync.atomic_load_explicit(&state.lost, .Acquire) != 0
}

// ---------------------------------------------------------------------------
// Self-loop tone source (verification and interactive smoke tests)
// ---------------------------------------------------------------------------

Tone :: struct {
	ma_context:       ma.context_type,
	device:        ma.device,
	context_ready: bool,
	device_ready:  bool,
	phase:         f64,
	frequency:     f64,
	amplitude:     f32,
	sample_rate:   f64,
}

tone_data_callback :: proc "c" (device: ^ma.device, output, input: rawptr, frame_count: u32) {
	context = runtime.default_context()
	_ = input
	tone := cast(^Tone)device.pUserData
	if tone == nil || output == nil {
		return
	}
	samples := cast([^]f32)output
	channels := int(tone.device.playback.channels)
	if channels < 1 {
		channels = 2
	}
	step := 2.0 * math.PI * tone.frequency / tone.sample_rate
	for frame in 0 ..< int(frame_count) {
		value := f32(f64(tone.amplitude) * math.sin(tone.phase))
		tone.phase += step
		if tone.phase > 2.0 * math.PI {
			tone.phase -= 2.0 * math.PI
		}
		for channel in 0 ..< channels {
			samples[frame * channels + channel] = value
		}
	}
}

// tone_start opens a default playback device and renders a continuous sine.
// `sample_rate == 0` uses the device default. It is used by the loopback
// self-loop test and is not part of the capture contract.
tone_start :: proc(
	tone: ^Tone,
	frequency: f64 = 440,
	amplitude: f32 = 0.5,
	sample_rate: u32 = 48000,
) -> bool {
	if tone == nil || sample_rate == 0 {
		return false
	}
	if ma.context_init(nil, 0, nil, &tone.ma_context) != .SUCCESS {
		return false
	}
	tone.context_ready = true
	tone.frequency = frequency
	tone.amplitude = amplitude
	tone.sample_rate = f64(sample_rate)
	tone.phase = 0
	config := ma.device_config_init(.playback)
	config.sampleRate = sample_rate
	config.playback.format = .f32
	config.playback.channels = 2
	config.dataCallback = tone_data_callback
	config.pUserData = rawptr(tone)
	if ma.device_init(&tone.ma_context, &config, &tone.device) != .SUCCESS {
		return false
	}
	tone.device_ready = true
	return ma.device_start(&tone.device) == .SUCCESS
}

tone_stop :: proc(tone: ^Tone) {
	if tone == nil {
		return
	}
	if tone.device_ready {
		_ = ma.device_stop(&tone.device)
		ma.device_uninit(&tone.device)
		tone.device_ready = false
	}
	if tone.context_ready {
		ma.context_uninit(&tone.ma_context)
		tone.context_ready = false
	}
}
