// Independent C calling-convention probe: a complete miniature CLAP "plugin"
// compiled from C against the official headers, exported from a shared library
// and driven through the Odin declarations.
//
// The test proves, for the shapes this milestone uses:
//   - Odin can load the library and call a C function returning a const
//     clap_plugin_entry_t* (x64 Win64/SysV pointer return);
//   - Odin -> C calls through clap_plugin_entry_t and clap_plugin_factory_t
//     function pointers, with pointers to structs built by Odin;
//   - C -> Odin calls through clap_host_t.get_extension and through
//     clap_input_events_t/clap_output_events_t vtables built by Odin;
//   - C reads Odin-built clap_process_t, clap_audio_buffer_t,
//     clap_event_param_value_t and writes a clap_event_param_gesture_t back;
//   - C-provided clap_plugin_audio_ports_t extension structs are callable.
//
// On Windows the DLL uses __declspec(dllexport); elsewhere default visibility.
#if defined(_WIN32)
#define _CRT_SECURE_NO_WARNINGS 1
#define PROBE_EXPORT __declspec(dllexport)
#else
#define PROBE_EXPORT __attribute__((visibility("default")))
#endif

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "clap/version.h"
#include "clap/entry.h"
#include "clap/plugin.h"
#include "clap/host.h"
#include "clap/process.h"
#include "clap/audio-buffer.h"
#include "clap/events.h"
#include "clap/ext/audio-ports.h"
#include "clap/factory/plugin-factory.h"
#include "carnival-telemetry-capture.h"

#define PROBE_MARKER ((const void *)(uintptr_t)0x5A5A5A5A5A5A5A5Aull)

#define PROBE_CAPTURE_CAPACITY 3u

static int g_inited = 0;
static int g_destroyed = 0;
static int g_marker_ok = 0;
static int g_process_calls = 0;
static int g_param_seen = 0;
static double g_param_value = 0.0;
static float g_first_input = 0.0f;
static uint32_t g_last_frames = 0;
static int g_host_restart_calls = 0;

static clap_carnival_measurement_record_t g_capture_records[PROBE_CAPTURE_CAPACITY];
static uint32_t g_capture_count = 0;
static uint32_t g_capture_read = 0;
static bool g_capture_enabled = false;
static uint64_t g_capture_dropped = 0;
static bool g_capture_valid = true;
static uint32_t g_capture_schema_calls = 0;

typedef struct probe_instance {
   const clap_host_t *host;
   const clap_plugin_t *plugin;
} probe_instance;

static probe_instance g_instance;
static clap_plugin_t g_plugin;

static bool probe_plugin_init(const clap_plugin_t *plugin) {
   probe_instance *instance = (probe_instance *)plugin->plugin_data;
   const void *marker = instance->host->get_extension(instance->host, "probe.marker");
   g_marker_ok = marker == PROBE_MARKER;
   return true;
}

static void probe_plugin_destroy(const clap_plugin_t *plugin) {
   (void)plugin;
   g_destroyed += 1;
}

static bool probe_plugin_activate(const clap_plugin_t *plugin, double sample_rate,
                                  uint32_t min_frames, uint32_t max_frames) {
   (void)plugin;
   return sample_rate > 0.0 && min_frames >= 1 && max_frames >= min_frames;
}

static void probe_plugin_deactivate(const clap_plugin_t *plugin) { (void)plugin; }

static bool probe_plugin_start(const clap_plugin_t *plugin) {
   (void)plugin;
   return true;
}

static void probe_plugin_stop(const clap_plugin_t *plugin) { (void)plugin; }
static void probe_plugin_reset(const clap_plugin_t *plugin) { (void)plugin; }

static uint32_t probe_ports_count(const clap_plugin_t *plugin, bool is_input) {
   (void)plugin;
   return is_input ? 1u : 1u;
}

static bool probe_ports_get(const clap_plugin_t *plugin, uint32_t index, bool is_input,
                            clap_audio_port_info_t *info) {
   (void)plugin;
   if (index != 0 || info == NULL)
      return false;
   memset(info, 0, sizeof(*info));
   info->id = is_input ? 10u : 20u;
   strncpy(info->name, is_input ? "Probe In" : "Probe Out", CLAP_NAME_SIZE - 1);
   info->flags = CLAP_AUDIO_PORT_IS_MAIN;
   info->channel_count = 2;
   info->port_type = CLAP_PORT_STEREO;
   info->in_place_pair = is_input ? 20u : 10u;
   return true;
}

static const clap_plugin_audio_ports_t g_audio_ports = {
    probe_ports_count,
    probe_ports_get,
};

// --- Draft Carnival telemetry extension (implemented in C) -----------------

static bool probe_capture_set_enabled(const clap_plugin_t *plugin, bool enabled) {
   (void)plugin;
   g_capture_enabled = enabled;
   g_capture_count = 0;
   g_capture_read = 0;
   g_capture_dropped = 0;
   g_capture_valid = true;
   return true;
}

