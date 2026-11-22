# Boundary gate for core/.
#
# AGENTS.md makes the source-independent boundary non-negotiable: core/ may use
# Odin core: packages only, never Alicorn, SDL, miniaudio, CLAP, or a platform
# audio backend. This is intentionally a simple textual gate, not a compiler.
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$coreRoot = Join-Path $repoRoot 'core'
if (-not (Test-Path -LiteralPath $coreRoot -PathType Container)) {
    throw "core/ not found at '$coreRoot'."
}

$files = Get-ChildItem -LiteralPath $coreRoot -Recurse -File -Filter '*.odin'
$pattern = '(?im)^\s*(?:foreign\s+)?import\s+(?:[A-Za-z_][A-Za-z0-9_]*\s+)?"(?:alicorn[^"]*|vendor:(?:sdl3|miniaudio|wasapi|alsa|coreaudio)[^"]*|[^"]*clap[^"]*)"'
$violations = @()
foreach ($file in $files) {
    $matches = Select-String -LiteralPath $file.FullName -Pattern $pattern
    foreach ($match in $matches) {
        $relative = $file.FullName.Substring($repoRoot.Length + 1)
        $violations += "${relative}:$($match.LineNumber): $($match.Line.Trim())"
    }
}

if ($violations.Count -gt 0) {
    Write-Host 'Boundary violation: core/ imports a forbidden package.' -ForegroundColor Red
    foreach ($violation in $violations) {
        Write-Host "  $violation"
    }
    Write-Host 'core/ may import only Odin core: packages and Pulse core packages.' -ForegroundColor Red
    exit 1
}

Write-Host "check-boundary: ok ($($files.Count) core files scanned)"
exit 0
