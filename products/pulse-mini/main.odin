// Pulse Mini: the standalone capture meter (Milestone 3).
//
// capture device -> bounded ring -> core/meter engine -> revisioned snapshot
//
// Analysis is snapshot-driven: the engine analyses every delivered block and
// publishes a latest-wins snapshot; the console prints at an independent
// cadence. `--print-cadence` therefore cannot change measured values (only how
// often a value is shown).
//
// Usage:
//   pulse-mini.exe --input=loopback [--duration=N] [--print-cadence=Hz]
//                  [--window=FRAMES] [--self-loop]
//
// `--input=loopback` captures the default render endpoint in shared mode.
// `--self-loop` additionally renders a documented 400 Hz / -6.02 dBFS sine so
// the loopback has a known signal to measure (a functional smoke test).
//
// Idle loopback endpoints deliver no callbacks. Pulse Mini does not fabricate
// silence: it prints an explicit stall, keeps the source clock where it was,
// and starts a new analysis epoch when delivery resumes (see
// docs/architecture.md).
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"

import "carnival:core/meter"
import "carnival:core/transport"

import "carnival:adapters/wasapi"

BUFFER_FRAMES :: 1024

Options :: struct {
	input:          string,
	duration_s:     f64,
	print_cadence:  f64,
	window_frames:  int,
	self_loop:      bool,
}

parse_options :: proc() -> (Options, bool) {
	options := Options{
		input = "loopback",
		duration_s = 5,
		print_cadence = 10,
		window_frames = 1024,
	}
	for argument in os.args[1:] {
		if argument == "--self-loop" {
			options.self_loop = true
			continue
		}
		key, value := split_flag(argument)
		switch key {
		case "--input":
			options.input = value
		case "--duration":
			parsed, ok := strconv.parse_f64(value)
			if !ok || parsed < 0 {
				return options, false
			}
			options.duration_s = parsed
		case "--print-cadence":
			parsed, ok := strconv.parse_f64(value)
			if !ok || parsed <= 0 {
				return options, false
			}
			options.print_cadence = parsed
		case "--window":
			parsed, ok := strconv.parse_int(value)
			if !ok || parsed < 1 || parsed > 8192 {
				return options, false
			}
			options.window_frames = parsed
		case "--help":
			return options, false
		case:
			fmt.eprintf("pulse-mini: unknown argument %q\n", argument)
			return options, false
		}
	}
	if options.input != "loopback" {
		fmt.eprintf("pulse-mini: only --input=loopback is implemented in this milestone\n")
		return options, false
	}
	return options, true
}

split_flag :: proc(argument: string) -> (key, value: string) {
	for index in 0 ..< len(argument) {
		if argument[index] == '=' {
			return argument[:index], argument[index + 1:]
		}
	}
	return argument, ""
}

usage :: proc() {
	fmt.eprintln("usage: pulse-mini --input=loopback [--duration=N] [--print-cadence=Hz] [--window=FRAMES] [--self-loop]")
}

print_snapshot :: proc(
	snapshot: transport.Measurement_Snapshot,
	elapsed_s: f64,
	device_unavailable: bool,
) {
	fmt.printf(
		"t=%6.2fs frm=%-9d epoch=%d L[win %6.1f hold %6.1f max %6.1f rms %6.1f dBFS] " +
		"R[win %6.1f hold %6.1f max %6.1f rms %6.1f dBFS] %s%s\n",
		elapsed_s,
		snapshot.frame,
		snapshot.epoch,
		f64(snapshot.window_peak_db[0]),
		f64(snapshot.peak_hold_db[0]),
		f64(snapshot.session_max_db[0]),
		f64(snapshot.rms_db[0]),
		f64(snapshot.window_peak_db[1]),
		f64(snapshot.peak_hold_db[1]),
		f64(snapshot.session_max_db[1]),
		f64(snapshot.rms_db[1]),
		snapshot.valid ? "valid" : "INVALID",
		device_unavailable ? " (device unavailable)" : (snapshot.overrun ? " (audio discontinuity)" : ""),
	)
}

