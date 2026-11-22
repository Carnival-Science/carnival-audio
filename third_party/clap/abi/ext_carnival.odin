// DRAFT private Carnival telemetry extension — experimental, not a CLAP
// standard proposal.
//
// This extension lets an independent host (the verification laboratory) inspect
// the canonical measurement records that a Carnival plugin produces, through
// the real plugin binary and the normal CLAP `plugin.get_extension` mechanism.
// It is deliberately **private and draft**:
//
//   - it is not submitted to the CLAP project and is not a compatibility
//     promise to other vendors;
//   - the extension id, UUIDs, vtable order and record schema may change in a
//     later draft revision, in which case the extension id gains a new /N
//     suffix rather than silently changing meaning;
//   - hosts must treat `schema_version` (and the matching field in every
//     record) as the authority for the record layout.
//
// Thread rule: every function in this vtable must be called from the host's
// main thread (CLAP's normal extension-call rule), never from the audio
// thread. `capture_drain` may run while `process` is active, but the sink
// callback executes synchronously on the caller's thread; it must not call
// back into the plugin or retain the record pointer. See
// `third_party/clap/draft/carnival-telemetry-capture.h` and
// `docs/clap-plugin.md` for the same rules in prose and in C.
//
// Why the record declaration lives here: the telemetry wire format is the ABI
// boundary between the plugin and an independent host, so it is declared once
// as ABI surface. `products/pulse` aliases this type as its canonical
// `Measurement_Record`; verification may import the same declaration without
// importing any plugin implementation. This package still contains no
// analysis, DSP or metering code.
package clap

// Stable draft extension id. Version suffix is part of the identifier: an
// incompatible draft revision gets a new id, never a redefinition.
CARNIVAL_EXT_TELEMETRY_CAPTURE_DRAFT :: "com.carnival-science.telemetry-capture.draft/1"

// Frozen draft identifiers. These are fixed values generated for this draft and
// are not random at runtime. They identify the extension and its measurement
// schema in evidence records and host logs; they are not CLAP protocol fields.
CARNIVAL_TELEMETRY_DRAFT_UUID :: [16]u8{
	0x33, 0xC1, 0x8B, 0x91, 0xBC, 0x23, 0x42, 0x90,
	0x86, 0xA8, 0x2D, 0x40, 0x35, 0x31, 0x6E, 0xCC,
}
CARNIVAL_MEASUREMENT_SCHEMA_UUID :: [16]u8{
	0xFD, 0xEC, 0xFE, 0x25, 0x9B, 0x08, 0x41, 0x63,
	0xAD, 0xE3, 0xBA, 0xF7, 0xBC, 0xC2, 0xED, 0xAB,
}

// CARNIVAL_MEASUREMENT_SCHEMA_VERSION is reported by `schema_version` and is
// repeated in every record. Draft schema 1 (UUID above) is the M1/M2-prep
// record shape: one record per complete sample-clock-aligned RMS window, with
// separate audio-domain and capture-domain validity.
CARNIVAL_MEASUREMENT_SCHEMA_VERSION :: u32(1)

CARNIVAL_MEASUREMENT_CHANNELS :: 2

// Carnival_Measurement_Record is the canonical record wire layout. Field names
// and meanings match the Milestone 1 `Measurement_Record`; the draft adds
// `schema_version` and `capture_valid` (see docs/clap-plugin.md).
//
//   valid          audio-domain validity: false after lost audio samples
//   overrun        alias of "audio-domain invalid" for Milestone 1 consumers
//   capture_valid  capture-domain validity: false after lost measurement
//                  records; it never downgrades `valid`
Carnival_Measurement_Record :: struct {
	schema_version: u32,
	epoch:          u64,
	generation:     u64,
	start_frame:    i64,
	frames:         u32,
	channels:       u32,
	sample_rate:    u32,
	peak:           [CARNIVAL_MEASUREMENT_CHANNELS]f32,
	peak_frame:     [CARNIVAL_MEASUREMENT_CHANNELS]i64,
	rms:            [CARNIVAL_MEASUREMENT_CHANNELS]f32,
	hold:           [CARNIVAL_MEASUREMENT_CHANNELS]f32,
	valid:          bool,
	overrun:        bool,
	capture_valid:  bool,
}

