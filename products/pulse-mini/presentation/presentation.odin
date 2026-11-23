// Snapshot-to-visual mapping: the seeded presentation contract for Pulse Mini.
//
// This package is deliberately tiny and dependency-free. It imports the
// presentation record (`core/transport`) and nothing else: no Alicorn, no
// audio adapter, no platform code. That keeps the mapping an ordinary carnival
// package whose tests run without a UI toolchain, and it makes the rule
// structural: the UI cannot compute audio measurements because this layer only
// consumes values the meter engine already published.
//
// The mapping is a seed, not a standard. It is not exported from core, is not
// a stability promise, and is expected to change when a second graphical
// product exists. What it does fix is the *direction*: snapshot fields
// (`window_peak`, `rms`, `peak_hold`, `session_max`, validity, epoch) become
// bounded visual state (bar fractions, zones, colors, an explicit state kind).
// Audio-domain truth stays in core/meter.
package presentation

import "core:math"

import "carnival:core/transport"

// The displayed range. The engine's own floor is lower (it reports down to
// -120 dBFS); a utility meter that spends half its width on inaudible levels
// is worse, so the display clamps to a documented -60..0 dBFS window. This is
// a visual choice, not a measurement.
DISPLAY_FLOOR_DB :: f32(-60)
DISPLAY_CEILING_DB :: f32(0)

// Zone boundaries for the bar tint. They only describe how the already
// published dBFS value is styled.
ZONE_SAFE_BELOW_DB :: f32(-12)
ZONE_WARN_BELOW_DB :: f32(-3)

// EPSILON_PERCENT is the change threshold that decides whether a new snapshot
// is worth a new frame. 0.25% of the 60 dB display range is 0.15 dB, below
// what a user can read from the numeric labels, and comfortably above
// floating-point noise in repeated quiet windows.
EPSILON_PERCENT :: f32(0.25)

// Palette. Values are packed 0xRRGGBB so the mapping stays independent of any
// renderer's color type. The UI converts them once at the edge.
COLOR_SILENT :: u32(0x475569)
COLOR_SAFE :: u32(0x34d399)
COLOR_WARN :: u32(0xfbbf24)
COLOR_HOT :: u32(0xf87171)
COLOR_STATE_STARTING :: u32(0x94a3b8)
COLOR_STATE_LIVE :: u32(0x34d399)
COLOR_STATE_IDLE :: u32(0x94a3b8)
COLOR_STATE_DISCONNECTED :: u32(0xf87171)
COLOR_STATE_INVALID :: u32(0xfbbf24)
COLOR_TRACK :: u32(0x1e293b)

// Source_State is capture-lifecycle information owned by the adapter, not an
// audio measurement. The engine snapshot cannot distinguish "no callbacks yet"
// from "the endpoint disappeared", so the capture side reports that fact
// explicitly and the mapping combines the two.
Source_State :: enum u8 {
	Starting, // capture has not delivered anything yet
	Live, // the adapter is delivering data
	Stalled, // no callbacks; the engine has moved to an idle epoch
	Device_Lost, // the endpoint was removed or rerouted
}

// State is the one thing a user must be able to read from across the room.
State :: enum u8 {
	Starting,
	Live,
	Idle, // stalled: no data, no fabrication
	Disconnected, // device lost; never show the last reading as live
	Invalid_Window, // data is flowing, but this window crosses a gap/overrun
}

// Level_Zone styles one displayed value. It is derived only from the dBFS
// value the engine published.
Level_Zone :: enum u8 {
	Silent,
	Safe,
	Warn,
	Hot,
}

// Channel is the bounded visual state of one stereo channel.
Channel :: struct {
	peak_percent:         f32,
	rms_percent:          f32,
	hold_percent:         f32,
	session_max_percent:  f32,
	peak_db:              f32,
	rms_db:               f32,
	hold_db:              f32,
	session_max_db:       f32,
	peak_zone:            Level_Zone,
	rms_zone:             Level_Zone,
	hold_zone:            Level_Zone,
	peak_color:           u32,
	rms_color:            u32,
	hold_color:           u32,
}

