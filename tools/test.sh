#!/bin/sh
# Portable headless test harness (Linux/macOS), mirroring tools/test.ps1.
#
# Odin is resolved from PULSE_ODIN or PATH. The `carnival` collection points at
# the repository root so packages import each other as "carnival:core/...".
#
# The boundary gate is the single PowerShell source of truth
# (tools/check-boundary.ps1) executed with pwsh, which is preinstalled on the
# GitHub-hosted Linux/macOS runners. This keeps one rule set for all three OSes
# instead of a second, drifting shell reimplementation.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

odin=${PULSE_ODIN:-}
if [ -z "$odin" ]; then
    if [ -x /c/odin/odin.exe ]; then
        odin=/c/odin/odin.exe
    elif command -v odin >/dev/null 2>&1; then
        odin=$(command -v odin)
    else
        echo "Odin was not found. Set PULSE_ODIN or install it on PATH." >&2
        exit 1
    fi
fi

if ! "$odin" version >/dev/null 2>&1; then
    echo "Odin at '$odin' did not run." >&2
    exit 1
fi

echo "odin: $odin"

pwsh_bin=$(command -v pwsh || true)
if [ -z "$pwsh_bin" ]; then
    echo "pwsh is required to run the shared boundary gate (tools/check-boundary.ps1)." >&2
    exit 1
fi
"$pwsh_bin" -NoProfile -File "$root/tools/check-boundary.ps1"

if [ -f "$root/tools/abi/build.sh" ]; then
    sh "$root/tools/abi/build.sh"
    case "$(uname -s)" in
        Darwin) export PULSE_CLAP_CC_PROBE="$root/out/abi/libclap_cc_probe.dylib" ;;
        *)      export PULSE_CLAP_CC_PROBE="$root/out/abi/libclap_cc_probe.so" ;;
    esac
    export PULSE_CLAP_ABI_PROBE="$root/out/abi/abi_probe.txt"
fi

packages="core/stream core/dsp core/transport core/meter tests"
for optional in third_party/clap/abi adapters/clap adapters/wasapi products/pulse; do
    if [ -d "$root/$optional" ]; then
        packages="$packages $optional"
    fi
done
for package in $packages; do
    echo "== test $package =="
    # The CLAP entry/factory registry is process-global by design; keep test
    # execution serial so independent instance tests cannot race init/deinit.
    "$odin" test "$root/$package" "-collection:carnival=$root" -define:ODIN_TEST_THREADS=1
done

echo 'test: all packages passed'
