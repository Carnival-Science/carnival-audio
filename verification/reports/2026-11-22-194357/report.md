# A-1 verification laboratory run

- Date: 2026-11-22T19:43:57.9007620-06:00
- Git commit: 3178515d0ef9242a287c1f2b33939737ee96335b (dirty working tree: True)
- Platform: windows X64 - Microsoft Windows 10.0.19045 
- CPU: AMD Ryzen 5 7600X 6-Core Processor (12 logical processors)
- Odin: C:\odin\odin.exe version dev-2026-11-nightly:08539cd
- Exit semantics: worker 0 = all probes pass, 1 = specimen probe failure, 2 = laboratory failure

## Census

| Specimen | Probe | Observed | Expected | Classification | Class |
| --- | --- | --- | --- | --- | --- |
| pulse | measurement | pass | pass | expected_pass | canonical_measurement |
| pulse | spectrum | pass | pass | expected_pass | independent_dft |
| pulse | nonfinite | pass | pass | expected_pass | non_finite_output |
| pulse | repeatability | pass | pass | expected_pass | fresh_instance_repeatability |
| pulse | partition | pass | pass | expected_pass | static_partition_invariant |
| pulse | automation | pass | pass | expected_pass | automation_partition_sensitive_control_rate |
| pulse | state | pass | pass | expected_pass | authoring_state_and_migration |
| pulse | checkpoint | skip | pass | skip | processing_checkpoint_restore |
| pulse | isolation | pass | pass | expected_pass | instance_isolation |
| pulse | reset | pass | pass | expected_pass | reset_clean_state |
| pulse | tail | pass | pass | expected_pass | tail_boundedness |
| pulse | perturbation | pass | pass | expected_pass | paired_input_response |
| pulse | capture_toggle | pass | pass | expected_pass | capture_episode_semantics |
| pulse | capture_overflow | pass | pass | expected_pass | capture_queue_overflow |
| pulse | gap | pass | pass | expected_pass | audio_discontinuity_segments |
| pulse | cross_process_repeatability | pass | pass | expected_pass | fresh_process_repeatability |
| gain | nonfinite | pass | pass | expected_pass | non_finite_output |
| gain | repeatability | pass | pass | expected_pass | fresh_instance_repeatability |
| gain | partition | pass | pass | expected_pass | static_partition_invariant |
| gain | automation | pass | pass | expected_pass | automation_partition_sensitive_control_rate |
| gain | state | pass | pass | expected_pass | authoring_state_and_migration |
| gain | isolation | pass | pass | expected_pass | instance_isolation |
| gain | reset | pass | pass | expected_pass | reset_clean_state |
| gain | tail | pass | pass | expected_pass | tail_boundedness |
| gain | perturbation | pass | pass | expected_pass | paired_input_response |
| gain | cross_process_repeatability | pass | pass | expected_pass | fresh_process_repeatability |
| biquad | nonfinite | pass | pass | expected_pass | non_finite_output |
| biquad | repeatability | pass | pass | expected_pass | fresh_instance_repeatability |
| biquad | partition | pass | pass | expected_pass | static_partition_invariant |
| biquad | automation | pass | pass | expected_pass | automation_partition_sensitive_control_rate |
| biquad | state | pass | pass | expected_pass | authoring_state_and_migration |
| biquad | checkpoint | pass | pass | expected_pass | processing_checkpoint_restore |
| biquad | isolation | pass | pass | expected_pass | instance_isolation |
| biquad | reset | pass | pass | expected_pass | reset_clean_state |
| biquad | tail | pass | pass | expected_pass | tail_boundedness |
| biquad | perturbation | pass | pass | expected_pass | paired_input_response |
| biquad | cross_process_repeatability | pass | pass | expected_pass | fresh_process_repeatability |
| delay | nonfinite | pass | pass | expected_pass | non_finite_output |
| delay | repeatability | pass | pass | expected_pass | fresh_instance_repeatability |
| delay | partition | pass | pass | expected_pass | static_partition_invariant |
| delay | automation | pass | pass | expected_pass | automation_partition_sensitive_control_rate |
| delay | state | pass | pass | expected_pass | authoring_state_and_migration |
| delay | checkpoint | pass | pass | expected_pass | processing_checkpoint_restore |
| delay | isolation | pass | pass | expected_pass | instance_isolation |
| delay | reset | pass | pass | expected_pass | reset_clean_state |
| delay | tail | pass | pass | expected_pass | tail_boundedness |
| delay | perturbation | pass | pass | expected_pass | paired_input_response |
| delay | cross_process_repeatability | pass | pass | expected_pass | fresh_process_repeatability |
| block_smoother | nonfinite | pass | pass | expected_pass | non_finite_output |
| block_smoother | repeatability | pass | pass | expected_pass | fresh_instance_repeatability |
| block_smoother | partition | fail | fail | expected_fail | static_partition_sensitive |
| block_smoother | state | pass | pass | expected_pass | authoring_state_and_migration |
| block_smoother | isolation | pass | pass | expected_pass | instance_isolation |
| block_smoother | reset | pass | pass | expected_pass | reset_clean_state |
| block_smoother | tail | pass | pass | expected_pass | tail_boundedness |
| block_smoother | perturbation | pass | pass | expected_pass | paired_input_response |
| block_smoother | cross_process_repeatability | pass | pass | expected_pass | fresh_process_repeatability |
| leaky_delay | nonfinite | pass | pass | expected_pass | non_finite_output |
| leaky_delay | repeatability | pass | pass | expected_pass | fresh_instance_repeatability |
| leaky_delay | partition | pass | pass | expected_pass | static_partition_invariant |
| leaky_delay | state | pass | pass | expected_pass | authoring_state_and_migration |
| leaky_delay | checkpoint | fail | fail | expected_fail | processing_checkpoint_restore |
| leaky_delay | isolation | pass | pass | expected_pass | instance_isolation |
| leaky_delay | reset | pass | pass | expected_pass | reset_clean_state |
| leaky_delay | tail | pass | pass | expected_pass | tail_boundedness |
| leaky_delay | perturbation | pass | pass | expected_pass | paired_input_response |
| leaky_delay | cross_process_repeatability | pass | pass | expected_pass | fresh_process_repeatability |
| nan_trigger | nonfinite | fail | fail | expected_fail | non_finite_output |
| nan_trigger | repeatability | pass | pass | expected_pass | fresh_instance_repeatability |
| nan_trigger | partition | pass | pass | expected_pass | static_partition_invariant |
| nan_trigger | reset | pass | pass | expected_pass | reset_clean_state |
| nan_trigger | cross_process_repeatability | pass | pass | expected_pass | fresh_process_repeatability |
| third_party_distortion | nonfinite | pass | pass | expected_pass | non_finite_output |
| third_party_distortion | repeatability | pass | pass | expected_pass | fresh_instance_repeatability |
| third_party_distortion | partition | pass | pass | expected_pass | static_partition_invariant |
| third_party_distortion | automation | pass | pass | expected_pass | automation_partition_invariant_observed |
| third_party_distortion | state | pass | pass | expected_pass | authoring_state_and_migration |
| third_party_distortion | isolation | pass | pass | expected_pass | instance_isolation |
| third_party_distortion | reset | pass | pass | expected_pass | reset_clean_state |
| third_party_distortion | tail | pass | pass | expected_pass | tail_boundedness |
| third_party_distortion | perturbation | pass | pass | expected_pass | paired_input_response |
| third_party_distortion | cross_process_repeatability | pass | pass | expected_pass | fresh_process_repeatability |

