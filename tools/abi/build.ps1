# Build the independent C probes used by the CLAP ABI tests.
#
# Outputs into out/abi/ (git-ignored):
#   abi_probe.exe        - prints C sizeof/offsetof facts (Windows)
#   clap_cc_probe.dll    - C-compiled CLAP entry/factory/plugin for the calling
#                          convention test (Windows)
#
# The build is intentionally external to the Odin build: the point is that the
# numbers and the function pointers come from a C translation unit compiled
# against the official headers, not from Odin.
param(
    [string]$OutDir = (Join-Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path 'out\abi')
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$include = Join-Path $repoRoot 'third_party\clap\vendor\include'
$draftInclude = Join-Path $repoRoot 'third_party\clap\draft'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$probeExe = Join-Path $OutDir 'abi_probe.exe'
$probeDll = Join-Path $OutDir 'clap_cc_probe.dll'

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw 'vswhere.exe was not found; install the MSVC C++ build tools.'
}
$installation = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ([string]::IsNullOrWhiteSpace($installation)) {
    throw 'No Visual Studio installation with MSVC x64 tools was found.'
}
$vcvars = Join-Path $installation 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path -LiteralPath $vcvars)) {
    throw "vcvars64.bat not found under '$installation'."
}

$common = "/nologo /std:c11 /W4 /WX /I`"$include`" /I`"$draftInclude`""
$exeCmd = "call `"$vcvars`" >nul && cl $common `"$PSScriptRoot\abi_probe.c`" /Fe:`"$probeExe`""
Write-Host "abi: compiling C layout probe"
Push-Location -LiteralPath $OutDir
try {
    & cmd.exe /d /s /c $exeCmd
} finally {
    Pop-Location
}
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$dllCmd = "call `"$vcvars`" >nul && cl $common /LD `"$PSScriptRoot\cc_probe.c`" /link /out:`"$probeDll`" /IMPLIB:`"$OutDir\clap_cc_probe.lib`""
Write-Host "abi: compiling C calling-convention probe"
Push-Location -LiteralPath $OutDir
try {
    & cmd.exe /d /s /c $dllCmd
} finally {
    Pop-Location
}
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "abi: probes built in $OutDir"
$facts = Join-Path $OutDir 'abi_probe.txt'
& $probeExe | Set-Content -LiteralPath $facts -Encoding Ascii
Write-Host "PULSE_CLAP_ABI_PROBE=$facts"
Write-Host "PULSE_CLAP_CC_PROBE=$probeDll"
exit 0
