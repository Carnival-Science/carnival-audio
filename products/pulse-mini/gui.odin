// Graphical presentation: the Pulse Mini window.
//
// Threading
// ---------
// The UI thread never touches WASAPI and never computes a level. A capture
// worker owns the device and the meter engine: it polls the loopback ring,
// pushes delivered blocks, notes discontinuities and publishes the engine's
// seqlock snapshot. It wakes the host only when a new snapshot exists and the
// window is renderable.
//
// The UI thread reads the latest snapshot with meter.engine_snapshot (a lock-free
// seqlock read), maps it with the pure `presentation` package, and invalidates
// only when the mapped visual state changes beyond the documented epsilon.
// Cadence is therefore independent: analysis runs at the capture/window rate,
// presentation runs only when a frame would differ.
//
// Hidden windows
// --------------
// The native host reports renderable transitions. While hidden, the UI stores
// no frames and the capture worker suppresses wakeups; capture and snapshot
// publication continue. On restore the host asks for one forced frame from
// the latest snapshot.
package main

import "core:fmt"
import "core:sync"
import "core:thread"
import "core:time"

import ui "alicorn:ui"
import alicorn "alicorn:runtime"

import "carnival:core/transport"
import "carnival:products/pulse-mini/presentation"

GRAPHICAL_TITLE :: "Pulse Mini"
GRAPHICAL_WIDTH :: 560
GRAPHICAL_HEIGHT :: 460

// Palette for the window chrome. Meter colors come from the presentation
// mapping so the visual policy stays in one testable place.
BACKGROUND_COLOR :: u32(0x0b1220)
CARD_COLOR :: u32(0x111827)
TRACK_COLOR :: u32(0x1e293b)
TEXT_COLOR :: u32(0xe2e8f0)
MUTED_COLOR :: u32(0x94a3b8)
ACCENT_COLOR :: u32(0x38bdf8)

App :: struct {
	options:           Options,
	capture:           Capture_Session,
	worker:            ^thread.Thread,
	waker:             ui.Application_Waker,

	// Cross-thread words. The capture worker is the only writer of the
	// capture-side values; the UI thread is the only writer of `renderable`.
	stop:                   u32,
	renderable:             u32, // atomic bool: 1 while the window can be seen
	published:              u64,
	hidden_wakes_suppressed: u64,
	source_state:           u32, // presentation.Source_State

	// UI-thread presentation state.
	tracker:         presentation.Tracker,
	visual:          presentation.Visual,
	frames:          u64,
	wakes:           u64,
	startup_error:   string,
	host_services:   ui.UI_Host_Services,
	has_services:    bool,
	started:         time.Tick,
	duration_ns:     u64,
	quit_requested:  bool,
	last_hud_ns:     i64,
}

source_state_load :: proc(app: ^App) -> presentation.Source_State {
	return presentation.Source_State(sync.atomic_load_explicit(&app.source_state, .Acquire))
}

