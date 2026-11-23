// Shared capture session for Pulse Mini's two presentations.
//
// The console mode (`--headless`) and the graphical mode run the same pipeline:
//
//   WASAPI shared-mode loopback -> bounded ring -> meter.Engine
//       -> revisioned Measurement_Snapshot (seqlock)
//
// The session owns the device, the self-loop tone and the engine. It performs
// no rendering and no allocation on the poll path; the graphical mode calls
// it from a capture worker thread and only reads the published snapshot from
// the UI thread.
package main

import "carnival:adapters/wasapi"
import "carnival:core/meter"
import "carnival:core/transport"

CAPTURE_BUFFER_FRAMES :: 1024
CAPTURE_RING_SECONDS :: 2

// Notification reports what one poll did, so each presentation can log it in
// its own vocabulary without re-deriving engine state.
Notification :: enum u8 {
	Resumed,
	Stall,
	Overrun,
	Device_Lost,
	Recovered,
	Closed,
}

Notification_Set :: bit_set[Notification]

Capture_Session :: struct {
	loopback:           wasapi.Loopback,
	session:            wasapi.Session,
	tone:               wasapi.Tone,
	engine:             ^meter.Engine,
	sample_rate:        int,
	// Live/diagnostic counters. They describe capture, not measurement.
	device_unavailable: bool,
	device_lost_noted:  bool,
	stall_reported:     bool,
	delivered:          u64,
	stalls:             int,
	recoveries:         int,
	overruns:           int,
	dropped:            u64,
	last_dropped_delta: u64,
	last_poll:         wasapi.Poll_Reason,
	idle_stalled:      bool, // adapter's threshold crossed; a short empty poll is not a stall
	closed:             bool,
}

// Open_Failure names the first stage that failed so each presentation can give
// the user an actionable message instead of a generic open error.
Open_Failure :: enum u8 {
	None,
	Tone,
	Session,
	Engine,
	Activation,
	Start,
}

// capture_session_open starts the optional self-loop tone first (shared-mode
// WASAPI binds a loopback stream to the endpoint active when it starts), then
// opens the session, activates the engine at the negotiated rate and starts
// delivery. On failure it releases everything it acquired.
capture_session_open :: proc(
	capture: ^Capture_Session,
	self_loop: bool,
	window_frames: int,
) -> Open_Failure {
	if capture == nil { return .Session }
	capture^ = Capture_Session{}

	if self_loop {
		if !wasapi.tone_start(&capture.tone, 400, 0.5, 48000) {
			return .Tone
		}
	}
	if !wasapi.session_open(&capture.session, wasapi.loopback_backend(&capture.loopback), wasapi.Device_Config{
		sample_rate = 48000,
		channels = 2,
		period_frames = 480,
	}, 48000 * CAPTURE_RING_SECONDS) {
		wasapi.tone_stop(&capture.tone)
		return .Session
	}
	capture.sample_rate = int(capture.session.info.sample_rate)
	if capture.sample_rate == 0 { capture.sample_rate = 48000 }

	capture.engine = meter.engine_create()
	if capture.engine == nil {
		wasapi.session_close(&capture.session)
		wasapi.tone_stop(&capture.tone)
		return .Engine
	}
	if !meter.engine_activate(capture.engine, f64(capture.sample_rate), 1024) {
		meter.engine_destroy(capture.engine)
		capture.engine = nil
		wasapi.session_close(&capture.session)
		wasapi.tone_stop(&capture.tone)
		return .Activation
	}
	parameters := meter.default_parameters()
	parameters.window_frames = window_frames
	meter.engine_set_parameters(capture.engine, parameters)

	if !wasapi.session_start(&capture.session) {
		meter.engine_destroy(capture.engine)
		capture.engine = nil
		wasapi.session_close(&capture.session)
		wasapi.tone_stop(&capture.tone)
		return .Start
	}
	// The capture episode is live; mark the engine as processing so an episode
	// switch would be refused while audio runs.
	meter.engine_set_processing(capture.engine, true)
	return .None
}

// capture_session_close releases the session in the reverse order of open and
// is safe to call after a partial open.
capture_session_close :: proc(capture: ^Capture_Session) {
	if capture == nil { return }
	if capture.engine != nil {
		meter.engine_set_processing(capture.engine, false)
		meter.engine_destroy(capture.engine)
		capture.engine = nil
	}
	wasapi.session_close(&capture.session)
	wasapi.tone_stop(&capture.tone)
}

// capture_session_poll performs one bounded poll and pushes any delivered audio
// into the engine. The engine publishes a snapshot on every push and on every
// noted discontinuity; this function performs no rendering or I/O.
capture_session_poll :: proc(capture: ^Capture_Session, buffer: []f32) -> Notification_Set {
	notifications: Notification_Set
	poll := wasapi.session_poll(&capture.session, buffer, CAPTURE_BUFFER_FRAMES)
	capture.last_poll = poll.reason
	switch poll.reason {
	case .Data:
		if poll.resumed {
			event := capture.device_unavailable ? meter.Discontinuity_Event.Device_Recovered : meter.Discontinuity_Event.Stall
			meter.engine_note_discontinuity(capture.engine, 0, event)
			capture.recoveries += 1
			notifications += {.Resumed}
		}
		capture.device_unavailable = false
		capture.device_lost_noted = false
		// The returned block predates any frames the ring dropped while the
		// consumer was behind, so push it first and then close that epoch.
		_ = meter.engine_push_interleaved(capture.engine, buffer[:poll.frames * 2], poll.frames, -1)
		capture.delivered += u64(poll.frames)
		if poll.dropped_delta > 0 {
			meter.engine_note_discontinuity(capture.engine, poll.dropped_delta, .Capture_Overrun)
			capture.overruns += 1
			notifications += {.Overrun}
		}
		capture.stall_reported = false
		capture.idle_stalled = false
	case .Idle:
		if poll.dropped_delta > 0 {
			meter.engine_note_discontinuity(capture.engine, poll.dropped_delta, .Capture_Overrun)
			capture.overruns += 1
			notifications += {.Overrun}
		} else if poll.discontinuity {
			meter.engine_note_discontinuity(capture.engine, 0, .Stall)
			capture.stalls += 1
		}
		capture.idle_stalled = poll.discontinuity || capture.session.stalled
		if !capture.stall_reported {
			notifications += {.Stall}
			capture.stall_reported = true
		}
	case .Recovered:
		meter.engine_note_discontinuity(capture.engine, 0, .Device_Recovered)
		capture.recoveries += 1
		capture.device_unavailable = false
		capture.device_lost_noted = false
		capture.idle_stalled = false
		notifications += {.Recovered}
	case .Device_Lost:
		if !capture.device_lost_noted {
			// Device loss is an epoch boundary: the last readings must never be
			// presented as live. The engine publishes an invalid snapshot
			// immediately, even while no audio arrives.
			meter.engine_note_discontinuity(capture.engine, 0, .Device_Lost)
			capture.device_lost_noted = true
			capture.device_unavailable = true
			notifications += {.Device_Lost}
		}
	case .Closed:
		capture.closed = true
		notifications += {.Closed}
	}
	capture.dropped = poll.dropped_frames
	capture.last_dropped_delta = poll.dropped_delta
	return notifications
}

// capture_session_snapshot is the presentation read. The graphical mode calls
// it only through the capture worker for its publication counter; the UI thread
// reads the same seqlock directly through meter.engine_snapshot.
capture_session_snapshot :: proc(capture: ^Capture_Session) -> transport.Measurement_Snapshot {
	if capture == nil { return {} }
	return meter.engine_snapshot(capture.engine)
}
