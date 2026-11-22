# Run the Milestone 0 checks: boundary gate, then every package's @(test)s.
#
# Odin is resolved from -Odin, PULSE_ODIN, the local development path, or PATH.
# The `pulse` collection points at the repository root so packages import each
# other as "pulse:core/...".
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

foreach ($package in $packages) {
    $path = Join-Path $repoRoot $package
    Write-Host "== test $package =="
    & $Odin test $path "-collection:pulse=$repoRoot"
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

Write-Host 'test: all packages passed'
exit 0
