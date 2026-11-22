// DRAFT private Carnival telemetry extension — experimental, not a CLAP
// standard proposal.
//
// C mirror of `third_party/clap/abi/ext_carnival.odin`. It exists so the
// independent C layout probe can assert the Odin declaration against a C
// compiler and so the miniature C plugin probe can implement the extension for
// an Odin host. Keep this file and the Odin declaration in lockstep; the probe
// in `tools/abi/` fails when they disagree.
//
// Rules (same as the Odin header):
//   - private draft; the id, UUIDs, vtable and record layout may change in a
//     later draft revision, signalled by a new /N suffix on the extension id;
//   - all functions are called from the host main thread, never the audio
//     thread;
//   - the sink callback is synchronous and its record pointer must not be
//     retained or used after the call returns.
#ifndef CLAP_CARNIVAL_TELEMETRY_CAPTURE_DRAFT_H
#define CLAP_CARNIVAL_TELEMETRY_CAPTURE_DRAFT_H

#include <stdbool.h>
#include <stdint.h>

#include "clap/plugin.h"
#include "clap/stream.h"

#define CARNIVAL_EXT_TELEMETRY_CAPTURE_DRAFT "com.carnival-science.telemetry-capture.draft/1"

#define CARNIVAL_TELEMETRY_DRAFT_UUID                                                              \
   { 0x33, 0xC1, 0x8B, 0x91, 0xBC, 0x23, 0x42, 0x90, 0x86, 0xA8, 0x2D, 0x40, 0x35, 0x31, 0x6E, 0xCC }
#define CARNIVAL_MEASUREMENT_SCHEMA_UUID                                                           \
   { 0xFD, 0xEC, 0xFE, 0x25, 0x9B, 0x08, 0x41, 0x63, 0xAD, 0xE3, 0xBA, 0xF7, 0xBC, 0xC2, 0xED, 0xAB }

#define CARNIVAL_MEASUREMENT_SCHEMA_VERSION 1u
#define CARNIVAL_MEASUREMENT_CHANNELS 2

typedef struct clap_carnival_measurement_record {
   uint32_t schema_version;
   uint64_t epoch;
   uint64_t generation;
   int64_t start_frame;
   uint32_t frames;
   uint32_t channels;
   uint32_t sample_rate;
   float peak[CARNIVAL_MEASUREMENT_CHANNELS];
   int64_t peak_frame[CARNIVAL_MEASUREMENT_CHANNELS];
   float rms[CARNIVAL_MEASUREMENT_CHANNELS];
   float hold[CARNIVAL_MEASUREMENT_CHANNELS];
   bool valid;
   bool overrun;
   bool capture_valid;
} clap_carnival_measurement_record_t;

typedef struct clap_carnival_capture_sink {
   void *ctx;
   bool (*push)(void *ctx, const clap_carnival_measurement_record_t *record);
} clap_carnival_capture_sink_t;

typedef struct clap_carnival_telemetry_capture {
   bool (*set_enabled)(const clap_plugin_t *plugin, bool enabled);
   uint32_t (*drain)(const clap_plugin_t *plugin, clap_carnival_capture_sink_t sink,
                     uint32_t max_records);
   uint64_t (*dropped)(const clap_plugin_t *plugin);
   bool (*valid)(const clap_plugin_t *plugin);
   uint32_t (*schema_version)(const clap_plugin_t *plugin);
} clap_carnival_telemetry_capture_t;

// ---------------------------------------------------------------------------
// Draft: Carnival processing-checkpoint extension (separate capability)
// ---------------------------------------------------------------------------
//
// Authoring state (clap.state) reopens a project with the same settings. A
// processing checkpoint resumes computation at an exact sample position. This
// extension is optional: call `supported()` first. A host must not treat an
// authoring state that omits a delay line as a defect; that omission is only a
// defect of this checkpoint capability, and only when `supported()` is true.
#define CARNIVAL_EXT_PROCESSING_CHECKPOINT_DRAFT "com.carnival-science.processing-checkpoint.draft/1"

#define CARNIVAL_CHECKPOINT_DRAFT_UUID                                                             \
   { 0x5C, 0x2F, 0x0A, 0x7E, 0x4B, 0x1D, 0x4C, 0x8E, 0x9F, 0x3A, 0x7D, 0x6E, 0x2B, 0x1C, 0x0A, 0x95 }

#define CARNIVAL_CHECKPOINT_SCHEMA_VERSION 1u

typedef struct clap_carnival_processing_checkpoint {
   bool (*supported)(const clap_plugin_t *plugin);
   bool (*save)(const clap_plugin_t *plugin, clap_ostream_t *stream);
   bool (*load)(const clap_plugin_t *plugin, clap_istream_t *stream);
   uint32_t (*schema_version)(const clap_plugin_t *plugin);
} clap_carnival_processing_checkpoint_t;

#endif // CLAP_CARNIVAL_TELEMETRY_CAPTURE_DRAFT_H