main :: proc() {
	options, ok := parse_options()
	if !ok {
		usage()
		os.exit(2)
	}

	loopback: wasapi.Loopback
	session: wasapi.Session
	tone: wasapi.Tone
	// Start the self-loop tone before opening the loopback endpoint: shared-mode
	// WASAPI binds a loopback stream to the endpoint that is active when the
	// stream starts, and a fresh playback device can otherwise be missed.
	if options.self_loop {
		if !wasapi.tone_start(&tone, 400, 0.5, 48000) {
			fmt.eprintln("pulse-mini: --self-loop requested but no playback device is available")
			os.exit(2)
		}
	}
	// Odin's `defer` is scope-bound, so this must live in the procedure scope:
	// placing it inside the `if` would stop the tone at the end of the block.
	defer wasapi.tone_stop(&tone)
	// 48 kHz is the requested rate; the device reports the negotiated rate in
	// `session.info.sample_rate` and the engine is activated with that value.
	if !wasapi.session_open(&session, wasapi.loopback_backend(&loopback), wasapi.Device_Config{
		sample_rate = 48000,
		channels = 2,
		period_frames = 480,
	}, 48000 * 2) {
		fmt.eprintln("pulse-mini: could not open WASAPI loopback on the default render endpoint")
		os.exit(2)
	}
	defer wasapi.session_close(&session)
	if session.info.sample_rate == 0 {
		session.info.sample_rate = 48000
	}

	engine := meter.engine_create()
	if engine == nil {
		fmt.eprintln("pulse-mini: engine allocation failed")
		os.exit(2)
	}
	defer meter.engine_destroy(engine)
	if !meter.engine_activate(engine, f64(session.info.sample_rate), 1024) {
		fmt.eprintln("pulse-mini: engine activation failed")
		os.exit(2)
	}
	parameters := meter.default_parameters()
	parameters.window_frames = options.window_frames
	meter.engine_set_parameters(engine, parameters)

	if !wasapi.session_start(&session) {
		fmt.eprintln("pulse-mini: loopback device did not start")
		os.exit(2)
	}
	// The capture episode is live; mark the engine as processing so an episode
	// switch would be refused if one were attempted.
	meter.engine_set_processing(engine, true)
	defer meter.engine_set_processing(engine, false)

	fmt.printf(
		"pulse-mini: loopback %d Hz, window %d frames, print %.1f Hz, duration %.1fs%s\n",
		session.info.sample_rate,
		options.window_frames,
		options.print_cadence,
		options.duration_s,
		options.self_loop ? ", self-loop tone 400 Hz" : "",
	)

	buffer: [BUFFER_FRAMES * 2]f32
	started := time.tick_now()
	print_period_ns := i64(f64(time.Second) / options.print_cadence)
	next_print_ns: i64 = 0
	stall_reported := false
	device_lost_noted := false
	device_unavailable := false
	delivered: u64 = 0
	stalls := 0
	recoveries := 0
	overruns := 0
	dropped: u64 = 0
	timed_out := false

	for {
		elapsed_ns := time.duration_nanoseconds(time.tick_since(started))
		if options.duration_s > 0 && f64(elapsed_ns) >= options.duration_s * f64(time.Second) {
			break
		}
		poll := wasapi.session_poll(&session, buffer[:], BUFFER_FRAMES)
		switch poll.reason {
		case .Data:
			if poll.resumed {
				event := device_unavailable ? meter.Discontinuity_Event.Device_Recovered : meter.Discontinuity_Event.Stall
				meter.engine_note_discontinuity(engine, 0, event)
				recoveries += 1
				fmt.println("pulse-mini: timeline discontinuity -> new analysis epoch")
			}
			device_unavailable = false
			device_lost_noted = false
			// The returned block predates any frames the ring dropped while the
			// consumer was behind, so push it first and then close that epoch.
			_ = meter.engine_push_interleaved(engine, buffer[:poll.frames * 2], poll.frames, -1)
			delivered += u64(poll.frames)
			if poll.dropped_delta > 0 {
				// Capture-ring overflow: the source clock advanced by frames the
				// engine never received. Record the dropped range as an explicit
				// discontinuity so the affected window cannot look continuous.
				meter.engine_note_discontinuity(engine, poll.dropped_delta, .Capture_Overrun)
				overruns += 1
				fmt.printf("pulse-mini: capture ring dropped %d frame(s) -> new analysis epoch\n",
					poll.dropped_delta)
			}
			stall_reported = false
		case .Idle:
			if poll.dropped_delta > 0 {
				meter.engine_note_discontinuity(engine, poll.dropped_delta, .Capture_Overrun)
				overruns += 1
				fmt.printf("pulse-mini: capture ring dropped %d frame(s) -> new analysis epoch\n",
					poll.dropped_delta)
			} else if poll.discontinuity {
				meter.engine_note_discontinuity(engine, 0, .Stall)
				stalls += 1
			}
			if !stall_reported {
				fmt.println("pulse-mini: stalled (no loopback data; source clock does not advance)")
				stall_reported = true
			}
		case .Recovered:
			meter.engine_note_discontinuity(engine, 0, .Device_Recovered)
			recoveries += 1
			device_unavailable = false
			device_lost_noted = false
			fmt.println("pulse-mini: device recovered -> new analysis epoch")
		case .Device_Lost:
			if !device_lost_noted {
				// Device loss is an epoch boundary: the last readings must never
				// be presented as live. The engine publishes an invalid snapshot
				// immediately, even while no audio arrives.
				meter.engine_note_discontinuity(engine, 0, .Device_Lost)
				device_lost_noted = true
				device_unavailable = true
				fmt.println("pulse-mini: device unavailable (retrying); no valid reading is shown")
			}
		case .Closed:
			timed_out = true
		}
		dropped = poll.dropped_frames

		if elapsed_ns >= next_print_ns {
			print_snapshot(meter.engine_snapshot(engine), f64(elapsed_ns) / f64(time.Second), device_unavailable)
			next_print_ns += print_period_ns
			if next_print_ns < elapsed_ns {
				next_print_ns = elapsed_ns + print_period_ns
			}
		}
		if timed_out {
			break
		}
		time.sleep(time.Millisecond)
	}

	snapshot := meter.engine_snapshot(engine)
	fmt.printf(
		"pulse-mini: done: %d frames (%.3fs), epoch %d, %d stall break(s), %d recover(ies), " +
		"%d overrun(s), %d dropped, session max %.1f/%.1f dBFS, final %s\n",
		delivered,
		f64(delivered) / f64(session.info.sample_rate),
		snapshot.epoch,
		stalls,
		recoveries,
		overruns,
		dropped,
		f64(snapshot.session_max_db[0]),
		f64(snapshot.session_max_db[1]),
		snapshot.valid ? "valid" : "INVALID",
	)
	if delivered == 0 {
		fmt.println("pulse-mini: the loopback endpoint produced no data (it may be silent); use --self-loop to verify the path")
	}
}
