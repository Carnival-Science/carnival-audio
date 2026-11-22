// Scenario file format for the verification laboratory.
//
// A scenario is deterministic: it names the specimen, the input signal, the
// block partitions, the parameter/transport schedule and the probe list. The
// worker writes the exact scenario file hash into evidence, so a run can be
// reproduced from the scenario plus the specimen binary.
//
// Unknown JSON fields are ignored by Odin's unmarshaller; missing fields take
// the defaults in `scenario_normalize`.
package verification_lab

import "core:encoding/json"
import "core:os"

SCENARIO_SCHEMA :: "carnival.verification.scenario/1"

Specimen_Spec :: struct {
	id:    string `json:"id"`,
	class: string `json:"class"`,
	path:  string `json:"path"`,
}

Input_Spec :: struct {
	kind:           string `json:"kind"`,
	frames:         int `json:"frames"`,
	frequency_hz:   f64 `json:"frequency_hz"`,
	amplitude:      f64 `json:"amplitude"`,
	channel_scale:  [2]f64 `json:"channel_scale"`,
	seed:           u64 `json:"seed"`,
	impulse_frame:  int `json:"impulse_frame"`,
	dc_value:       f64 `json:"dc_value"`,
}

Partition_Spec :: struct {
	name:          string `json:"name"`,
	block_sizes:   []u32 `json:"block_sizes"`,
	irregular_seed: u64 `json:"irregular_seed"`,
}

Param_Setting :: struct {
	id:    u32 `json:"id"`,
	value: f64 `json:"value"`,
}

Telemetry_Spec :: struct {
	enabled:       bool `json:"enabled"`,
	drain_per_block: bool `json:"drain_per_block"`,
	overflow:      bool `json:"overflow"`,
}

Measurement_Spec :: struct {
	enabled:         bool `json:"enabled"`,
	window_frames:   int `json:"window_frames"`,
	hold_frames:     int `json:"hold_frames"`,
	hold_decay:      bool `json:"hold_decay"`,
	schema_version:  u32 `json:"schema_version"`,
}

Event_Spec :: struct {
	frame:    u64 `json:"frame"`,
	param_id: u32 `json:"param_id"`,
	value:    f64 `json:"value"`,
}

Automation_Spec :: struct {
	enabled:    bool `json:"enabled"`,
	events:     []Event_Spec `json:"events"`,
	partitions: []string `json:"partitions"`,
}

Fixture_Spec :: struct {
	name:          string `json:"name"`,
	schema:        u32 `json:"schema"`,
	hex:           string `json:"hex"`,
	expect_params: []Param_Setting `json:"expect_params"`,
	expect_capture: bool `json:"expect_capture"`,
	note:          string `json:"note"`,
}

State_Spec :: struct {
	round_trip: bool `json:"round_trip"`,
	migration:  bool `json:"migration"`,
	fixtures:   []Fixture_Spec `json:"fixtures"`,
}

Tail_Spec :: struct {
	silence_frames: int `json:"silence_frames"`,
	threshold_db:   f64 `json:"threshold_db"`,
}

Perturbation_Spec :: struct {
	delta_frame: int `json:"delta_frame"`,
	delta:       f64 `json:"delta"`,
}

Gap_Spec :: struct {
	start_frame: int `json:"start_frame"`,
	frames:      int `json:"frames"`,
}

Isolation_Spec :: struct {
	enabled:    bool `json:"enabled"`,
	alt_params: []Param_Setting `json:"alt_params"`,
}

Transport_Spec :: struct {
	enabled:          bool `json:"enabled"`,
	playing:          bool `json:"playing"`,
	tempo:            f64 `json:"tempo"`,
	position_seconds: f64 `json:"position_seconds"`,
}

Scenario :: struct {
	schema:           string `json:"schema"`,
	name:             string `json:"name"`,
	description:      string `json:"description"`,
	specimen:         Specimen_Spec `json:"specimen"`,
	sample_rate:      u32 `json:"sample_rate"`,
	max_block_frames: u32 `json:"max_block_frames"`,
	input:            Input_Spec `json:"input"`,
	params:           []Param_Setting `json:"params"`,
	partitions:       []Partition_Spec `json:"partitions"`,
	telemetry:        Telemetry_Spec `json:"telemetry"`,
	measurement:      Measurement_Spec `json:"measurement"`,
	automation:       Automation_Spec `json:"automation"`,
	state:            State_Spec `json:"state"`,
	tail:             Tail_Spec `json:"tail"`,
	perturbation:     Perturbation_Spec `json:"perturbation"`,
	gaps:             []Gap_Spec `json:"gaps"`,
	isolation:        Isolation_Spec `json:"isolation"`,
	transport:        Transport_Spec `json:"transport"`,
	probes:           []string `json:"probes"`,
}

