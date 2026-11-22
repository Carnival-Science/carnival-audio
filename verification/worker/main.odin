// Verification worker: one scenario, one experiment, one JSON evidence file.
//
// A fresh process per run is the crash-isolation and fresh-state boundary. The
// worker takes a scenario file and an output directory, loads the specimen
// shared library, runs the requested probes and writes machine-readable
// evidence plus WAV/CSV artifacts. It never posts to or queries a remote
// service; evidence is local.
//
// Exit codes:
//   0  every probe passed (or skipped as declared by the scenario)
//   1  at least one probe failed (a specimen finding; expected for the
//      deliberately defective reference processors)
//   2  laboratory/infrastructure failure (missing plugin, scenario, pipeline)
package verification_worker

import "core:fmt"
import "core:os"

import host "carnival:verification/host"
import lab "carnival:verification/lab"

Arguments :: struct {
	scenario_path: string,
	out_dir:       string,
	plugin_path:   string,
	odin_build:    string,
	cpu:           string,
	git_commit:    string,
}

parse_arguments :: proc() -> (Arguments, bool) {
	args: Arguments
	arguments := os.args
	index := 1
	for index < len(arguments) {
		switch arguments[index] {
		case "--scenario":
			index += 1
			if index >= len(arguments) { return args, false }
			args.scenario_path = arguments[index]
		case "--out":
			index += 1
			if index >= len(arguments) { return args, false }
			args.out_dir = arguments[index]
		case "--plugin":
			index += 1
			if index >= len(arguments) { return args, false }
			args.plugin_path = arguments[index]
		case "--odin-build":
			index += 1
			if index >= len(arguments) { return args, false }
			args.odin_build = arguments[index]
		case "--cpu":
			index += 1
			if index >= len(arguments) { return args, false }
			args.cpu = arguments[index]
		case "--git-commit":
			index += 1
			if index >= len(arguments) { return args, false }
			args.git_commit = arguments[index]
		case "-h", "--help":
			return args, false
		}
		index += 1
	}
	return args, args.scenario_path != "" && args.out_dir != ""
}

main :: proc() {
	args, parsed := parse_arguments()
	if !parsed {
		fmt.eprintln("usage: verify-worker --scenario <file> --out <dir> [--plugin <path>] [--odin-build <text>] [--cpu <text>] [--git-commit <hash>]")
		os.exit(2)
	}
	code := run(args)
	os.exit(code)
}

