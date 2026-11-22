// Shared harness for Milestone 0 integration tests.
package tests

import "core:mem"
import "core:testing"

import "carnival:core/dsp"
import "carnival:core/stream"
import "carnival:core/transport"

// Counting_Allocator measures peak bytes requested from a backing allocator.
// It is intentionally simple: the goal is a ceiling for setup allocations, not
// a general-purpose accounting allocator. Frees with an unknown size do not
// decrease `current`, so `peak` is the conservative high-water mark.
Counting_Allocator :: struct {
	backing: mem.Allocator,
	current: int,
	peak:    int,
	allocs:  int,
	frees:   int,
}

counting_allocator_proc :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size: int,
	alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	counter := cast(^Counting_Allocator)data
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		bytes, err := mem.alloc_bytes(size, alignment, counter.backing)
		if err == .None {
			counter.current += len(bytes)
			counter.peak = max(counter.peak, counter.current)
			counter.allocs += 1
		}
		return bytes, err
	case .Free:
		err := mem.free(old_memory, counter.backing)
		if err == .None {
			counter.current -= old_size
			if counter.current < 0 {
				counter.current = 0
			}
			counter.frees += 1
		}
		return nil, err
	case .Resize, .Resize_Non_Zeroed:
		old_bytes := mem.byte_slice(old_memory, old_size)
		bytes, err := mem.resize_bytes(old_bytes, size, alignment, counter.backing)
		if err == .None {
			counter.current += len(bytes) - old_size
			counter.peak = max(counter.peak, counter.current)
		}
		return bytes, err
	case .Query_Features, .Query_Info:
		return nil, .None
	case .Free_All:
		return nil, .Mode_Not_Implemented
	}
	return nil, .Mode_Not_Implemented
}

counting_allocator :: proc(counter: ^Counting_Allocator) -> mem.Allocator {
	return mem.Allocator{procedure = counting_allocator_proc, data = counter}
}

MAX_WINDOWS :: 16

RMS_Collector :: struct {
	count:  int,
	values: [MAX_WINDOWS][dsp.MAX_CHANNELS]f32,
	valid:  [MAX_WINDOWS]bool,
}

rms_collector_callback :: proc(user: rawptr, record: dsp.RMS_Record) {
	collector := cast(^RMS_Collector)user
	if collector.count < MAX_WINDOWS {
		for channel in 0 ..< record.channels {
			collector.values[collector.count][channel] = record.rms[channel]
		}
		collector.valid[collector.count] = record.valid
	}
	collector.count += 1
}

Correlation_Collector :: struct {
	count:  int,
	values: [MAX_WINDOWS]f32,
	valid:  [MAX_WINDOWS]bool,
}

correlation_collector_callback :: proc(user: rawptr, record: dsp.Correlation_Record) {
	collector := cast(^Correlation_Collector)user
	if collector.count < MAX_WINDOWS {
		collector.values[collector.count] = record.value
		collector.valid[collector.count] = record.valid
	}
	collector.count += 1
}

Partition_Result :: struct {
	peak:          dsp.Sample_Peak,
	peak_channels: [dsp.MAX_CHANNELS]dsp.Sample_Peak,
	rms:           RMS_Collector,
	correlation:   Correlation_Collector,
}

// run_partitions feeds the same sample stream through fixed-window analysis in
// arbitrary contiguous blocks, as a real transport or replay source would.
run_partitions :: proc(samples: []f32, frames, channels, partition: int) -> Partition_Result {
	result: Partition_Result
	peak: dsp.Peak_Accumulator
	_ = dsp.peak_accumulator_init(&peak, channels)
	rms_window: dsp.RMS_Window
	_ = dsp.rms_window_init(&rms_window, 1024, channels)
	correlation_window: dsp.Correlation_Window
	_ = dsp.correlation_window_init(&correlation_window, 1024)

	offset := 0
	for offset < frames {
		count := min(partition, frames - offset)
		block := stream.Audio_Block{
			start_frame = i64(offset),
			frames = count,
			channels = channels,
			interleaved = samples[offset * channels : (offset + count) * channels],
		}
		_ = dsp.peak_accumulator_process(&peak, block)
		_ = dsp.rms_window_process(&rms_window, block, rms_collector_callback, &result.rms)
		if channels == 2 {
			_ = dsp.correlation_window_process(&correlation_window, block, correlation_collector_callback, &result.correlation)
		}
		offset += count
	}
	result.peak = peak.overall
	for channel in 0 ..< channels {
		result.peak_channels[channel] = peak.per_channel[channel]
	}
	return result
}

FFT_Partition_Result :: struct {
	count:      int,
	magnitudes: [8][513]f32,
}

// run_fft_partitions fills 1024-frame Hann windows from the left channel of
// `samples`, respecting arbitrary partition boundaries, and records the
// amplitude spectrum of each complete window.
run_fft_partitions :: proc(t: ^testing.T, samples: []f32, frames, channels, partition: int) -> FFT_Partition_Result {
	result: FFT_Partition_Result
	plan: dsp.Real_FFT_Plan
	testing.expect(t, dsp.real_fft_plan_init(&plan, 1024, .Hann) == .None, "plan")
	defer dsp.real_fft_plan_destroy(&plan)
	window_samples := make([]f32, 1024)
	defer delete(window_samples)
	spectrum := make([]dsp.Complex32, 513)
	defer delete(spectrum)
	filled := 0
	offset := 0
	for offset < frames {
		count := min(partition, frames - offset)
		for frame in 0 ..< count {
			window_samples[filled] = samples[(offset + frame) * channels]
			filled += 1
			if filled == 1024 {
				testing.expect(t, dsp.real_fft_forward(&plan, window_samples, spectrum), "forward")
				if result.count < 8 {
					for bin in 0 ..< 513 {
						result.magnitudes[result.count][bin] = dsp.real_fft_amplitude(&plan, spectrum, bin)
					}
					result.count += 1
				}
				filled = 0
			}
		}
		offset += count
	}
	return result
}

pipeline_snapshot :: proc(result: Partition_Result, generation: u64 = 1) -> transport.Measurement_Snapshot {
	snapshot := transport.Measurement_Snapshot{
		generation = generation,
		valid = result.peak.valid,
		epoch = 1,
		frame = 10000,
		sample_rate = 48000,
		channels = 2,
		peak = {result.peak_channels[0].magnitude, result.peak_channels[1].magnitude},
		peak_frame = {result.peak_channels[0].frame, result.peak_channels[1].frame},
		peak_db = {
			dsp.peak_amplitude_to_dbfs(result.peak_channels[0].magnitude),
			dsp.peak_amplitude_to_dbfs(result.peak_channels[1].magnitude),
		},
		correlation = 0,
		correlation_valid = false,
	}
	if result.rms.count > 0 {
		last := result.rms.count - 1
		if last >= MAX_WINDOWS {
			last = MAX_WINDOWS - 1
		}
		for channel in 0 ..< 2 {
			snapshot.rms[channel] = result.rms.values[last][channel]
			snapshot.rms_db[channel] = dsp.rms_to_dbfs(result.rms.values[last][channel])
			snapshot.hold[channel] = result.peak_channels[channel].magnitude
			snapshot.hold_db[channel] = dsp.peak_amplitude_to_dbfs(result.peak_channels[channel].magnitude)
		}
	}
	if result.correlation.count > 0 {
		last := min(result.correlation.count - 1, MAX_WINDOWS - 1)
		snapshot.correlation = result.correlation.values[last]
		snapshot.correlation_valid = result.correlation.valid[last]
	}
	return snapshot
}
