# Compile-check every Pulse package. Milestone 0 has no executable entry point;
# this gate proves the public API and tests type-check with vet enabled.
#
# Floating-point contraction: the Odin toolchain used here (dev-2026-11-nightly)
# exposes no -fma/-no-fma flag, so there is no build switch to set. DSP code
# writes explicit multiply/add expressions and never calls an FMA intrinsic; see
# docs/determinism.md.
param(
    [string]$Odin
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$Odin = Resolve-PulseOdin -Requested $Odin
$repoRoot = Get-PulseRepoRoot
$packages = Get-PulsePackages

foreach ($package in $packages) {
    $path = Join-Path $repoRoot $package
    Write-Host "check $package"
    & $Odin check $path "-collection:pulse=$repoRoot" -vet -warnings-as-errors -no-entry-point
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

Write-Host "build: ok ($($packages.Count) packages)"
exit 0
