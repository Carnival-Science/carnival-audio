# Build the graphical Pulse Mini product against a separate Alicorn checkout.
#
# Pulse Mini's default presentation is a native Alicorn window. Alicorn is a
# separate repository (Carnival-Science/Alicorn) and is not vendored here, so
# the build needs an `alicorn` collection:
#
#   odin build products/pulse-mini -collection:carnival=<repo> \
#       -collection:alicorn=<AlicornRoot> <AccessKit linker arguments>
#
# Resolution order for AlicornRoot: -AlicornRoot, PULSE_ALICORN_ROOT, then the
# sibling `alicorn` directory next to carnival-audio. The checkout must include
# the generic host options added on branch `pulse-mini-host-options`
# (`Application.always_on_top` and `Application.on_renderable_changed`); the
# script checks for them instead of accepting a stale checkout silently.
#
# Examples:
#   .\tools\pulse-mini.ps1
#   .\tools\pulse-mini.ps1 -Run --self-loop
#   .\tools\pulse-mini.ps1 -AlicornRoot C:\Users\saman\dev\alicorn -Run --headless --self-loop
param(
    [string]$Odin,
    [string]$AlicornRoot,
    [switch]$Run,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$AppArgs
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$Odin = Resolve-PulseOdin -Requested $Odin
$repoRoot = Get-PulseRepoRoot

# The Alicorn revision this product was developed and verified against. Update
# it when the host contract changes; tools/pulse-mini.ps1 and docs/pulse-mini.md
# are the only places that name the pin.
$PulseAlicornPin = '92cb620'

$AlicornRoot = Resolve-PulseAlicornRoot -Requested $AlicornRoot
if ([string]::IsNullOrWhiteSpace($AlicornRoot)) {
    throw @"
Alicorn checkout not found. The graphical Pulse Mini needs the separate Alicorn
repository with the native host options.

Pass -AlicornRoot <path>, set PULSE_ALICORN_ROOT, or place a checkout next to
this repository as ..\alicorn. Required revision: $PulseAlicornPin.
"@
}

$hostApi = Join-Path $AlicornRoot 'native\sdl_gpu\application_api.odin'
if (-not (Select-String -LiteralPath $hostApi -Pattern 'on_renderable_changed' -Quiet)) {
    throw @"
Alicorn at '$AlicornRoot' does not expose Application.on_renderable_changed.
This product needs the host options from branch `pulse-mini-host-options`
(pin $PulseAlicornPin). Fast-forward that checkout and retry.
"@
}
if (-not (Select-String -LiteralPath $hostApi -Pattern 'always_on_top' -Quiet)) {
    throw "Alicorn at '$AlicornRoot' does not expose Application.always_on_top; pin $PulseAlicornPin is required."
}

$commit = (& git -C $AlicornRoot rev-parse --short HEAD) 2>$null
Write-Host "alicorn: $AlicornRoot ($commit, pin $PulseAlicornPin)"

# AccessKit is resolved by Alicorn's own bootstrap so the compiler arguments
# match the host build. Dot-sourcing keeps the returned object in this process.
. (Join-Path $AlicornRoot 'tools\common.ps1')
$accessKit = Get-AlicornAccessKit

$outputRoot = Join-Path $repoRoot 'out'
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$executable = Join-Path $outputRoot 'pulse-mini.exe'

# `odin check` accepts collections but not linker flags. Keep the AccessKit
# collections for type checking and pass the full set to the build.
$checkArguments = @($accessKit.CompilerArguments | Where-Object { $_ -notmatch '^-extra-linker-flags' })

# Alicorn is not vet-clean across its whole dependency graph (its own tooling
# checks without -vet), so this product's check verifies type/value correctness
# without promoting every imported warning to an error. The carnival packages
# themselves are checked with -vet in tools/build.ps1.
# Native compiler warnings arrive on stderr; keep them out of the build log and
# replay them only when the step actually fails.
$checkLog = Join-Path ([IO.Path]::GetTempPath()) 'pulse-mini-check.log'

# PowerShell 5.1 turns native stderr into a terminating error when
# ErrorActionPreference is Stop. Compiler warnings arrive on stderr, so scope a
# non-terminating preference around the two external invocations and branch on
# the exit code instead.
function Invoke-PulseMiniCompiler {
    param([string[]]$Arguments, [string]$StdErrPath)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & $Odin @Arguments 2> $StdErrPath
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    return $code
}

Write-Host "check products/pulse-mini"
$checkArgumentsAll = @(
    'check', (Join-Path $repoRoot 'products\pulse-mini'),
    "-collection:carnival=$repoRoot", "-collection:alicorn=$AlicornRoot"
) + @($checkArguments) + @('-no-entry-point')
$checkExit = Invoke-PulseMiniCompiler -Arguments $checkArgumentsAll -StdErrPath $checkLog
if ($checkExit -ne 0) {
    Get-Content -LiteralPath $checkLog | Select-Object -Last 40
    exit $checkExit
}

Write-Host "build pulse-mini $executable"
$buildArguments = @(
    'build', (Join-Path $repoRoot 'products\pulse-mini'),
    "-collection:carnival=$repoRoot", "-collection:alicorn=$AlicornRoot"
) + @($accessKit.CompilerArguments) + @("-out:$executable", '-o:minimal')
$buildExit = Invoke-PulseMiniCompiler -Arguments $buildArguments -StdErrPath $checkLog
if ($buildExit -ne 0) {
    Get-Content -LiteralPath $checkLog | Select-Object -Last 40
    exit $buildExit
}

# SDL3 is loaded dynamically; stage its DLL next to the executable for a direct
# launch from out\.
$odinRoot = Split-Path -Parent $Odin
$sdl = Join-Path $odinRoot 'vendor\sdl3\SDL3.dll'
if (-not (Test-Path -LiteralPath $sdl -PathType Leaf)) {
    throw "SDL3.dll not found next to the Odin distribution: '$sdl'."
}
Copy-Item -LiteralPath $sdl -Destination (Join-Path $outputRoot 'SDL3.dll') -Force

Write-Host "build: pulse-mini ok"
if ($Run) {
    & $executable @AppArgs
    exit $LASTEXITCODE
}
exit 0
