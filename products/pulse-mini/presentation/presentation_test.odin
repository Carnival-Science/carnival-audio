// Bounded tests for the seeded snapshot-to-visual mapping.
//
// These are deliberately exhaustive around the mapping's contract: display
// range, level zones, state selection from engine validity plus capture
// lifecycle, and the presentation-on-demand tracker. They prove the *mapping*
// only. They do not prove that shared-mode loopback produced any particular
// level; that remains the adapter self-loop evidence.

package presentation

import "core:math"
import "core:testing"

import "carnival:core/transport"

close :: proc(a, b: f32) -> bool {
	return math.abs(a-b) <= 0.0001
}

// snapshot_at builds a schema-2 snapshot whose per-channel dBFS values are the
// inputs. The amplitude fields are left at zero: the mapping consumes only the
// presentation dBFS fields, and that restriction is itself part of the test.
snapshot_at :: proc(
	generation: u64,
	epoch: u64,
	valid: bool,
	overrun: bool,
	peak_db, rms_db, hold_db, max_db: [2]f32,
) -> transport.Measurement_Snapshot {
	return transport.Measurement_Snapshot{
		generation=generation,
		schema_version=transport.SNAPSHOT_SCHEMA_VERSION,
		valid=valid,
		overrun=overrun,
		window_valid=valid,
		epoch=epoch,
		sample_rate=48000,
		channels=2,
		window_peak_db=peak_db,
		rms_db=rms_db,
		peak_hold_db=hold_db,
		session_max_db=max_db,
	}
}

@(test)
test_percent_maps_the_documented_display_range :: proc(t: ^testing.T) {
	cases := []struct {
		db:       f32,
		expected: f32,
	} {
		{-120, 0},
		{-60, 0},
		{-59.999, 0.001666},
		{-45, 25},
		{-30, 50},
		{-15, 75},
		{-6.0206, 89.9656},
		{0, 100},
		{6, 100},
	}
	for item in cases {
		got := percent_from_db(item.db)
		testing.expect(t, math.abs(got-item.expected) <= 0.01,
			"percent_from_db should map the -60..0 dBFS display range")
	}
	testing.expect_value(t, percent_from_db(math.nan_f32()), f32(0))
	testing.expect_value(t, percent_from_db(math.inf_f32(1)), f32(0))
}

@(test)
test_zones_cover_every_band_and_silence :: proc(t: ^testing.T) {
	testing.expect_value(t, zone_from_db(-120), Level_Zone.Silent)
	testing.expect_value(t, zone_from_db(-60), Level_Zone.Silent)
	testing.expect_value(t, zone_from_db(-59.9), Level_Zone.Safe)
	testing.expect_value(t, zone_from_db(-13), Level_Zone.Safe)
	testing.expect_value(t, zone_from_db(-12), Level_Zone.Warn)
	testing.expect_value(t, zone_from_db(-3.0001), Level_Zone.Warn)
	testing.expect_value(t, zone_from_db(-3), Level_Zone.Hot)
	testing.expect_value(t, zone_from_db(0), Level_Zone.Hot)
	testing.expect_value(t, zone_from_db(math.nan_f32()), Level_Zone.Silent)
}

@(test)
test_state_prefers_capture_lifecycle_then_engine_validity :: proc(t: ^testing.T) {
	live := snapshot_at(4, 2, true, false, {0, 0}, {0, 0}, {0, 0}, {0, 0})
	invalid := snapshot_at(5, 3, false, true, {0, 0}, {0, 0}, {0, 0}, {0, 0})
	quiet := snapshot_at(6, 3, false, false, {0, 0}, {0, 0}, {0, 0}, {0, 0})
	never := transport.Measurement_Snapshot{}

	testing.expect_value(t, state_from_snapshot(never, .Starting), State.Starting)
	testing.expect_value(t, state_from_snapshot(live, .Live), State.Live)
	testing.expect_value(t, state_from_snapshot(invalid, .Live), State.Invalid_Window)
	testing.expect_value(t, state_from_snapshot(quiet, .Live), State.Idle)
	testing.expect_value(t, state_from_snapshot(quiet, .Stalled), State.Idle)
	testing.expect_value(t, state_from_snapshot(live, .Stalled), State.Idle)
	testing.expect_value(t, state_from_snapshot(live, .Device_Lost), State.Disconnected)
	testing.expect_value(t, state_from_snapshot(invalid, .Device_Lost), State.Disconnected)
	testing.expect_value(t, state_from_snapshot(never, .Device_Lost), State.Disconnected)
	// A non-zero generation cannot be "starting" just because the adapter has
	// not flipped its lifecycle flag yet.
	testing.expect_value(t, state_from_snapshot(live, .Starting), State.Live)
}

@(test)
test_channel_visual_uses_published_db_values :: proc(t: ^testing.T) {
	snapshot := snapshot_at(7, 2, true, false,
		{-6.0206, -20}, {-9.0309, -26}, {-1, -58}, {0, -12})
	visual := snapshot_to_visual(snapshot, .Live)

	testing.expect_value(t, visual.state, State.Live)
	testing.expect_value(t, visual.epoch, u64(2))
	testing.expect_value(t, visual.generation, u64(7))
	testing.expect_value(t, visual.state_color, COLOR_STATE_LIVE)

	left := visual.channels[0]
	testing.expect(t, close(left.peak_percent, 89.9656), "peak bar follows window_peak_db")
	testing.expect(t, close(left.rms_percent, 84.9485), "rms bar follows rms_db")
	testing.expect(t, close(left.hold_percent, 98.3333), "hold bar follows peak_hold_db")
	testing.expect(t, close(left.session_max_percent, 100), "max bar follows session_max_db")
	testing.expect_value(t, left.peak_zone, Level_Zone.Warn)
	testing.expect_value(t, left.rms_zone, Level_Zone.Warn)
	testing.expect_value(t, left.hold_zone, Level_Zone.Hot)
	testing.expect_value(t, left.hold_color, COLOR_HOT)

	right := visual.channels[1]
	testing.expect_value(t, right.peak_zone, Level_Zone.Safe)
	testing.expect_value(t, right.rms_zone, Level_Zone.Safe)
	testing.expect_value(t, right.hold_zone, Level_Zone.Safe)
	testing.expect_value(t, right.hold_color, COLOR_SAFE)
	testing.expect_value(t, right.session_max_percent, f32(80))
}

