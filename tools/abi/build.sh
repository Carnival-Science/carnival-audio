#!/bin/sh
# Build the independent C probes used by the CLAP ABI tests (Unix-like).
#
# Outputs into out/abi/ (git-ignored):
#   abi_probe            - C sizeof/offsetof facts
#   libclap_cc_probe.so  - C-compiled CLAP entry/factory/plugin (Linux)
#   libclap_cc_probe.dylib - same on macOS
#
# Set CC to override the compiler (default: cc).
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
out="$root/out/abi"
include="$root/third_party/clap/vendor/include"
draft_include="$root/third_party/clap/draft"
cc=${CC:-cc}

mkdir -p "$out"

echo "abi: compiling C layout probe with $cc"
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -I"$include" -I"$draft_include" \
    "$root/tools/abi/abi_probe.c" -o "$out/abi_probe"

echo "abi: compiling C calling-convention probe with $cc"
case "$(uname -s)" in
    Darwin)
        lib="$out/libclap_cc_probe.dylib"
        "$cc" -std=c11 -O2 -Wall -Wextra -Werror -fPIC -shared -I"$include" -I"$draft_include" \
            "$root/tools/abi/cc_probe.c" -o "$lib"
        ;;
    *)
        lib="$out/libclap_cc_probe.so"
        "$cc" -std=c11 -O2 -Wall -Wextra -Werror -fPIC -shared -I"$include" -I"$draft_include" \
            "$root/tools/abi/cc_probe.c" -o "$lib"
        ;;
esac

echo "abi: probes built in $out"
"$out/abi_probe" > "$out/abi_probe.txt"
echo "PULSE_CLAP_ABI_PROBE=$out/abi_probe.txt"
echo "PULSE_CLAP_CC_PROBE=$lib"
