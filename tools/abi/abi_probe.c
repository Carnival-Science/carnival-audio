// Independent C ABI layout probe for the Odin CLAP declarations.
//
// Compiled against the vendored official CLAP 1.2.10 headers. It prints one
// line per fact:
//
//   version <major> <minor> <revision>
//   size <OdinTypeName> <bytes>
//   offset <OdinTypeName>.<OdinFieldName> <bytes>
//
// tests/abi_layout_test.odin parses this file and compares every value with
// Odin's size_of/offset_of. The expected values therefore come from the C
// compiler and the official headers, not from the Odin declarations.
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#include "clap/version.h"
#include "clap/entry.h"
#include "clap/plugin.h"
#include "clap/host.h"
#include "clap/process.h"
#include "clap/audio-buffer.h"
#include "clap/events.h"
#include "clap/stream.h"
#include "clap/id.h"
#include "clap/string-sizes.h"
#include "clap/ext/audio-ports.h"
#include "clap/ext/params.h"
#include "clap/ext/state.h"
#include "clap/ext/latency.h"
#include "clap/ext/thread-check.h"
#include "clap/ext/tail.h"
#include "clap/ext/render.h"
#include "clap/factory/plugin-factory.h"

#define SIZE(odin_name, c_type) printf("size %s %zu\n", odin_name, sizeof(c_type))
#define FIELD(odin_name, odin_field, c_type, c_field)                              \
   printf("offset %s.%s %zu\n", odin_name, odin_field, offsetof(c_type, c_field))