// capture_worker owns the device and the engine. It never renders and never
// reads UI state except the two atomic words below.
capture_worker :: proc(data: rawptr) {
	app := cast(^App)data
	buffer: [CAPTURE_BUFFER_FRAMES * 2]f32
	last_generation: u64 = 0
	for sync.atomic_load_explicit(&app.stop, .Acquire) == 0 {
		_ = capture_session_poll(&app.capture, buffer[:])
		source := presentation.Source_State.Live
		if app.capture.device_unavailable {
			source = .Device_Lost
		} else {
			switch app.capture.last_poll {
			case .Data:
				source = .Live
			case .Idle:
				// A poll with no frames is normal between audio callbacks. Only
				// the adapter's threshold (or a reported discontinuity) is a real
				// stall; a short empty poll keeps the previous presentation state.
				source = app.capture.idle_stalled ? .Stalled : source_state_load(app)
			case .Device_Lost:
				source = .Device_Lost
			case .Recovered:
				source = .Starting
			case .Closed:
				source = source_state_load(app)
			}
		}
		sync.atomic_store_explicit(&app.source_state, u32(source), .Release)

		snapshot := capture_session_snapshot(&app.capture)
		if snapshot.generation > last_generation {
			// Publication policy: the engine publishes once per intake block and
			// at least once per noted discontinuity. A generation advances by two
			// per publication (the seqlock's even/odd protocol), so the delta
			// divided by two is the number of presentation snapshots produced.
			publications := (snapshot.generation - last_generation) / 2
			if publications == 0 { publications = 1 }
			_ = sync.atomic_add_explicit(&app.published, publications, .Release)
			last_generation = snapshot.generation
			if sync.atomic_load_explicit(&app.renderable, .Acquire) != 0 {
				ui.wake(app.waker)
			} else {
				// Capture and publication continue; only the UI wake is elided.
				_ = sync.atomic_add_explicit(&app.hidden_wakes_suppressed, 1, .Release)
			}
		}
		time.sleep(time.Millisecond)
	}
}

open_error_message :: proc(failure: Open_Failure) -> string {
	switch failure {
	case .Tone:
		return "--self-loop requested but no playback device is available"
	case .Session:
		return "could not open WASAPI loopback on the default render endpoint"
	case .Engine, .Activation:
		return "meter engine could not be activated"
	case .Start:
		return "loopback device did not start"
	case .None:
		return ""
	}
	return "capture session failed"
}

graphical_start :: proc(app: ^App, waker: ui.Application_Waker) {
	app.waker = waker
	app.started = time.tick_now()
	sync.atomic_store_explicit(&app.renderable, 1, .Release)
	if app.options.duration_s > 0 {
		app.duration_ns = u64(app.options.duration_s * f64(time.Second))
		if app.has_services {
			_ = ui.ui_schedule_after(app.host_services.scheduler, .Frequent, app.duration_ns)
		}
	}
	// The first description is the empty starting state. It is derived by the
	// pure mapping, not by reading the engine.
	app.visual = presentation.snapshot_to_visual(transport.Measurement_Snapshot{}, .Starting)

	failure := capture_session_open(&app.capture, app.options.self_loop, app.options.window_frames)
	if failure != .None {
		app.startup_error = open_error_message(failure)
		sync.atomic_store_explicit(&app.source_state, u32(presentation.Source_State.Device_Lost), .Release)
		return
	}
	app.worker = thread.create_and_start_with_data(rawptr(app), capture_worker, name="pulse-mini-capture")
	if app.worker == nil {
		app.startup_error = "capture worker thread could not start"
		capture_session_close(&app.capture)
		sync.atomic_store_explicit(&app.source_state, u32(presentation.Source_State.Device_Lost), .Release)
	}
}

graphical_services :: proc(app: ^App, services: ui.UI_Host_Services) {
	app.host_services = services
	app.has_services = true
}

// refresh_presentation reads the latest snapshot and applies the epsilon
// policy. force=true is used on restore, where the retained surface may be
// stale or discarded.
refresh_presentation :: proc(app: ^App, ctx: ui.Application_Context, force := false) -> bool {
	snapshot := capture_session_snapshot(&app.capture)
	observation := presentation.observe(
		&app.tracker,
		snapshot,
		source_state_load(app),
		sync.atomic_load_explicit(&app.renderable, .Acquire) != 0,
		force,
	)
	app.visual = observation.visual
	if observation.render {
		ui.invalidate(ctx, "pulse-mini snapshot changed")
	}
	return observation.render
}