static uint32_t probe_capture_drain(const clap_plugin_t *plugin,
                                    clap_carnival_capture_sink_t sink,
                                    uint32_t max_records) {
   (void)plugin;
   if (sink.push == NULL)
      return 0;
   const uint32_t pending = g_capture_count - g_capture_read;
   const uint32_t limit = max_records == 0 ? pending : (max_records < pending ? max_records : pending);
   uint32_t delivered = 0;
   while (delivered < limit && g_capture_read < g_capture_count) {
      if (!sink.push(sink.ctx, &g_capture_records[g_capture_read]))
         break;
      g_capture_read += 1;
      delivered += 1;
   }
   return delivered;
}

static uint64_t probe_capture_dropped(const clap_plugin_t *plugin) {
   (void)plugin;
   return g_capture_dropped;
}

static bool probe_capture_valid(const clap_plugin_t *plugin) {
   (void)plugin;
   return g_capture_valid;
}

static uint32_t probe_capture_schema_version(const clap_plugin_t *plugin) {
   (void)plugin;
   g_capture_schema_calls += 1;
   return CARNIVAL_MEASUREMENT_SCHEMA_VERSION;
}

static const clap_carnival_telemetry_capture_t g_telemetry = {
    probe_capture_set_enabled,
    probe_capture_drain,
    probe_capture_dropped,
    probe_capture_valid,
    probe_capture_schema_version,
};

static clap_process_status probe_plugin_process(const clap_plugin_t *plugin,
                                                const clap_process_t *process) {
   probe_instance *instance = (probe_instance *)plugin->plugin_data;
   g_process_calls += 1;
   g_last_frames = process->frames_count;

   if (process->in_events != NULL && process->in_events->size(process->in_events) > 0) {
      const clap_event_header_t *header = process->in_events->get(process->in_events, 0);
      if (header != NULL && header->type == CLAP_EVENT_PARAM_VALUE &&
          header->size == sizeof(clap_event_param_value_t)) {
         const clap_event_param_value_t *value = (const clap_event_param_value_t *)header;
         g_param_seen = value->param_id == 1001u;
         g_param_value = value->value;
      }
   }

   if (process->audio_inputs_count < 1 || process->audio_outputs_count < 1 ||
       process->audio_inputs[0].data32 == NULL || process->audio_outputs[0].data32 == NULL)
      return CLAP_PROCESS_ERROR;

   const uint32_t frames = process->frames_count;
   const uint32_t channels = process->audio_inputs[0].channel_count;
   if (channels != 2 || process->audio_outputs[0].channel_count != 2)
      return CLAP_PROCESS_ERROR;

   for (uint32_t channel = 0; channel < channels; ++channel) {
      const float *in = process->audio_inputs[0].data32[channel];
      float *out = process->audio_outputs[0].data32[channel];
      if (in == NULL || out == NULL)
         return CLAP_PROCESS_ERROR;
      if (channel == 0 && frames > 0)
         g_first_input = in[0];
      if (in != out)
         memcpy(out, in, (size_t)frames * sizeof(float));
   }

   if (process->out_events != NULL) {
      clap_event_param_gesture_t gesture;
      memset(&gesture, 0, sizeof(gesture));
      gesture.header.size = (uint32_t)sizeof(gesture);
      gesture.header.time = 0;
      gesture.header.space_id = CLAP_CORE_EVENT_SPACE_ID;
      gesture.header.type = CLAP_EVENT_PARAM_GESTURE_BEGIN;
      gesture.param_id = 1001u;
      process->out_events->try_push(process->out_events, &gesture.header);
   }

   if (instance->host->request_restart != NULL) {
      instance->host->request_restart(instance->host);
      g_host_restart_calls += 1;
   }

   return CLAP_PROCESS_CONTINUE;
}

static const void *probe_plugin_get_extension(const clap_plugin_t *plugin, const char *id) {
   (void)plugin;
   if (strcmp(id, CLAP_EXT_AUDIO_PORTS) == 0)
      return &g_audio_ports;
   if (strcmp(id, CARNIVAL_EXT_TELEMETRY_CAPTURE_DRAFT) == 0)
      return &g_telemetry;
   return NULL;
}

static void probe_plugin_on_main_thread(const clap_plugin_t *plugin) { (void)plugin; }

static const clap_plugin_descriptor_t g_descriptor = {
    CLAP_VERSION_INIT,
    "com.carnival-science.probe",
    "CLAP C Calling Probe",
    "Carnival Science",
    "https://carnival.science/",
    "",
    "",
    "1.0.0",
    "C-compiled ABI probe",
    NULL,
};

static uint32_t probe_factory_count(const clap_plugin_factory_t *factory) {
   (void)factory;
   return 1;
}

static const clap_plugin_descriptor_t *
probe_factory_descriptor(const clap_plugin_factory_t *factory, uint32_t index) {
   (void)factory;
   return index == 0 ? &g_descriptor : NULL;
}

