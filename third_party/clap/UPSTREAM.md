# CLAP upstream provenance

| Field | Value |
| --- | --- |
| Project | CLAP (CLever Audio Plugin) |
| Repository | https://github.com/free-audio/clap |
| Tag | `1.2.10` |
| Commit | `195b42a004144fab0b3cf95e9c067187d15365b7` |
| Retrieved | 2026-11-22 |
| License | MIT (vendored `LICENSE`) |
| Upstream README | vendored as `README.upstream.md` |

## Why vendor

`adapters/clap` implements the plugin side and `verification/` will act as an
independent host. Both must compile against the *same* protocol declaration.
Vendoring the small MIT header subset makes the C ABI proof tooling
(`tools/abi/abi_probe.c`) reproducible without network access, and pins the
exact layouts that `third_party/clap/abi` mirrors.

The Odin declarations are hand-written against these headers; no generator is
introduced. `tools/abi/abi_probe.c` is compiled with the vendored headers and
its `sizeof`/`offsetof` output is compared against Odin by
`third_party/clap/abi/abi_test.odin`. The calling-convention leg is
`tools/abi/cc_probe.c` + `third_party/clap/abi/cc_test.odin`.

## Vendored header subset

The subset covers the core entry/plugin/host/process/event surface and the
extensions this milestone binds:

```
include/clap/version.h
include/clap/entry.h
include/clap/plugin.h
include/clap/host.h
include/clap/process.h
include/clap/audio-buffer.h
include/clap/events.h
include/clap/id.h
include/clap/stream.h
include/clap/string-sizes.h
include/clap/fixedpoint.h
include/clap/plugin-features.h
include/clap/private/macros.h
include/clap/private/std.h
include/clap/ext/audio-ports.h
include/clap/ext/params.h
include/clap/ext/state.h
include/clap/ext/latency.h
include/clap/ext/thread-check.h
include/clap/ext/tail.h
include/clap/ext/render.h
include/clap/factory/plugin-factory.h
```

`clap/clap.h` and `clap/all.h` are intentionally **not** vendored: they include
extensions outside this subset, so including them here would be misleading. C
probes include the individual headers above.

`vendor/VENDORED.sha256` lists the SHA-256 of every vendored file.

## Upgrade procedure

1. Check out the new upstream tag; record tag and commit in this file.
2. Replace the subset under `vendor/include/clap/`.
3. Regenerate `vendor/VENDORED.sha256`.
4. Update `third_party/clap/abi/*.odin` to match changed C declarations.
5. Run `tools/abi/build.ps1` (or `build.sh`) and the ABI tests. A layout change
   that is not mirrored fails the gate; do not "fix" the C probe.
