# Run the monorepo checks: boundary gate, then every package's @(test)s.
#
# Odin is resolved from -Odin, PULSE_ODIN, the local development path, or PATH.
# The `carnival` collection points at the repository root so packages import
# each other as "carnival:core/...".
param(
    [string]$Odin
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$Odin = Resolve-PulseOdin -Requested $Odin
$repoRoot = Get-PulseRepoRoot
$packages = Get-PulsePackages

Write-Host "odin: $Odin"
& "$PSScriptRoot\check-boundary.ps1"
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$abiBuild = Join-Path $PSScriptRoot 'abi\build.ps1'
# The CLAP ABI tests compare Odin declarations against a C translation unit
# compiled with the official headers, and drive a C-compiled CLAP plugin. Build
# those probes before running packages when the ABI layer is present.
if (Test-Path -LiteralPath $abiBuild -PathType Leaf) {
    & $abiBuild
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
    $abiOut = Join-Path $repoRoot 'out\abi'
    $env:PULSE_CLAP_ABI_PROBE = Join-Path $abiOut 'abi_probe.txt'
    $env:PULSE_CLAP_CC_PROBE = Join-Path $abiOut 'clap_cc_probe.dll'
}

foreach ($package in $packages) {
    $path = Join-Path $repoRoot $package
    Write-Host "== test $package =="
    # The CLAP entry/factory registry is process-global by design; run tests
    # serially so independent instance tests cannot race entry init/deinit.
    & $Odin test $path "-collection:carnival=$repoRoot" -define:ODIN_TEST_THREADS=1
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

Write-Host 'test: all packages passed'
exit 0
