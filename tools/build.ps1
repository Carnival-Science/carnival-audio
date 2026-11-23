# Compile-check every package. Milestone 0 has no executable entry point; this
# gate proves the public API and tests type-check with vet enabled.
#
# Floating-point contraction: the Odin toolchain used here (dev-2026-11-nightly)
# exposes no -fma/-no-fma flag, so there is no build switch to set. DSP code
# writes explicit multiply/add expressions and never calls an FMA intrinsic; see
# docs/determinism.md.
param(
    [string]$Odin,
    [string]$AlicornRoot
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

# Optional layers: reference processors and the verification laboratory. Each
# reference plugin package is a separate package because one DLL hosts exactly
# one CLAP plugin.
$optionalPackages = @()
foreach ($plugin in Get-PulseReferencePlugins) {
    $optionalPackages += $plugin.Package
}
$optionalPackages += Get-PulseVerificationPackages
foreach ($package in $optionalPackages) {
    $path = Join-Path $repoRoot $package
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        continue
    }
    Write-Host "check $package"
    & $Odin check $path "-collection:carnival=$repoRoot" -vet -warnings-as-errors -no-entry-point
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

Write-Host "build: ok ($($packages.Count) packages + optional)"

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

# Standalone Mini meter (Milestone 3.2a): the pure snapshot-to-visual mapping
# package has no UI dependency and is checked everywhere. The graphical product
# itself needs a separate Alicorn checkout; build it when one is available and
# skip it with a clear notice in headless CI.
$presentationPath = Join-Path $repoRoot 'products\pulse-mini\presentation'
if (Test-Path -LiteralPath $presentationPath -PathType Container) {
    Write-Host "check products/pulse-mini/presentation"
    & $Odin check $presentationPath "-collection:carnival=$repoRoot" -vet -warnings-as-errors -no-entry-point
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}
$resolvedAlicorn = Resolve-PulseAlicornRoot -Requested $AlicornRoot
if ($null -ne $resolvedAlicorn) {
    & "$PSScriptRoot\pulse-mini.ps1" -Odin $Odin -AlicornRoot $resolvedAlicorn
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
} else {
    Write-Host "build: pulse-mini graphical product skipped (no Alicorn checkout; pass -AlicornRoot or set PULSE_ALICORN_ROOT)"
}

# Reference processors and the verification worker. Building them here keeps a
# single entry point for a local laboratory run.
& "$PSScriptRoot\build_reference.ps1" -Odin $Odin
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
exit 0
