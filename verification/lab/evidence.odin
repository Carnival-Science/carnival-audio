// Machine-readable evidence written by one worker run.
//
// One JSON document per (specimen, scenario) invocation. The runner aggregates
// these into the census; the raw documents and WAV artifacts are preserved,
// including for failing specimens, because the failure is the finding.
package verification_lab

import "core:encoding/json"
import "core:fmt"
import "core:os"

EVIDENCE_SCHEMA :: "carnival.verification.evidence/1"

Probe_Status :: enum {
	Pass,
	Fail,
	Skip,
}

probe_status_name :: proc(status: Probe_Status) -> string {
	switch status {
	case .Pass: return "pass"
	case .Fail: return "fail"
	case .Skip: return "skip"
	}
	return "skip"
}

Metric :: struct {
	name:  string `json:"name"`,
	value: string `json:"value"`,
	unit:  string `json:"unit,omitempty"`,
}

Probe_Result :: struct {
	id:            string `json:"id"`,
	class:         string `json:"class"`,
	status:        string `json:"status"`,
	applicability: string `json:"applicability"`,
	summary:       string `json:"summary"`,
	metrics:       []Metric `json:"metrics,omitempty"`,
	details:       []string `json:"details,omitempty"`,
}

Artifact :: struct {
	kind:        string `json:"kind"`,
	path:        string `json:"path"`,
	sha256:      string `json:"sha256"`,
	bytes:       int `json:"bytes"`,
	frames:      int `json:"frames,omitempty"`,
	channels:    int `json:"channels,omitempty"`,
	sample_rate: u32 `json:"sample_rate,omitempty"`,
}

Scenario_Echo :: struct {
	name:        string `json:"name"`,
	description: string `json:"description,omitempty"`,
	sha256:      string `json:"sha256"`,
	plugin_id:   string `json:"plugin_id"`,
	class:       string `json:"class"`,
}

Specimen_Echo :: struct {
	path:          string `json:"path"`,
	sha256:        string `json:"sha256"`,
	descriptor_id: string `json:"descriptor_id"`,
	name:          string `json:"name"`,
	vendor:        string `json:"vendor"`,
	version:       string `json:"version"`,
	has_telemetry: bool `json:"has_telemetry"`,
}

Exit_Info :: struct {
	code:    int `json:"code"`,
	meaning: string `json:"meaning"`,
}

Evidence :: struct {
	schema:        string `json:"schema"`,
	lab_revision:  string `json:"lab_revision"`,
	abi:           string `json:"abi"`,
	scenario:      Scenario_Echo `json:"scenario"`,
	specimen:      Specimen_Echo `json:"specimen"`,
	environment:   Fingerprint `json:"environment"`,
	probes:        []Probe_Result `json:"probes"`,
	artifacts:     []Artifact `json:"artifacts"`,
	hashes:        map[string]string `json:"hashes"`,
	exit:          Exit_Info `json:"exit"`,
}

evidence_status_count :: proc(evidence: ^Evidence, status: Probe_Status) -> int {
	count := 0
	for probe in evidence.probes {
		if probe.status == probe_status_name(status) {
			count += 1
		}
	}
	return count
}

evidence_has_failure :: proc(evidence: ^Evidence) -> bool {
	return evidence_status_count(evidence, .Fail) > 0
}

evidence_write :: proc(path: string, evidence: ^Evidence, allocator := context.allocator) -> bool {
	data, err := json.marshal(evidence^, json.Marshal_Options{
		pretty = true,
		use_spaces = true,
		spaces = 2,
		sort_maps_by_key = true,
	}, allocator)
	if err != nil {
		fmt.eprintfln("evidence: JSON marshal failed: %v", err)

		return false
	}
	defer delete(data, allocator)
	return os.write_entire_file(path, data) == nil
}

artifact_add :: proc(
	artifacts: ^[dynamic]Artifact,
	kind, path, digest: string,
	bytes, frames, channels: int,
	sample_rate: u32,
) {
	append(artifacts, Artifact{
		kind = kind,
		path = path,
		sha256 = digest,
		bytes = bytes,
		frames = frames,
		channels = channels,
		sample_rate = sample_rate,
	})
}