// Visual is a complete, immutable description of one presented snapshot. The
// UI builds from this value; it does not read live engine state while drawing.
Visual :: struct {
	state:        State,
	epoch:        u64,
	generation:   u64,
	sample_rate:  int,
	channels:     [2]Channel,
	state_color:  u32,
}

// Counters are presentation-layer work counters. They answer "did the UI do
// more work than the data changed?" independently of any host counter.
Counters :: struct {
	observations:      u64, // snapshots offered to the tracker
	presented_changes: u64, // offers that produced a new frame
	skipped_unchanged: u64, // visible, but inside the epsilon
	skipped_hidden:    u64, // not visible; presentation work elided
}

// Skip_Reason explains why an observation did not request a frame.
Skip_Reason :: enum u8 {
	Changed,
	Unchanged,
	Hidden,
}

Observation :: struct {
	visual:  Visual,
	render:  bool,
	reason:  Skip_Reason,
}

// Tracker applies the presentation-on-demand policy. It owns the last
// presented visual and the counters. The app calls observe() from its wake
// callback; a true result means "store this visual and invalidate the root".
Tracker :: struct {
	visual:          Visual,
	have_visual:     bool,
	last_generation: u64,
	counters:        Counters,
}

// percent_from_db maps a published dBFS value onto the display bar. Values
// outside the display range clamp; non-finite values read as silence. This is
// the only arithmetic this package performs, and it is visual-only.
percent_from_db :: proc(db: f32) -> f32 {
	if math.is_nan(db) || math.is_inf(db) || db <= DISPLAY_FLOOR_DB {
		return 0
	}
	if db >= DISPLAY_CEILING_DB {
		return 100
	}
	return (db - DISPLAY_FLOOR_DB) / (DISPLAY_CEILING_DB - DISPLAY_FLOOR_DB) * 100
}

// zone_from_db classifies a published dBFS value for styling.
zone_from_db :: proc(db: f32) -> Level_Zone {
	if math.is_nan(db) || math.is_inf(db) || db <= DISPLAY_FLOOR_DB {
		return .Silent
	}
	if db < ZONE_SAFE_BELOW_DB {
		return .Safe
	}
	if db < ZONE_WARN_BELOW_DB {
		return .Warn
	}
	return .Hot
}

zone_color :: proc(zone: Level_Zone) -> u32 {
	switch zone {
	case .Silent:
		return COLOR_SILENT
	case .Safe:
		return COLOR_SAFE
	case .Warn:
		return COLOR_WARN
	case .Hot:
		return COLOR_HOT
	}
	return COLOR_SILENT
}

state_color :: proc(state: State) -> u32 {
	switch state {
	case .Starting:
		return COLOR_STATE_STARTING
	case .Live:
		return COLOR_STATE_LIVE
	case .Idle:
		return COLOR_STATE_IDLE
	case .Disconnected:
		return COLOR_STATE_DISCONNECTED
	case .Invalid_Window:
		return COLOR_STATE_INVALID
	}
	return COLOR_STATE_STARTING
}

state_label :: proc(state: State) -> string {
	switch state {
	case .Starting:
		return "STARTING"
	case .Live:
		return "LIVE"
	case .Idle:
		return "STALLED"
	case .Disconnected:
		return "DEVICE LOST"
	case .Invalid_Window:
		return "INVALID GAP"
	}
	return "UNKNOWN"
}

// state_from_snapshot combines the engine's epoch/validity semantics with the
// capture lifecycle. Order matters:
//
//   - device loss is the strongest statement; the last reading must never look
//     live;
//   - a snapshot that has never been published is "starting", not "idle";
//   - an adapter stall is an explicit idle state (the loopback endpoint emits
//     no callbacks while silent);
//   - with data flowing, `valid` is authoritative for the completed window;
//   - an invalid completed window with `overrun` is the boundary window after
//     a gap/overrun: data flows again but this window is not trustworthy.
state_from_snapshot :: proc(snapshot: transport.Measurement_Snapshot, source: Source_State) -> State {
	if source == .Device_Lost {
		return .Disconnected
	}
	if snapshot.generation == 0 && source == .Starting {
		return .Starting
	}
	if source == .Stalled {
		return .Idle
	}
	if snapshot.valid {
		return .Live
	}
	if snapshot.overrun {
		return .Invalid_Window
	}
	return .Idle
}

