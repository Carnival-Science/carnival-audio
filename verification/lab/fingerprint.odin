// Observed numeric-environment fingerprint.
//
// This is an observation, never a hermeticity claim. The worker records what
// the process can see: platform/arch, denormal behavior observed by ordinary
// arithmetic, and whether a value-changing multiply+add was contracted. The
// runner adds the CPU model, Odin version and repository revision, which are
// cheaper to obtain outside the process.
package verification_lab

import "core:fmt"
import "core:math"

Fingerprint :: struct {
	platform:      string `json:"platform"`,
	arch:          string `json:"arch"`,
	odin_build:    string `json:"odin_build"`,
	host_revision: string `json:"host_revision"`,
	denormals:     string `json:"denormals"`,
	denormal_probe: string `json:"denormal_probe"`,
	contraction:   string `json:"contraction"`,
	contraction_probe: string `json:"contraction_probe"`,
	cpu:           string `json:"cpu,omitempty"`,
	git_commit:    string `json:"git_commit,omitempty"`,
	note:          string `json:"note"`,
}

LAB_REVISION :: "m2.0"
ABI_VERSION :: "clap-1.2.10"

platform_name :: proc() -> string {
	when ODIN_OS == .Windows { return "windows" }
	when ODIN_OS == .Linux { return "linux" }
	when ODIN_OS == .Darwin { return "darwin" }
	return "other"
}

arch_name :: proc() -> string {
	when ODIN_ARCH == .amd64 { return "x86_64" }
	when ODIN_ARCH == .arm64 { return "aarch64" }
	return "other"
}

observe_fingerprint :: proc(odin_build: string) -> Fingerprint {
	result := Fingerprint{
		platform = platform_name(),
		arch = arch_name(),
		odin_build = odin_build,
		host_revision = LAB_REVISION,
		note = "observed, not hermetic: no claim of universal determinism or real-time safety",
	}

	// FTZ/DAZ observation through ordinary arithmetic on a runtime-derived
	// subnormal. math.pow is a library call, so the values are not folded at
	// compile time on the builds used here; that assumption is part of the
	// observation, not a guarantee.
	tiny := math.pow(10.0, -320.0)
	half := tiny * 0.5
	if tiny == 0 {
		result.denormals = "cannot_observe_subnormal_constant"
		result.denormal_probe = "tiny=0"
	} else if half == 0 {
		result.denormals = "flushed_or_below_range"
	} else {
		result.denormals = "preserved"
	}
	result.denormal_probe = fmt.aprintf("tiny=%g half=%g tiny_nonzero=%v half_nonzero=%v", tiny, half, tiny != 0, half != 0)

	// A fused multiply-add and a separately rounded multiply/add differ for this
	// case. A non-zero result is an observation of contraction, not proof of a
	// specific CPU instruction (the compiler may choose either).
	a := math.pow(1.0 + 4.440892098500626e-16, 1.0)
	b := 1.0 - 4.440892098500626e-16
	c := -1.0
	contracted := a * b + c
	if contracted != 0 {
		result.contraction = "contracted_observed"
	} else {
		result.contraction = "separately_rounded"
	}
	result.contraction_probe = fmt.aprintf("a*b+c=%g", contracted)
	return result
}
