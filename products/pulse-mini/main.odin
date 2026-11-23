// Pulse Mini: the standalone capture meter (Milestone 3).
//
// The graphical presentation is the default: a small always-on-top Alicorn
// window that you can leave on the desktop. `--headless` preserves the M3.1
// console meter, its flags and its output.
//
// Pipeline (both modes):
//
//   capture device -> bounded ring -> core/meter engine -> revisioned snapshot
//
// Analysis runs on the capture cadence. The console prints and the window
// present at independent cadences, and neither can change a measured value:
// they only read the latest snapshot. The window's UI thread never computes a
// measurement; `presentation` maps the published snapshot fields to bars,
// colours and an explicit state.
//
// Usage:
//   pulse-mini.exe [--input=loopback] [--self-loop] [--window=FRAMES]
//                  [--duration=N] [--always-on-top|--no-always-on-top]
//   pulse-mini.exe --headless [--print-cadence=Hz] [same capture flags]
//
// `--input=loopback` captures the default render endpoint in shared mode.
// `--self-loop` additionally renders a documented 400 Hz / -6.02 dBFS sine so
// the loopback has a known signal to measure (a functional smoke test).
//
// Idle loopback endpoints deliver no callbacks. Pulse Mini does not fabricate
// silence: it shows an explicit idle/disconnected state, keeps the source
// clock where it was, and starts a new analysis epoch when delivery resumes
// (see docs/architecture.md and docs/pulse-mini.md).
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"

import "carnival:core/transport"

// Options are shared by the graphical and console presentations. The window
// cadence is not a flag: the graphical mode is presentation-on-demand and
// rebuilds only when the mapped snapshot changes beyond an epsilon.
Options :: struct {
	input:          string,
	duration_s:     f64,
	duration_set:   bool,
	print_cadence:  f64,
	window_frames:  int,
	self_loop:      bool,
	headless:       bool,
	always_on_top:  bool,
}

parse_options :: proc() -> (Options, bool) {
	options := Options{
		input = "loopback",
		print_cadence = 10,
		window_frames = 1024,
		always_on_top = true,
	}
	for argument in os.args[1:] {
		switch argument {
		case "--self-loop":
			options.self_loop = true
			continue
		case "--headless":
			options.headless = true
			continue
		case "--always-on-top":
			options.always_on_top = true
			continue
		case "--no-always-on-top":
			options.always_on_top = false
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
			options.duration_set = true
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
		// The Alicorn native host parses the same command line. These are
		// diagnostics/window-management flags owned by the host; pulse-mini
		// accepts them so a run can enable a capture bundle without a second
		// argument syntax.
		case "--diagnostics", "--capture-dir", "--capture-after", "--idle-validation-seconds",
			"--smoke-hold-ms", "--input-debug", "--deferred-system-fonts",
			"--fallback-probe-after-first-frame":
			continue
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
	if !options.duration_set {
		// The console meter has always defaulted to a five-second run. The
		// graphical product stays open until the user closes it.
		options.duration_s = options.headless ? 5 : 0
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
	fmt.eprintln("usage: pulse-mini [--input=loopback] [--self-loop] [--window=FRAMES] [--duration=N] [--always-on-top|--no-always-on-top]")
	fmt.eprintln("       pulse-mini --headless [--print-cadence=Hz] [same capture flags]")
	fmt.eprintln("       pulse-mini --help")
}

main :: proc() {
	options, ok := parse_options()
	if !ok {
		usage()
		os.exit(2)
	}
	if options.headless {
		os.exit(run_headless(options))
	}
	run_graphical(options)
}

// ---------------------------------------------------------------------------
// Console presentation (Milestone 3.1 behavior, unchanged)
// ---------------------------------------------------------------------------

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

run_headless :: proc(options: Options) -> int {
	capture: Capture_Session
	if failure := capture_session_open(&capture, options.self_loop, options.window_frames); failure != .None {
		switch failure {
		case .Tone:
			fmt.eprintln("pulse-mini: --self-loop requested but no playback device is available")
		case .Engine, .Activation:
			fmt.eprintln("pulse-mini: meter engine could not be activated")
		case .None:
			// Unreachable: the caller only enters this branch for a failure.
		case .Session, .Start:
			fmt.eprintln("pulse-mini: could not open WASAPI loopback on the default render endpoint")
		}
		return 2
	}
	defer capture_session_close(&capture)

	fmt.printf(
		"pulse-mini: loopback %d Hz, window %d frames, print %.1f Hz, duration %.1fs%s\n",
		capture.sample_rate,
		options.window_frames,
		options.print_cadence,
		options.duration_s,
		options.self_loop ? ", self-loop tone 400 Hz" : "",
	)

	buffer: [CAPTURE_BUFFER_FRAMES * 2]f32
	started := time.tick_now()
	print_period_ns := i64(f64(time.Second) / options.print_cadence)
	next_print_ns: i64 = 0
	timed_out := false
	device_lost_printed := false
	stall_printed := false

	for {
		elapsed_ns := time.duration_nanoseconds(time.tick_since(started))
		if options.duration_s > 0 && f64(elapsed_ns) >= options.duration_s * f64(time.Second) {
			break
		}
		notifications := capture_session_poll(&capture, buffer[:])
		if .Resumed in notifications {
			fmt.println("pulse-mini: timeline discontinuity -> new analysis epoch")
		}
		if .Overrun in notifications {
			fmt.printf("pulse-mini: capture ring dropped %d frame(s) -> new analysis epoch\n",
				capture.last_dropped_delta)
		}
		if .Stall in notifications && !stall_printed {
			fmt.println("pulse-mini: stalled (no loopback data; source clock does not advance)")
			stall_printed = true
		}
		if .Device_Lost in notifications && !device_lost_printed {
			fmt.println("pulse-mini: device unavailable (retrying); no valid reading is shown")
			device_lost_printed = true
		}
		if .Recovered in notifications {
			fmt.println("pulse-mini: device recovered -> new analysis epoch")
			device_lost_printed = false
		}
		// A delivered block clears the adapter's stall latch; allow the next
		// stall to be reported again, matching the M3.1 console behavior.
		if !capture.stall_reported { stall_printed = false }
		if .Closed in notifications { timed_out = true }

		if elapsed_ns >= next_print_ns {
			print_snapshot(capture_session_snapshot(&capture), f64(elapsed_ns) / f64(time.Second), capture.device_unavailable)
			next_print_ns += print_period_ns
			if next_print_ns < elapsed_ns {
				next_print_ns = elapsed_ns + print_period_ns
			}
		}
		if timed_out { break }
		time.sleep(time.Millisecond)
	}

	snapshot := capture_session_snapshot(&capture)
	fmt.printf(
		"pulse-mini: done: %d frames (%.3fs), epoch %d, %d stall break(s), %d recover(ies), " +
		"%d overrun(s), %d dropped, session max %.1f/%.1f dBFS, final %s\n",
		capture.delivered,
		f64(capture.delivered) / f64(capture.sample_rate),
		snapshot.epoch,
		capture.stalls,
		capture.recoveries,
		capture.overruns,
		capture.dropped,
		f64(snapshot.session_max_db[0]),
		f64(snapshot.session_max_db[1]),
		snapshot.valid ? "valid" : "INVALID",
	)
	if capture.delivered == 0 {
		fmt.println("pulse-mini: the loopback endpoint produced no data (it may be silent); use --self-loop to verify the path")
	}
	return 0
}