@(test)
test_state_labels_are_distinct :: proc(t: ^testing.T) {
	states := []State{.Starting, .Live, .Idle, .Disconnected, .Invalid_Window}
	seen := make(map[string]bool)
	defer delete(seen)
	for state in states {
		label := state_label(state)
		testing.expect(t, len(label) > 0, "every state needs a label")
		testing.expect(t, !seen[label], "state labels must be visually distinct")
		seen[label] = true
		testing.expect(t, state_color(state) != 0, "every state needs a badge color")
	}
}

@(test)
test_tracker_coalesces_changes_inside_epsilon :: proc(t: ^testing.T) {
	tracker := Tracker{}
	base := snapshot_at(1, 1, true, false, {-10, -10}, {-20, -20}, {-8, -8}, {-6, -6})
	first := observe(&tracker, base, .Live, true)
	testing.expect(t, first.render)
	testing.expect_value(t, first.reason, Skip_Reason.Changed)
	testing.expect_value(t, tracker.counters.presented_changes, u64(1))

	// A new engine generation with the same displayed levels is exactly what
	// presentation-on-demand must coalesce.
	same := snapshot_at(2, 1, true, false, {-10, -10}, {-20, -20}, {-8, -8}, {-6, -6})
	second := observe(&tracker, same, .Live, true)
	testing.expect(t, !second.render)
	testing.expect_value(t, second.reason, Skip_Reason.Unchanged)
	testing.expect_value(t, tracker.counters.skipped_unchanged, u64(1))

	// 0.1 dB is 0.17% of the display range: below the 0.25% epsilon.
	sub_epsilon := snapshot_at(3, 1, true, false, {-9.9, -10}, {-20, -20}, {-8, -8}, {-6, -6})
	third := observe(&tracker, sub_epsilon, .Live, true)
	testing.expect(t, !third.render, "sub-epsilon level changes should not rebuild")
	testing.expect_value(t, tracker.counters.skipped_unchanged, u64(2))

	// 0.2 dB is 0.33%: above it.
	above_epsilon := snapshot_at(4, 1, true, false, {-9.8, -10}, {-20, -20}, {-8, -8}, {-6, -6})
	fourth := observe(&tracker, above_epsilon, .Live, true)
	testing.expect(t, fourth.render, "a visible level change should rebuild")
	testing.expect_value(t, tracker.counters.presented_changes, u64(2))
	testing.expect_value(t, tracker.counters.observations, u64(4))
}

@(test)
test_tracker_elides_hidden_work_and_catches_up_on_restore :: proc(t: ^testing.T) {
	tracker := Tracker{}
	visible := snapshot_at(1, 1, true, false, {-12, -12}, {-18, -18}, {-10, -10}, {-8, -8})
	testing.expect(t, observe(&tracker, visible, .Live, true).render)

	// While hidden, the engine keeps publishing (generation advances) and the
	// capture side keeps running. The tracker consumes observations but never
	// requests a frame, and does not advance its presented generation.
	published: u64 = 0
	for step in 0 ..< 100 {
		published += 1
		generation := u64(2 + step)
		db := f32(-40 + step % 30)
		hidden_snapshot := snapshot_at(generation, 1, true, false,
			{db, db}, {db-6, db-6}, {db-2, db-2}, {db, db})
		observation := observe(&tracker, hidden_snapshot, .Live, false)
		testing.expect(t, !observation.render)
		testing.expect_value(t, observation.reason, Skip_Reason.Hidden)
	}
	testing.expect_value(t, published, u64(100))
	testing.expect_value(t, tracker.counters.skipped_hidden, u64(100))
	testing.expect_value(t, tracker.counters.presented_changes, u64(1))
	testing.expect_value(t, tracker.counters.observations, u64(101))

	// On restore the host asks for one frame explicitly (force=true), so the
	// discarded/stale retained surface is described from the latest snapshot.
	restored := snapshot_at(102, 1, true, false, {-3, -3}, {-9, -9}, {-1, -1}, {-3, -3})
	after := observe(&tracker, restored, .Live, true, force=true)
	testing.expect(t, after.render)
	testing.expect_value(t, tracker.counters.presented_changes, u64(2))
}

@(test)
test_tracker_renders_once_for_a_steady_hidden_to_restore_cycle :: proc(t: ^testing.T) {
	tracker := Tracker{}
	steady := snapshot_at(1, 1, true, false, {-10, -10}, {-20, -20}, {-8, -8}, {-6, -6})
	testing.expect(t, observe(&tracker, steady, .Live, true).render)
	for _ in 0 ..< 50 {
		_ = observe(&tracker, steady, .Live, false)
	}
	testing.expect(t, observe(&tracker, steady, .Live, true, force=true).render,
		"restoring must invalidate once even when levels did not change, because the hidden period did not update presented state")
	testing.expect(t, !observe(&tracker, steady, .Live, true).render,
		"the following unchanged observation should be idle again")
}