int main(void) {
   printf("version %u %u %u\n", (unsigned)CLAP_VERSION_MAJOR, (unsigned)CLAP_VERSION_MINOR,
          (unsigned)CLAP_VERSION_REVISION);
   printf("bool_size %zu\n", sizeof(bool));
   printf("invalid_id %u\n", (unsigned)CLAP_INVALID_ID);
   printf("name_size %d\n", CLAP_NAME_SIZE);
   printf("path_size %d\n", CLAP_PATH_SIZE);

   SIZE("Version", clap_version_t);
   FIELD("Version", "major", clap_version_t, major);
   FIELD("Version", "minor", clap_version_t, minor);
   FIELD("Version", "revision", clap_version_t, revision);

   SIZE("Entry", clap_plugin_entry_t);
   FIELD("Entry", "clap_version", clap_plugin_entry_t, clap_version);
   FIELD("Entry", "init", clap_plugin_entry_t, init);
   FIELD("Entry", "deinit", clap_plugin_entry_t, deinit);
   FIELD("Entry", "get_factory", clap_plugin_entry_t, get_factory);

   SIZE("Plugin_Descriptor", clap_plugin_descriptor_t);
   FIELD("Plugin_Descriptor", "clap_version", clap_plugin_descriptor_t, clap_version);
   FIELD("Plugin_Descriptor", "id", clap_plugin_descriptor_t, id);
   FIELD("Plugin_Descriptor", "name", clap_plugin_descriptor_t, name);
   FIELD("Plugin_Descriptor", "vendor", clap_plugin_descriptor_t, vendor);
   FIELD("Plugin_Descriptor", "url", clap_plugin_descriptor_t, url);
   FIELD("Plugin_Descriptor", "manual_url", clap_plugin_descriptor_t, manual_url);
   FIELD("Plugin_Descriptor", "support_url", clap_plugin_descriptor_t, support_url);
   FIELD("Plugin_Descriptor", "version", clap_plugin_descriptor_t, version);
   FIELD("Plugin_Descriptor", "description", clap_plugin_descriptor_t, description);
   FIELD("Plugin_Descriptor", "features", clap_plugin_descriptor_t, features);

   SIZE("Plugin", clap_plugin_t);
   FIELD("Plugin", "desc", clap_plugin_t, desc);
   FIELD("Plugin", "plugin_data", clap_plugin_t, plugin_data);
   FIELD("Plugin", "init", clap_plugin_t, init);
   FIELD("Plugin", "destroy", clap_plugin_t, destroy);
   FIELD("Plugin", "activate", clap_plugin_t, activate);
   FIELD("Plugin", "deactivate", clap_plugin_t, deactivate);
   FIELD("Plugin", "start_processing", clap_plugin_t, start_processing);
   FIELD("Plugin", "stop_processing", clap_plugin_t, stop_processing);
   FIELD("Plugin", "reset", clap_plugin_t, reset);
   FIELD("Plugin", "process", clap_plugin_t, process);
   FIELD("Plugin", "get_extension", clap_plugin_t, get_extension);
   FIELD("Plugin", "on_main_thread", clap_plugin_t, on_main_thread);

   SIZE("Host", clap_host_t);
   FIELD("Host", "clap_version", clap_host_t, clap_version);
   FIELD("Host", "host_data", clap_host_t, host_data);
   FIELD("Host", "name", clap_host_t, name);
   FIELD("Host", "vendor", clap_host_t, vendor);
   FIELD("Host", "url", clap_host_t, url);
   FIELD("Host", "version", clap_host_t, version);
   FIELD("Host", "get_extension", clap_host_t, get_extension);
   FIELD("Host", "request_restart", clap_host_t, request_restart);
   FIELD("Host", "request_process", clap_host_t, request_process);
   FIELD("Host", "request_callback", clap_host_t, request_callback);

   SIZE("Audio_Buffer", clap_audio_buffer_t);
   FIELD("Audio_Buffer", "data32", clap_audio_buffer_t, data32);
   FIELD("Audio_Buffer", "data64", clap_audio_buffer_t, data64);
   FIELD("Audio_Buffer", "channel_count", clap_audio_buffer_t, channel_count);
   FIELD("Audio_Buffer", "latency", clap_audio_buffer_t, latency);
   FIELD("Audio_Buffer", "constant_mask", clap_audio_buffer_t, constant_mask);

   SIZE("Process", clap_process_t);
   FIELD("Process", "steady_time", clap_process_t, steady_time);
   FIELD("Process", "frames_count", clap_process_t, frames_count);
   FIELD("Process", "transport", clap_process_t, transport);
   FIELD("Process", "audio_inputs", clap_process_t, audio_inputs);
   FIELD("Process", "audio_outputs", clap_process_t, audio_outputs);
   FIELD("Process", "audio_inputs_count", clap_process_t, audio_inputs_count);
   FIELD("Process", "audio_outputs_count", clap_process_t, audio_outputs_count);
   FIELD("Process", "in_events", clap_process_t, in_events);
   FIELD("Process", "out_events", clap_process_t, out_events);

   SIZE("Event_Header", clap_event_header_t);
   FIELD("Event_Header", "size", clap_event_header_t, size);
   FIELD("Event_Header", "time", clap_event_header_t, time);
   FIELD("Event_Header", "space_id", clap_event_header_t, space_id);
   FIELD("Event_Header", "type", clap_event_header_t, type);
   FIELD("Event_Header", "flags", clap_event_header_t, flags);

   SIZE("Event_Param_Value", clap_event_param_value_t);
   FIELD("Event_Param_Value", "header", clap_event_param_value_t, header);
   FIELD("Event_Param_Value", "param_id", clap_event_param_value_t, param_id);
   FIELD("Event_Param_Value", "cookie", clap_event_param_value_t, cookie);
   FIELD("Event_Param_Value", "note_id", clap_event_param_value_t, note_id);
   FIELD("Event_Param_Value", "port_index", clap_event_param_value_t, port_index);
   FIELD("Event_Param_Value", "channel", clap_event_param_value_t, channel);
   FIELD("Event_Param_Value", "key", clap_event_param_value_t, key);
   FIELD("Event_Param_Value", "value", clap_event_param_value_t, value);

   SIZE("Event_Param_Mod", clap_event_param_mod_t);
   FIELD("Event_Param_Mod", "amount", clap_event_param_mod_t, amount);

   SIZE("Event_Param_Gesture", clap_event_param_gesture_t);
   FIELD("Event_Param_Gesture", "param_id", clap_event_param_gesture_t, param_id);

   SIZE("Event_Transport", clap_event_transport_t);
   FIELD("Event_Transport", "header", clap_event_transport_t, header);
   FIELD("Event_Transport", "flags", clap_event_transport_t, flags);
   FIELD("Event_Transport", "song_pos_beats", clap_event_transport_t, song_pos_beats);
   FIELD("Event_Transport", "song_pos_seconds", clap_event_transport_t, song_pos_seconds);
   FIELD("Event_Transport", "tempo", clap_event_transport_t, tempo);
   FIELD("Event_Transport", "tempo_inc", clap_event_transport_t, tempo_inc);
   FIELD("Event_Transport", "bar_number", clap_event_transport_t, bar_number);
   FIELD("Event_Transport", "tsig_num", clap_event_transport_t, tsig_num);
   FIELD("Event_Transport", "tsig_denom", clap_event_transport_t, tsig_denom);

   SIZE("Event_Midi", clap_event_midi_t);
   FIELD("Event_Midi", "port_index", clap_event_midi_t, port_index);
   FIELD("Event_Midi", "data", clap_event_midi_t, data);

   SIZE("Event_Midi_Sysex", clap_event_midi_sysex_t);
   FIELD("Event_Midi_Sysex", "buffer", clap_event_midi_sysex_t, buffer);
   FIELD("Event_Midi_Sysex", "size", clap_event_midi_sysex_t, size);

   SIZE("Event_Midi2", clap_event_midi2_t);
   FIELD("Event_Midi2", "port_index", clap_event_midi2_t, port_index);
   FIELD("Event_Midi2", "data", clap_event_midi2_t, data);

   SIZE("Input_Events", clap_input_events_t);
   FIELD("Input_Events", "ctx", clap_input_events_t, ctx);
   FIELD("Input_Events", "size", clap_input_events_t, size);
   FIELD("Input_Events", "get", clap_input_events_t, get);

   SIZE("Output_Events", clap_output_events_t);
   FIELD("Output_Events", "ctx", clap_output_events_t, ctx);
   FIELD("Output_Events", "try_push", clap_output_events_t, try_push);

   SIZE("Plugin_Factory", clap_plugin_factory_t);
   FIELD("Plugin_Factory", "get_plugin_count", clap_plugin_factory_t, get_plugin_count);
   FIELD("Plugin_Factory", "get_plugin_descriptor", clap_plugin_factory_t,
         get_plugin_descriptor);
   FIELD("Plugin_Factory", "create_plugin", clap_plugin_factory_t, create_plugin);

   SIZE("Audio_Port_Info", clap_audio_port_info_t);
   FIELD("Audio_Port_Info", "id", clap_audio_port_info_t, id);
   FIELD("Audio_Port_Info", "name", clap_audio_port_info_t, name);
   FIELD("Audio_Port_Info", "flags", clap_audio_port_info_t, flags);
   FIELD("Audio_Port_Info", "channel_count", clap_audio_port_info_t, channel_count);
   FIELD("Audio_Port_Info", "port_type", clap_audio_port_info_t, port_type);
   FIELD("Audio_Port_Info", "in_place_pair", clap_audio_port_info_t, in_place_pair);

   SIZE("Plugin_Audio_Ports", clap_plugin_audio_ports_t);
   FIELD("Plugin_Audio_Ports", "count", clap_plugin_audio_ports_t, count);
   FIELD("Plugin_Audio_Ports", "get", clap_plugin_audio_ports_t, get);

   SIZE("Param_Info", clap_param_info_t);
   FIELD("Param_Info", "id", clap_param_info_t, id);
   FIELD("Param_Info", "flags", clap_param_info_t, flags);
   FIELD("Param_Info", "cookie", clap_param_info_t, cookie);
   FIELD("Param_Info", "name", clap_param_info_t, name);
   FIELD("Param_Info", "module", clap_param_info_t, module);
   FIELD("Param_Info", "min_value", clap_param_info_t, min_value);
   FIELD("Param_Info", "max_value", clap_param_info_t, max_value);
   FIELD("Param_Info", "default_value", clap_param_info_t, default_value);

   SIZE("Plugin_Params", clap_plugin_params_t);
   FIELD("Plugin_Params", "count", clap_plugin_params_t, count);
   FIELD("Plugin_Params", "get_info", clap_plugin_params_t, get_info);
   FIELD("Plugin_Params", "get_value", clap_plugin_params_t, get_value);
   FIELD("Plugin_Params", "value_to_text", clap_plugin_params_t, value_to_text);
   FIELD("Plugin_Params", "text_to_value", clap_plugin_params_t, text_to_value);
   FIELD("Plugin_Params", "flush", clap_plugin_params_t, flush);

   SIZE("IStream", clap_istream_t);
   FIELD("IStream", "ctx", clap_istream_t, ctx);
   FIELD("IStream", "read", clap_istream_t, read);

   SIZE("OStream", clap_ostream_t);
   FIELD("OStream", "ctx", clap_ostream_t, ctx);
   FIELD("OStream", "write", clap_ostream_t, write);

   SIZE("Plugin_State", clap_plugin_state_t);
   FIELD("Plugin_State", "save", clap_plugin_state_t, save);
   FIELD("Plugin_State", "load", clap_plugin_state_t, load);

   SIZE("Host_State", clap_host_state_t);
   FIELD("Host_State", "mark_dirty", clap_host_state_t, mark_dirty);

   SIZE("Plugin_Latency", clap_plugin_latency_t);
   FIELD("Plugin_Latency", "get", clap_plugin_latency_t, get);

   SIZE("Host_Latency", clap_host_latency_t);
   FIELD("Host_Latency", "changed", clap_host_latency_t, changed);

   SIZE("Host_Thread_Check", clap_host_thread_check_t);
   FIELD("Host_Thread_Check", "is_main_thread", clap_host_thread_check_t, is_main_thread);
   FIELD("Host_Thread_Check", "is_audio_thread", clap_host_thread_check_t, is_audio_thread);

   SIZE("Plugin_Tail", clap_plugin_tail_t);
   FIELD("Plugin_Tail", "get", clap_plugin_tail_t, get);

   SIZE("Host_Audio_Ports", clap_host_audio_ports_t);
   FIELD("Host_Audio_Ports", "is_rescan_flag_supported", clap_host_audio_ports_t,
         is_rescan_flag_supported);
   FIELD("Host_Audio_Ports", "rescan", clap_host_audio_ports_t, rescan);

   SIZE("Host_Params", clap_host_params_t);
   FIELD("Host_Params", "rescan", clap_host_params_t, rescan);
   FIELD("Host_Params", "clear", clap_host_params_t, clear);
   FIELD("Host_Params", "request_flush", clap_host_params_t, request_flush);

   SIZE("Plugin_Render", clap_plugin_render_t);
   FIELD("Plugin_Render", "has_hard_realtime_requirement", clap_plugin_render_t,
         has_hard_realtime_requirement);
   FIELD("Plugin_Render", "set", clap_plugin_render_t, set);

   return 0;
}