static const clap_plugin_t *probe_factory_create(const clap_plugin_factory_t *factory,
                                                 const clap_host_t *host,
                                                 const char *plugin_id) {
   (void)factory;
   if (host == NULL || plugin_id == NULL ||
       strcmp(plugin_id, "com.carnival-science.probe") != 0)
      return NULL;
   g_instance.host = host;
   g_instance.plugin = &g_plugin;
   g_destroyed = 0;
   g_marker_ok = 0;
   g_process_calls = 0;
   g_param_seen = 0;
   g_param_value = 0.0;
   g_first_input = 0.0f;
   g_last_frames = 0;
   g_host_restart_calls = 0;
   g_capture_count = 0;
   g_capture_read = 0;
   g_capture_enabled = false;
   g_capture_dropped = 0;
   g_capture_valid = true;
   g_capture_schema_calls = 0;

   g_plugin.desc = &g_descriptor;
   g_plugin.plugin_data = &g_instance;
   g_plugin.init = probe_plugin_init;
   g_plugin.destroy = probe_plugin_destroy;
   g_plugin.activate = probe_plugin_activate;
   g_plugin.deactivate = probe_plugin_deactivate;
   g_plugin.start_processing = probe_plugin_start;
   g_plugin.stop_processing = probe_plugin_stop;
   g_plugin.reset = probe_plugin_reset;
   g_plugin.process = probe_plugin_process;
   g_plugin.get_extension = probe_plugin_get_extension;
   g_plugin.on_main_thread = probe_plugin_on_main_thread;
   return &g_plugin;
}

static const clap_plugin_factory_t g_factory = {
    probe_factory_count,
    probe_factory_descriptor,
    probe_factory_create,
};

static bool probe_entry_init(const char *plugin_path) {
   (void)plugin_path;
   g_inited += 1;
   return true;
}

static void probe_entry_deinit(void) { g_inited -= 1; }

static const void *probe_entry_get_factory(const char *factory_id) {
   return strcmp(factory_id, CLAP_PLUGIN_FACTORY_ID) == 0 ? &g_factory : NULL;
}

static const clap_plugin_entry_t g_entry = {
    CLAP_VERSION_INIT,
    probe_entry_init,
    probe_entry_deinit,
    probe_entry_get_factory,
};

PROBE_EXPORT const clap_plugin_entry_t *probe_entry(void) { return &g_entry; }
PROBE_EXPORT int probe_entry_init_depth(void) { return g_inited; }
PROBE_EXPORT int probe_marker_ok(void) { return g_marker_ok; }
PROBE_EXPORT int probe_destroyed(void) { return g_destroyed; }
PROBE_EXPORT int probe_process_calls(void) { return g_process_calls; }
PROBE_EXPORT int probe_param_seen(void) { return g_param_seen; }
PROBE_EXPORT double probe_param_value(void) { return g_param_value; }
PROBE_EXPORT float probe_first_input(void) { return g_first_input; }
PROBE_EXPORT uint32_t probe_last_frames(void) { return g_last_frames; }
PROBE_EXPORT int probe_host_restart_calls(void) { return g_host_restart_calls; }

// Draft Carnival telemetry helpers, reached by the Odin host through plain
// exported C symbols. They exercise the same vtable the host calls normally.
PROBE_EXPORT int probe_capture_seed(unsigned count) {
   if (!g_capture_enabled)
      return 0;
   if (count > PROBE_CAPTURE_CAPACITY)
      count = PROBE_CAPTURE_CAPACITY;
   g_capture_count = count;
   g_capture_read = 0;
   for (unsigned i = 0; i < count; ++i) {
      clap_carnival_measurement_record_t *record = &g_capture_records[i];
      memset(record, 0, sizeof(*record));
      record->schema_version = CARNIVAL_MEASUREMENT_SCHEMA_VERSION;
      record->epoch = 7;
      record->generation = (uint64_t)i + 1;
      record->start_frame = (int64_t)i * 1024;
      record->frames = 1024;
      record->channels = CARNIVAL_MEASUREMENT_CHANNELS;
      record->sample_rate = 48000;
      record->peak[0] = 0.5f;
      record->peak[1] = 0.25f;
      record->peak_frame[0] = 3;
      record->rms[0] = 0.25f;
      record->hold[0] = 0.5f;
      record->valid = true;
      record->overrun = false;
      record->capture_valid = true;
   }
   return (int)count;
}

PROBE_EXPORT int probe_capture_force_overflow(void) {
   g_capture_dropped += 2;
   g_capture_valid = false;
   return (int)g_capture_dropped;
}

PROBE_EXPORT int probe_capture_enabled(void) { return g_capture_enabled ? 1 : 0; }
PROBE_EXPORT unsigned probe_capture_schema_constant(void) {
   return CARNIVAL_MEASUREMENT_SCHEMA_VERSION;
}
PROBE_EXPORT unsigned probe_capture_schema_calls(void) { return g_capture_schema_calls; }