scenario_normalize :: proc(scenario: ^Scenario, allocator := context.allocator) {
	if scenario.sample_rate == 0 {
		scenario.sample_rate = 48000
	}
	if scenario.input.frames <= 0 {
		scenario.input.frames = 16384
	}
	if scenario.input.kind == "" {
		scenario.input.kind = "sine"
	}
	if scenario.input.amplitude == 0 {
		scenario.input.amplitude = 0.5
	}
	if scenario.input.frequency_hz == 0 {
		scenario.input.frequency_hz = 997
	}
	if scenario.input.channel_scale[0] == 0 && scenario.input.channel_scale[1] == 0 {
		scenario.input.channel_scale = {1, 1}
	}
	if scenario.max_block_frames == 0 {
		scenario.max_block_frames = 1024
		for partition in scenario.partitions {
			for size in partition.block_sizes {
				if int(size) > int(scenario.max_block_frames) {
					scenario.max_block_frames = size
				}
			}
		}
	}
	if len(scenario.partitions) == 0 {
		scenario.partitions = make([]Partition_Spec, 1, allocator)
		scenario.partitions[0] = Partition_Spec{name = "512"}
		scenario.partitions[0].block_sizes = make([]u32, 1, allocator)
		scenario.partitions[0].block_sizes[0] = 512
	}
	if scenario.measurement.window_frames <= 0 {
		scenario.measurement.window_frames = 512
	}
	if scenario.measurement.hold_frames <= 0 {
		scenario.measurement.hold_frames = 96000
	}
	if scenario.measurement.schema_version == 0 {
		scenario.measurement.schema_version = 1
	}
	if scenario.tail.silence_frames <= 0 {
		scenario.tail.silence_frames = 24000
	}
	if scenario.tail.threshold_db == 0 {
		scenario.tail.threshold_db = -90
	}
	if scenario.perturbation.delta == 0 {
		scenario.perturbation.delta = 0.25
	}
	if scenario.transport.tempo <= 0 {
		scenario.transport.tempo = 120
	}
	if len(scenario.automation.partitions) == 0 {
		scenario.automation.partitions = make([]string, len(scenario.partitions), allocator)
		for partition, index in scenario.partitions {
			scenario.automation.partitions[index] = partition.name
		}
	}
}

scenario_has_probe :: proc(scenario: ^Scenario, id: string) -> bool {
	for probe in scenario.probes {
		if probe == id {
			return true
		}
	}
	return false
}

Load_Result :: struct {
	scenario: Scenario,
	bytes:    []u8,
	hash:     string,
}

scenario_load :: proc(path: string, allocator := context.allocator) -> (Load_Result, bool) {
	data, err := os.read_entire_file(path, allocator)
	if err != nil {
		return {}, false
	}
	scenario: Scenario
	if unmarshal_error := json.unmarshal(data, &scenario, allocator = allocator); unmarshal_error != nil {
		delete(data, allocator)
		return {}, false
	}
	scenario_normalize(&scenario, allocator)
	return Load_Result{
		scenario = scenario,
		bytes = data,
		hash = sha256_hex(data, allocator),
	}, true
}

// partition_blocks expands a partition to absolute block sizes covering frames.
// An explicit cycle is repeated; otherwise the irregular seed drives a
// deterministic 64..1024 schedule.
partition_blocks :: proc(spec: Partition_Spec, frames: int, allocator := context.allocator) -> []int {
	result := make([dynamic]int, 0, 4096, allocator)
	if len(spec.block_sizes) > 0 {
		index := 0
		for total := 0; total < frames; {
			size := int(spec.block_sizes[index % len(spec.block_sizes)])
			if size <= 0 {
				size = 512
			}
			size = min(size, frames - total)
			append(&result, size)
			total += size
			index += 1
		}
		return result[:]
	}
	seed := spec.irregular_seed
	if seed == 0 {
		seed = 0x5EED_5EED
	}
	for total := 0; total < frames; {
		units := int(seed & 0xF) // 1..16 units of 64 frames
		seed = prng_next(&seed)
		size := (units + 1) * 64
		if size > 1024 {
			size = 1024
		}
		size = min(size, frames - total)
		append(&result, size)
		total += size
	}
	return result[:]
}

hex_decode :: proc(text: string, allocator := context.allocator) -> ([]u8, bool) {
	if len(text) % 2 != 0 {
		return nil, false
	}
	result := make([]u8, len(text) / 2, allocator)
	for index in 0 ..< len(result) {
		high, high_ok := hex_digit(text[index * 2])
		low, low_ok := hex_digit(text[index * 2 + 1])
		if !high_ok || !low_ok {
			delete(result, allocator)
			return nil, false
		}
		result[index] = high << 4 | low
	}
	return result, true
}

hex_digit :: proc(value: u8) -> (u8, bool) {
	switch value {
	case '0' ..= '9': return value - '0', true
	case 'a' ..= 'f': return value - 'a' + 10, true
	case 'A' ..= 'F': return value - 'A' + 10, true
	}
	return 0, false
}
