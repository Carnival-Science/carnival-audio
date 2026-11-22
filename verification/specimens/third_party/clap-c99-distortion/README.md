# Third-party census specimen: clap-c99-distortion

Small third-party CLAP census specimen for the A−1 laboratory. This is not
Carnival code; it is redistributed as a built binary under the upstream MIT
license (`LICENSE.md` beside this file).

| Item | Value |
| --- | --- |
| Upstream | https://github.com/baconpaul/clap-c99-distortion |
| Commit | `fe5b1df477fa705b715ce5a9f3d5e3f08c7492db` (shallow clone, 2026-11-22) |
| Vendored CLAP submodule | `free-audio/clap` `af1e05ce6487151c6b36003fdb47566dbb50194e` |
| License | MIT (see `LICENSE.md`) |
| Plugin id | `org.surge-synth-team.clap-c99-distortion` |
| Version | `1.0.0` |
| Binary | `clap-c99-distortion.clap` |
| SHA-256 | `aff9be7ca8fa87f56ba059f4e29df50d7ebbe7613c355dd7b35cd80487a1eeee` |
| Build platform | Windows x64, MSVC 19.44 / CMake Release |

## Build command

```powershell
git clone --depth 1 https://github.com/baconpaul/clap-c99-distortion.git
cd clap-c99-distortion
git submodule update --init --recursive
cmake -S . -B ignore/bld "-DCMAKE_C_FLAGS=/D_USE_MATH_DEFINES"
cmake --build ignore/bld --config Release
```

`_USE_MATH_DEFINES` is required for MSVC because the upstream source uses
`M_PI` without defining it; this is a build-environment fix, not a source
change. The working tree itself is upstream unmodified.

## Why this specimen

- stereo in / stereo out, three automatable parameters, `clap.state` save/load;
- tiny pure-C source that is easy to audit;
- its process loop applies parameter events at their sample offset, unlike the
  Carnival adapter's documented block-start control-rate application. The
  automation probe therefore observes a different, legitimate class
  (`automation_partition_invariant_observed`) and records it rather than
  forcing agreement.

The binary is a census input, not a compatibility promise. Verification reports
what this build does on the named platform; it does not assert the upstream
project's quality.