// Carnival_Capture_Sink is the host-provided drain destination. `push` receives
// a pointer that is valid only for the duration of the call (it points into the
// plugin's bounded queue; it is not retained by the plugin). Returning false
// stops the drain without consuming that record.
Carnival_Capture_Sink :: struct {
	ctx:  rawptr,
	push: proc "c" (ctx: rawptr, record: ^Carnival_Measurement_Record) -> bool,
}

// Carnival_Telemetry_Capture is the plugin-implemented extension vtable.
//
//   set_enabled       Turn canonical capture on or off. Off by default. On
//                     success the queue is cleared and the dropped counter is
//                     reset to zero. Safe to call on the main thread; callers
//                     that care about an exact boundary should stop processing.
//   drain             Deliver up to `max_records` pending records, oldest first,
//                     through `sink`. `max_records == 0` drains everything
//                     pending. Returns the number delivered (<= max_records).
//   dropped           Records discarded because the queue was full since the
//                     most recent enable (capture episode). Zero when capture
//                     has never been enabled or is disabled.
//   valid             Capture-domain validity: true unless a record was dropped
//                     during the current capture episode.
//   schema_version    CARNIVAL_MEASUREMENT_SCHEMA_VERSION implemented by this
//                     plugin build.
Carnival_Telemetry_Capture :: struct {
	set_enabled:    proc "c" (plugin: ^Plugin, enabled: bool) -> bool,
	drain:          proc "c" (plugin: ^Plugin, sink: Carnival_Capture_Sink, max_records: u32) -> u32,
	dropped:        proc "c" (plugin: ^Plugin) -> u64,
	valid:          proc "c" (plugin: ^Plugin) -> bool,
	schema_version: proc "c" (plugin: ^Plugin) -> u32,
}

// ---------------------------------------------------------------------------
// Draft: Carnival processing-checkpoint extension
// ---------------------------------------------------------------------------
//
// A **separate, explicitly optional** capability from authoring state.
//
// Authoring state (`clap.state`) reopens a project with the same settings. It
// is mandatory and does not promise that processing continues from the same
// sample. A **processing checkpoint** resumes computation at an exact sample
// position: filter history, delay lines, envelope timers. A plugin may support
// it or not; a host must ask `supported()` before using save/load, and must
// never treat an omitted delay line in `clap.state` as a defect.
//
// The payload is plugin-owned bytes written through the normal CLAP stream
// interface. The draft frames nothing itself: the plugin writes its own magic,
// payload version and fields, and validates them on load. `schema_version`
// versions the capability contract, not the payload. The payload is expected
// to be small (a delay line is bounded by the plugin's own maximum delay);
// plugins that cannot snapshot cheaply declare `supported() == false`.
//
// Thread rule: main thread only, exactly like the telemetry draft.
CARNIVAL_EXT_PROCESSING_CHECKPOINT_DRAFT :: "com.carnival-science.processing-checkpoint.draft/1"

// Frozen draft UUID, generated once for this revision (not random at runtime).
CARNIVAL_CHECKPOINT_DRAFT_UUID :: [16]u8{
	0x5C, 0x2F, 0x0A, 0x7E, 0x4B, 0x1D, 0x4C, 0x8E,
	0x9F, 0x3A, 0x7D, 0x6E, 0x2B, 0x1C, 0x0A, 0x95,
}

// Capability contract revision. A record layout change inside a plugin payload
// is the plugin's own version field; this number changes only if the vtable
// semantics below change (in which case the extension id also gets a new /N).
CARNIVAL_CHECKPOINT_SCHEMA_VERSION :: u32(1)

// Carnival_Processing_Checkpoint is the plugin-implemented extension vtable.
//
//   supported        True only when the plugin can save and restore its
//                    processing state at an exact sample position. A host that
//                    gets false must not call save/load and must not infer a
//                    defect from the absence of a checkpoint.
//   save             Write the complete processing checkpoint to `stream`.
//                    Returns false on failure; the host then has no checkpoint.
//   load             Restore from `stream`. The plugin validates its own magic,
//                    version and length before committing. On false the plugin
//                    keeps its previous processing state (all-or-nothing).
//   schema_version   CARNIVAL_CHECKPOINT_SCHEMA_VERSION implemented by this
//                    build.
Carnival_Processing_Checkpoint :: struct {
	supported:      proc "c" (plugin: ^Plugin) -> bool,
	save:           proc "c" (plugin: ^Plugin, stream: ^OStream) -> bool,
	load:           proc "c" (plugin: ^Plugin, stream: ^IStream) -> bool,
	schema_version: proc "c" (plugin: ^Plugin) -> u32,
}