run :: proc(args: Arguments) -> int {
	load, loaded := lab.scenario_load(args.scenario_path)
	if !loaded {
		fmt.eprintfln("worker: cannot read scenario %s", args.scenario_path)
		return 2
	}
	scenario := &load.scenario
	if args.plugin_path != "" {
		scenario.specimen.path = args.plugin_path
	}
	if scenario.specimen.path == "" {
		fmt.eprintln("worker: scenario does not name a specimen path and --plugin was not given")
		return 2
	}
	if os.make_directory_all(args.out_dir) != nil {
		fmt.eprintfln("worker: cannot create output directory %s", args.out_dir)
		return 2
	}
	plugin_data, plugin_error := os.read_entire_file(scenario.specimen.path, context.allocator)
	if plugin_error != nil {
		fmt.eprintfln("worker: cannot read plugin %s", scenario.specimen.path)
		return 2
	}
	plugin_hash := lab.sha256_hex(plugin_data)
	delete(plugin_data)

	input := lab.generate_input(
		scenario.input.frames,
		f64(scenario.sample_rate),
		lab.input_kind_from_string(scenario.input.kind),
		scenario.input.frequency_hz,
		scenario.input.amplitude,
		scenario.input.channel_scale,
		scenario.input.seed,
		scenario.input.impulse_frame,
		scenario.input.dc_value,
	)
	defer lab.destroy_input(input)

	environment := lab.observe_fingerprint(args.odin_build)
	environment.cpu = args.cpu
	environment.git_commit = args.git_commit
	evidence := lab.Evidence{
		schema = lab.EVIDENCE_SCHEMA,
		lab_revision = lab.LAB_REVISION,
		abi = lab.ABI_VERSION,
		scenario = lab.Scenario_Echo{
			name = scenario.name,
			description = scenario.description,
			sha256 = load.hash,
			plugin_id = scenario.specimen.id,
			class = scenario.specimen.class,
		},
		specimen = lab.Specimen_Echo{
			path = scenario.specimen.path,
			sha256 = plugin_hash,
		},
		environment = environment,
		hashes = make(map[string]string),
	}

	// Input WAV is an artifact even when the run fails later.
	input_artifacts: [dynamic]lab.Artifact
	add_input_artifact(scenario, input, args.out_dir, &input_artifacts)
	for artifact in input_artifacts {
		evidence.hashes["input_wav"] = artifact.sha256
	}

	library, opened := lab_open(scenario)
	if !opened {
		evidence.probes = make([]lab.Probe_Result, 1)
		evidence.probes[0] = lab.Probe_Result{
			id = "lab",
			class = "laboratory",
			status = "fail",
			applicability = "Infrastructure precondition",
			summary = fmt.aprintf("could not load CLAP library %s", scenario.specimen.path),
		}
		evidence.exit = lab.Exit_Info{code = 2, meaning = "laboratory_failure"}
		lab.evidence_write(fmt.aprintf("%s/evidence.json", args.out_dir), &evidence)
		fmt.eprintfln("worker: LAB FAILURE: cannot load %s", scenario.specimen.path)
		return 2
	}
	defer {
		host.library_close(library)
		free(library)
	}

	// Descriptor and telemetry availability are recorded before probing.
	factory := host.library_factory(library)
	if factory != nil && factory.get_plugin_count(factory) > 0 {
		descriptor := host.library_descriptor(library, 0)
		if descriptor != nil {
			evidence.specimen.descriptor_id = string(descriptor.id)
			evidence.specimen.name = string(descriptor.name)
			evidence.specimen.vendor = string(descriptor.vendor)
			evidence.specimen.version = string(descriptor.version)
		}
	}
	if probe_instance, created := host.instance_create(
		library,
		scenario.specimen.id,
		scenario.max_block_frames,
	); created {
		if host.instance_init(probe_instance) {
			evidence.specimen.has_telemetry = host.instance_has_telemetry(probe_instance)
		}
		host.instance_destroy(probe_instance)
	} else {
		evidence.probes = make([]lab.Probe_Result, 1)
		evidence.probes[0] = lab.Probe_Result{
			id = "lab",
			class = "laboratory",
			status = "fail",
			applicability = "Infrastructure precondition",
			summary = fmt.aprintf(
				"factory could not create plugin %s from %s",
				scenario.specimen.id,
				scenario.specimen.path,
			),
		}
		evidence.exit = lab.Exit_Info{code = 2, meaning = "laboratory_failure"}
		lab.evidence_write(fmt.aprintf("%s/evidence.json", args.out_dir), &evidence)
		fmt.eprintfln("worker: LAB FAILURE: cannot create plugin %s", scenario.specimen.id)
		return 2
	}

	ctx := lab.Run_Context{
		scenario = scenario,
		library = library,
		out_dir = args.out_dir,
		scenario_hash = load.hash,
		plugin_hash = plugin_hash,
		input = input,
	}
	lab.write_canonical_artifacts(&ctx)
	lab.run_probes(&ctx)

	evidence.probes = ctx.results[:]
	all_artifacts := make([]lab.Artifact, len(input_artifacts) + len(ctx.artifacts))
	copy(all_artifacts[:len(input_artifacts)], input_artifacts[:])
	copy(all_artifacts[len(input_artifacts):], ctx.artifacts[:])
	evidence.artifacts = all_artifacts
	evidence.hashes["scenario"] = load.hash
	evidence.hashes["plugin"] = plugin_hash
	for artifact in evidence.artifacts {
		if artifact.kind == "output" {
			evidence.hashes["output_wav"] = artifact.sha256
		}
	}
	evidence.hashes["environment_fingerprint"] = lab.sha256_hex_string(
		fmt.aprintf(
			"%s|%s|%s|%s|%s",
			environment.platform,
			environment.arch,
			environment.denormals,
			environment.contraction,
			environment.odin_build,
		),
	)
	failures := lab.evidence_has_failure(&evidence)
	code := failures ? 1 : 0
	evidence.exit = lab.Exit_Info{
		code = code,
		meaning = failures ? "specimen_probe_failure" : "all_probes_passed",
	}
	lab.evidence_write(fmt.aprintf("%s/evidence.json", args.out_dir), &evidence)

	for probe in evidence.probes {
		fmt.printfln(
			"probe %-18s %-4s %-42s %s",
			probe.id,
			probe.status,
			probe.class,
			probe.summary,
		)
	}
	fmt.printfln(
		"RESULT specimen=%s scenario=%s pass=%d fail=%d skip=%d exit=%d",
		scenario.specimen.id,
		scenario.name,
		lab.evidence_status_count(&evidence, .Pass),
		lab.evidence_status_count(&evidence, .Fail),
		lab.evidence_status_count(&evidence, .Skip),
		code,
	)
	return code
}

lab_open :: proc(scenario: ^lab.Scenario) -> (^host.Library, bool) {
	library := new(host.Library)
	value, ok := host.library_open(scenario.specimen.path)
	if !ok {
		free(library)
		return nil, false
	}
	library^ = value
	return library, true
}

// add_input_artifact writes the generated input WAV and records its hash. It is
// a package procedure (not a closure) so failures before the library loads can
// still leave an artifact trail.
add_input_artifact :: proc(
	scenario: ^lab.Scenario,
	input: [][]f32,
	out_dir: string,
	artifacts: ^[dynamic]lab.Artifact,
) {
	filename := "input.wav"
	path := fmt.aprintf("%s/%s", out_dir, filename)
	if !lab.write_wav_f32(path, input, scenario.input.frames, scenario.sample_rate) {
		return
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return
	}
	digest := lab.sha256_hex(data, context.temp_allocator)
	lab.artifact_add(
		artifacts,
		"input",
		filename,
		digest,
		len(data),
		scenario.input.frames,
		2,
		scenario.sample_rate,
	)
}