## Automation classes observed

- **pulse**: automation_partition_sensitive_control_rate - automation changes across 0 audio and 2 record partition comparisons (observed control-rate class)
- **gain**: automation_partition_sensitive_control_rate - automation changes across 2 audio and 0 record partition comparisons (observed control-rate class)
- **biquad**: automation_partition_sensitive_control_rate - automation changes across 2 audio and 0 record partition comparisons (observed control-rate class)
- **delay**: automation_partition_sensitive_control_rate - automation changes across 2 audio and 0 record partition comparisons (observed control-rate class)
- **third_party_distortion**: automation_partition_invariant_observed - automation output and records are identical across the selected partitions for this schedule

Automation is labelled as a class, not collapsed into pass/fail. The adapter applies a block's parameter events at block start, so sample-timestamped automation is control-rate and partition-sensitive by contract; static parameters remain a separate, strict invariance class.

## Authoring state and migration

- **pulse**: pass - authoring round trip restored 4 parameters; 4 historical fixtures migrated
- **gain**: pass - authoring round trip restored 1 parameters
- **biquad**: pass - authoring round trip restored 2 parameters
- **delay**: pass - authoring round trip restored 3 parameters
- **block_smoother**: pass - authoring round trip restored 1 parameters
- **leaky_delay**: pass - authoring round trip restored 3 parameters
- **third_party_distortion**: pass - authoring round trip restored 3 parameters