graphical_wake :: proc(app: ^App, ctx: ui.Application_Context) {
	app.wakes += 1
	rendered := refresh_presentation(app, ctx)
	if rendered || sync.atomic_load_explicit(&app.renderable, .Acquire) == 0 {
		return
	}
	// The diagnostic counter line changes on every publication even when the
	// meter levels are inside the epsilon. Coalesce it to at most one frame per
	// second so the window can show live totals without per-snapshot rebuilds.
	// A hidden or stalled meter has no wake to coalesce: it stays at zero work.
	now_ns := time.duration_nanoseconds(time.tick_since(app.started))
	if now_ns - app.last_hud_ns >= i64(time.Second) {
		app.last_hud_ns = now_ns
		ui.invalidate(ctx, "pulse-mini counter refresh")
	}
}

graphical_renderable_changed :: proc(app: ^App, rt: ^alicorn.Runtime, renderable: bool) {
	if app == nil || rt == nil { return }
	if renderable {
		sync.atomic_store_explicit(&app.renderable, 1, .Release)
		// The host calls this after the window becomes drawable again. Describe
		// one frame from the latest snapshot even if levels are unchanged.
		_ = refresh_presentation(app, ui.Application_Context(rt), force=true)
	} else {
		sync.atomic_store_explicit(&app.renderable, 0, .Release)
	}
	fmt.printf(
		"pulse-mini: window %s at %dms: frames=%d published=%d consumed=%d hidden_wakes_suppressed=%d\n",
		renderable ? "visible" : "hidden",
		time.duration_nanoseconds(time.tick_since(app.started)) / 1_000_000,
		app.frames,
		sync.atomic_load_explicit(&app.published, .Acquire),
		app.tracker.counters.observations,
		sync.atomic_load_explicit(&app.hidden_wakes_suppressed, .Acquire),
	)
}

graphical_scheduled_wake :: proc(app: ^App, _rt: ^alicorn.Runtime, _class: ui.UI_Scheduled_Wake_Class) {
	if app.duration_ns > 0 && !app.quit_requested &&
	   time.duration_nanoseconds(time.tick_since(app.started)) >= i64(app.duration_ns) {
		app.quit_requested = true
		ui.ui_quit_request(app.host_services.quit)
	}
}

graphical_stop :: proc(app: ^App) {
	sync.atomic_store_explicit(&app.stop, 1, .Release)
	if app.worker != nil {
		thread.join(app.worker)
		thread.destroy(app.worker)
		app.worker = nil
	}
	capture_session_close(&app.capture)
	elapsed := time.duration_nanoseconds(time.tick_since(app.started))
	counters := app.tracker.counters
	fmt.printf(
		"pulse-mini: gui counters: snapshots_published=%d snapshots_consumed=%d " +
		"frames=%d renders_skipped=%d hidden_wakes_suppressed=%d wakes=%d " +
		"epoch=%d elapsed_ms=%d final_state=%s\n",
		sync.atomic_load_explicit(&app.published, .Acquire),
		counters.observations,
		app.frames,
		counters.skipped_unchanged + counters.skipped_hidden,
		sync.atomic_load_explicit(&app.hidden_wakes_suppressed, .Acquire),
		app.wakes,
		app.visual.epoch,
		elapsed / 1_000_000,
		presentation.state_label(app.visual.state),
	)
}

@(private = "file")
ui_color :: proc(hex: u32) -> ui.Color {
	return ui.rgb(hex)
}

@(private = "file")
format_db :: proc(db: f32) -> string {
	if presentation.zone_from_db(db) == .Silent {
		return "--"
	}
	return fmt.tprintf("%.1f", f64(db))
}

