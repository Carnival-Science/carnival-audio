// Probe dispatch for one scenario run.
package verification_lab

run_probes :: proc(ctx: ^Run_Context) {
	for id in ctx.scenario.probes {
		builder: Probe_Builder
		switch id {
		case "measurement":      builder = probe_measurement(ctx)
		case "spectrum":         builder = probe_spectrum(ctx)
		case "nonfinite":        builder = probe_nonfinite(ctx)
		case "repeatability":    builder = probe_repeatability(ctx)
		case "partition":        builder = probe_partition(ctx)
		case "automation":       builder = probe_automation(ctx)
		case "state":            builder = probe_state(ctx)
		case "checkpoint":       builder = probe_checkpoint(ctx)
		case "isolation":        builder = probe_isolation(ctx)
		case "reset":            builder = probe_reset(ctx)
		case "tail":             builder = probe_tail(ctx)
		case "perturbation":     builder = probe_perturbation(ctx)
		case "capture_toggle":   builder = probe_capture_toggle(ctx)
		case "capture_overflow": builder = probe_capture_overflow(ctx)
		case "gap":              builder = probe_gap(ctx)
		case:
			builder = probe_start(id, "unknown", "No probe implementation exists for this id.")
			builder.status = .Skip
			builder.summary = "unknown probe id"
		}
		probe_finish(ctx, &builder)
	}
}
