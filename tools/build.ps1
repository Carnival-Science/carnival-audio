# Compile-check every package. Milestone 0 has no executable entry point; this
# gate proves the public API and tests type-check with vet enabled.
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
    & $Odin check $path "-collection:carnival=$repoRoot" -vet -warnings-as-errors -no-entry-point
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

Write-Host "build: ok ($($packages.Count) packages)"

# Windows CLAP artifacts are a single DLL whose file name ends in `.clap`; see
# the CLAP entry-point documentation (there is no bundle directory on Windows).
# The exported symbol is `clap_entry`.
$pluginPath = Join-Path $repoRoot 'out\pulse.clap'
Write-Host "build plugin $pluginPath"
& $Odin build (Join-Path $repoRoot 'products\pulse') "-collection:carnival=$repoRoot" `
    -build-mode:dll -define:PULSE_PLUGIN_BUILD=true -out:$pluginPath -o:minimal
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
Write-Host "build: plugin ok"
exit 0