channel_from_snapshot :: proc(snapshot: transport.Measurement_Snapshot, index: int) -> Channel {
	peak_zone := zone_from_db(snapshot.window_peak_db[index])
	rms_zone := zone_from_db(snapshot.rms_db[index])
	hold_zone := zone_from_db(snapshot.peak_hold_db[index])
	return Channel{
		peak_percent=percent_from_db(snapshot.window_peak_db[index]),
		rms_percent=percent_from_db(snapshot.rms_db[index]),
		hold_percent=percent_from_db(snapshot.peak_hold_db[index]),
		session_max_percent=percent_from_db(snapshot.session_max_db[index]),
		peak_db=snapshot.window_peak_db[index],
		rms_db=snapshot.rms_db[index],
		hold_db=snapshot.peak_hold_db[index],
		session_max_db=snapshot.session_max_db[index],
		peak_zone=peak_zone,
		rms_zone=rms_zone,
		hold_zone=hold_zone,
		peak_color=zone_color(peak_zone),
		rms_color=zone_color(rms_zone),
		hold_color=zone_color(hold_zone),
	}
}

// snapshot_to_visual is pure: the same snapshot and source state always
// produce the same visual state. It reads only presentation fields.
snapshot_to_visual :: proc(
	snapshot: transport.Measurement_Snapshot,
	source: Source_State,
) -> Visual {
	state := state_from_snapshot(snapshot, source)
	return Visual{
		state=state,
		epoch=snapshot.epoch,
		generation=snapshot.generation,
		sample_rate=snapshot.sample_rate,
		channels={channel_from_snapshot(snapshot, 0), channel_from_snapshot(snapshot, 1)},
		state_color=state_color(state),
	}
}

@(private = "file")
near :: proc(a, b, epsilon: f32) -> bool {
	return math.abs(a-b) <= epsilon
}

// visual_close compares the parts a frame would show. `generation` is
// deliberately excluded: a new generation with unchanged levels is exactly
// the case the epsilon exists to coalesce.
visual_close :: proc(a, b: Visual) -> bool {
	if a.state != b.state || a.epoch != b.epoch || a.sample_rate != b.sample_rate {
		return false
	}
	for index in 0 ..< 2 {
		left := a.channels[index]
		right := b.channels[index]
		if !near(left.peak_percent, right.peak_percent, EPSILON_PERCENT) ||
		   !near(left.rms_percent, right.rms_percent, EPSILON_PERCENT) ||
		   !near(left.hold_percent, right.hold_percent, EPSILON_PERCENT) ||
		   !near(left.session_max_percent, right.session_max_percent, EPSILON_PERCENT) {
			return false
		}
		if left.peak_zone != right.peak_zone || left.rms_zone != right.rms_zone ||
		   left.hold_zone != right.hold_zone {
			return false
		}
	}
	return true
}

// observe implements presentation-on-demand. A hidden window never requests a
// frame and does not advance the presented state, so restoring it must ask for
// one frame with force=true: the retained surface may be stale or the desktop
// may have discarded it while the window could not be presented. A forced
// observation is counted as a presented change.
observe :: proc(
	tracker: ^Tracker,
	snapshot: transport.Measurement_Snapshot,
	source: Source_State,
	renderable: bool,
	force := false,
) -> Observation {
	tracker.counters.observations += 1
	visual := snapshot_to_visual(snapshot, source)
	if !renderable {
		tracker.counters.skipped_hidden += 1
		return Observation{visual=visual, render=false, reason=.Hidden}
	}
	if !force && tracker.have_visual && visual_close(tracker.visual, visual) {
		tracker.counters.skipped_unchanged += 1
		return Observation{visual=visual, render=false, reason=.Unchanged}
	}
	tracker.visual = visual
	tracker.have_visual = true
	tracker.last_generation = snapshot.generation
	tracker.counters.presented_changes += 1
	return Observation{visual=visual, render=true, reason=.Changed}
}