## Processing checkpoints (optional capability)

- **pulse**: skip (processing_checkpoint_restore) - specimen reports no processing-checkpoint support
- **biquad**: pass (processing_checkpoint_restore) - checkpoint restore continues the suffix bit-exactly (8192 frames after a 8192-frame prefix)
- **delay**: pass (processing_checkpoint_restore) - checkpoint restore continues the suffix bit-exactly (8192 frames after a 8192-frame prefix)
- **leaky_delay**: fail (processing_checkpoint_restore) - output after a processing checkpoint restore diverges from the uninterrupted run

Authoring state and processing checkpoints are separate contracts. An authoring state that omits a delay line is not defective: it reopens the project settings. Only a plugin that reports checkpoint support is judged on sample-exact continuation.

## Pulse canonical measurement and migration

- Measurement: pass - 32 records match independent peak/RMS/hold references
  - records = 32 
  - expected_records = 32 
  - schema_version = 1 
  - max_sample_peak_abs_diff = 0 amplitude
  - max_rms_abs_diff = 5.06090502839e-10 amplitude
  - max_hold_abs_diff = 0 amplitude
  - peak_frame_mismatches = 0 
  - invalid_records = 0 
  - record_hash_changed_by_perturbation = true 
- State/migration: pass - authoring round trip restored 4 parameters; 4 historical fixtures migrated
  - fixture_schema1_load = ok
  - fixture_schema1_param_1001 = 512
  - fixture_schema1_param_1002 = 0
  - fixture_schema1_param_1003 = 0
  - fixture_schema1_param_1004 = 20
  - fixture_schema1_capture_on = false
  - fixture_schema1_render_hash = 4e64f2fc8d77a2d096a5348c1da5a390f9191d46c72a419fc2e0360e276f5a74
  - fixture_schema2_load = ok
  - fixture_schema2_param_1001 = 256
  - fixture_schema2_param_1002 = 4800
  - fixture_schema2_param_1003 = 1
  - fixture_schema2_param_1004 = 40
  - fixture_schema2_capture_on = false
  - fixture_schema2_render_hash = 4e64f2fc8d77a2d096a5348c1da5a390f9191d46c72a419fc2e0360e276f5a74
  - fixture_schema3-capture-on_load = ok
  - fixture_schema3-capture-on_param_1001 = 1024
  - fixture_schema3-capture-on_param_1002 = 9600
  - fixture_schema3-capture-on_param_1003 = 1
  - fixture_schema3-capture-on_param_1004 = 12.5
  - fixture_schema3-capture-on_capture_on = true
  - fixture_schema3-capture-on_render_hash = 4e64f2fc8d77a2d096a5348c1da5a390f9191d46c72a419fc2e0360e276f5a74
  - fixture_schema3-capture-off_load = ok
  - fixture_schema3-capture-off_param_1001 = 2048
  - fixture_schema3-capture-off_param_1002 = 4800
  - fixture_schema3-capture-off_param_1003 = 0
  - fixture_schema3-capture-off_param_1004 = 20
  - fixture_schema3-capture-off_capture_on = false
  - fixture_schema3-capture-off_render_hash = 4e64f2fc8d77a2d096a5348c1da5a390f9191d46c72a419fc2e0360e276f5a74
- Gap: pass - gap [4096,4608) recorded; first post-gap window at 4608 is the invalid affected window, 22 later windows are audio-valid
- Capture overflow: pass - 4200 windows, 4096 delivered, 104 dropped, capture invalid as expected

## Conclusions and limits

- The small third-party census includes baconpaul/clap-c99-distortion (MIT), built from pinned upstream sources; its sample-offset event handling labels automation partition-invariant, in contrast to the block-start control-rate class.
- The deliberately defective processors failed exactly the classes they were built to violate: block-sensitive smoothing (static partition), an incomplete processing checkpoint (checkpoint restore; its authoring state passes), and NaN generation (non-finite output).
- Good specimens passed their strict invariance, authoring and checkpoint probes where claimed. Pulse automation is recorded as a control-rate class, not a defect.
- Evidence is local Windows x64. CI remains billing-blocked. No universal determinism, real-time or cross-platform claim is made.

## Raw evidence

- Census: census.csv / census.json
- Manifest: manifest.json
- Per-run evidence, inputs, outputs and records: runs/<specimen>/run<N>/