graphical_render :: proc(app: ^App, ctx: ^ui.UI) {
	app.frames += 1
	visual := app.visual
	state := presentation.state_label(visual.state)
	if app.startup_error != "" { state = "CAPTURE UNAVAILABLE" }

	// Layout scopes stay in this procedure: a deferred ui.panel/ui.row helper
	// must open its children in the invocation block (AGENTS.md "Layout scopes"),
	// so the meter rows below are described inline rather than in wrappers.
	if ui.panel(
		ctx,
		grow=1,
		padding=18,
		gap=12,
		fill=ui_color(BACKGROUND_COLOR),
		label="pulse-mini-root",
	) {
		if ui.row(ctx, height=34, gap=10, align=.Center) {
			if ui.column(ctx, grow=1, gap=0) {
				ui.text(ctx, "PULSE MINI", size=22, color=ui_color(TEXT_COLOR))
				ui.text(ctx, "Stereo loopback meter", size=11, color=ui_color(MUTED_COLOR))
			}
			if ui.panel(
				ctx,
				height=26,
				padding=10,
				fill=ui_color(visual.state_color),
				radius=13,
				label="state-badge",
			) {
				ui.text(ctx, state, size=11, color=ui_color(0x0b1220))
			}
		}

		if app.startup_error != "" {
			if ui.panel(ctx, padding=12, gap=6, fill=ui_color(CARD_COLOR), radius=8) {
				ui.text(ctx, app.startup_error, size=14, color=ui_color(presentation.COLOR_STATE_DISCONNECTED))
				ui.text(ctx, "The window stays open; close it or rerun with --self-loop.", size=12,
					color=ui_color(MUTED_COLOR))
			}
		} else if ui.row(ctx, grow=1, gap=12) {
			for channel, index in visual.channels {
				if ui.panel(
					ctx,
					key=u64(index + 1),
					grow=1,
					height=-1,
					padding=14,
					gap=8,
					fill=ui_color(CARD_COLOR),
					radius=10,
					label="channel-card",
				) {
					if ui.row(ctx, height=20, gap=8, align=.Center) {
						ui.text(ctx, index == 0 ? "L" : "R", size=16, color=ui_color(TEXT_COLOR))
						ui.text(ctx, "PEAK", size=10, color=ui_color(MUTED_COLOR))
					}
					// Peak bar. Grow-weighted segments split the row by the already
					// published bar fraction; no description-time percentage width
					// is needed, so the bar is correct at every window size.
					if ui.row(ctx, height=14, gap=0) {
						if ui.panel(
							ctx,
							width=0,
							height=14,
							grow=max(channel.peak_percent / 100, 0.0001),
							padding=0,
							fill=ui_color(channel.peak_color),
							radius=7,
						) {}
						if ui.panel(
							ctx,
							width=0,
							height=14,
							grow=max(1 - channel.peak_percent / 100, 0.0001),
							padding=0,
							fill=ui_color(TRACK_COLOR),
							radius=7,
						) {}
					}
					// Peak-hold indicator: a thin marker-length bar. It uses the
					// published peak_hold field, not a locally computed decay.
					if ui.row(ctx, height=4, gap=0) {
						if ui.panel(
							ctx,
							width=0,
							height=4,
							grow=max(channel.hold_percent / 100, 0.0001),
							padding=0,
							fill=ui_color(channel.hold_color),
							radius=2,
						) {}
						if ui.panel(
							ctx,
							width=0,
							height=4,
							grow=max(1 - channel.hold_percent / 100, 0.0001),
							padding=0,
							fill=ui_color(TRACK_COLOR),
							radius=2,
						) {}
					}
					if ui.row(ctx, height=16, gap=6, align=.Center) {
						ui.text(ctx, "PEAK", size=11, color=ui_color(MUTED_COLOR),
							style=ui.layout_style(width=38))
						ui.text(ctx, fmt.tprintf("%s dBFS", format_db(channel.peak_db)), size=12,
							color=ui_color(TEXT_COLOR))
					}
					if ui.row(ctx, height=16, gap=6, align=.Center) {
						ui.text(ctx, "HOLD", size=11, color=ui_color(MUTED_COLOR),
							style=ui.layout_style(width=38))
						ui.text(ctx, fmt.tprintf("%s dBFS", format_db(channel.hold_db)), size=12,
							color=ui_color(TEXT_COLOR))
					}
					// RMS bar.
					if ui.row(ctx, height=8, gap=0) {
						if ui.panel(
							ctx,
							width=0,
							height=8,
							grow=max(channel.rms_percent / 100, 0.0001),
							padding=0,
							fill=ui_color(channel.rms_color),
							radius=4,
						) {}
						if ui.panel(
							ctx,
							width=0,
							height=8,
							grow=max(1 - channel.rms_percent / 100, 0.0001),
							padding=0,
							fill=ui_color(TRACK_COLOR),
							radius=4,
						) {}
					}
					if ui.row(ctx, height=16, gap=6, align=.Center) {
						ui.text(ctx, "RMS", size=11, color=ui_color(MUTED_COLOR),
							style=ui.layout_style(width=38))
						ui.text(ctx, fmt.tprintf("%s dBFS", format_db(channel.rms_db)), size=12,
							color=ui_color(TEXT_COLOR))
					}
					// Session maximum is a distinct presentation value: it is the
					// maximum since this analysis epoch began, not the current
					// window and not the hold envelope.
					ui.text(ctx, "SESSION MAX", size=10, color=ui_color(MUTED_COLOR))
					ui.text(ctx, fmt.tprintf("%s dBFS", format_db(channel.session_max_db)), size=18,
						color=ui_color(TEXT_COLOR))
					if ui.row(ctx, height=2, gap=0) {
						if ui.panel(
							ctx,
							width=0,
							height=2,
							grow=max(channel.session_max_percent / 100, 0.0001),
							padding=0,
							fill=ui_color(MUTED_COLOR),
							radius=1,
						) {}
						if ui.panel(
							ctx,
							width=0,
							height=2,
							grow=max(1 - channel.session_max_percent / 100, 0.0001),
							padding=0,
							fill=ui_color(TRACK_COLOR),
							radius=1,
						) {}
					}
				}
			}
		}

		if ui.panel(ctx, padding=10, gap=6, fill=ui_color(CARD_COLOR), radius=8) {
			if ui.row(ctx, height=18, gap=12, align=.Center) {
				ui.text(ctx, fmt.tprintf("epoch %d", visual.epoch), size=11, color=ui_color(MUTED_COLOR))
				ui.text(ctx, fmt.tprintf("%.1f kHz", f64(visual.sample_rate) / 1000), size=11,
					color=ui_color(MUTED_COLOR))
				ui.text(ctx, fmt.tprintf("window %d", app.options.window_frames), size=11,
					color=ui_color(MUTED_COLOR))
				ui.text(ctx, app.options.always_on_top ? "always-on-top" : "normal window", size=11,
					color=ui_color(ACCENT_COLOR))
			}
			counters := app.tracker.counters
			published := sync.atomic_load_explicit(&app.published, .Acquire)
			skipped := counters.skipped_unchanged + counters.skipped_hidden
			ui.text(
				ctx,
				fmt.tprintf("snapshots %d published / %d consumed | frames %d | skipped %d",
					published, counters.observations, app.frames, skipped),
				size=10,
				color=ui_color(MUTED_COLOR),
			)
			ui.text(
				ctx,
				"analysis is capture-driven; the UI maps the latest snapshot only",
				size=10,
				color=ui_color(MUTED_COLOR),
			)
		}
	}
}

run_graphical :: proc(options: Options) {
	app := App{options=options}
	app.visual = presentation.snapshot_to_visual(transport.Measurement_Snapshot{}, .Starting)
	ui.run(
		&app,
		graphical_render,
		title=GRAPHICAL_TITLE,
		width=GRAPHICAL_WIDTH,
		height=GRAPHICAL_HEIGHT,
		on_services=graphical_services,
		on_start=graphical_start,
		on_wake=graphical_wake,
		on_stop=graphical_stop,
		on_renderable_changed=graphical_renderable_changed,
		on_scheduled_wake=graphical_scheduled_wake,
		always_on_top=options.always_on_top,
	)
}
