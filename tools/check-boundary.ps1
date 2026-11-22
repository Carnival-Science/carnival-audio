# Structural boundary gate for the carnival-audio monorepo.
#
# AGENTS.md makes two boundaries non-negotiable:
#
#   core/          may import Odin core: packages and sibling core packages only.
#                  It never imports Alicorn, SDL, miniaudio, a platform audio
#                  backend, CLAP, adapters/, products/ or verification/.
#
#   verification/  may import core record formats but never core/dsp (the
#                  implementation it must verify independently), adapters/,
#                  products/, Alicorn or CLAP. Its numerical references must be
#                  independent; the import boundary makes that structural.
#
# This is intentionally a simple textual gate, not a compiler.
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path

$scopes = @(
    @{
        Name    = 'core'
        Root    = Join-Path $repoRoot 'core'
        Pattern = '(?im)^\s*(?:foreign\s+)?import\s+(?:[A-Za-z_][A-Za-z0-9_]*\s+)?"(?:alicorn[^"]*|vendor:(?:sdl3|miniaudio|wasapi|alsa|coreaudio)[^"]*|[^"]*clap[^"]*|[^"]*verification[^"]*|[^"]*(?:adapters|products)/[^"]*)"'
        Reason  = 'core/ may import only Odin core: packages and sibling core packages.'
    },
    @{
        Name    = 'verification'
        Root    = Join-Path $repoRoot 'verification'
        Pattern = '(?im)^\s*(?:foreign\s+)?import\s+(?:[A-Za-z_][A-Za-z0-9_]*\s+)?"(?:[^"]*core/dsp[^"]*|alicorn[^"]*|vendor:(?:sdl3|miniaudio|wasapi|alsa|coreaudio)[^"]*|[^"]*clap[^"]*|[^"]*(?:adapters|products)/[^"]*)"'
        Reason  = 'verification/ must not import core/dsp, adapters/, products/, Alicorn or CLAP; use independent numerical references.'
    }
)

$counts = @()
$failed = $false
foreach ($scope in $scopes) {
    if (-not (Test-Path -LiteralPath $scope.Root -PathType Container)) {
        throw "$($scope.Name)/ not found at '$($scope.Root)'."
    }
    $files = @(Get-ChildItem -LiteralPath $scope.Root -Recurse -File -Filter '*.odin')
    $found = @()
    foreach ($file in $files) {
        $matches = Select-String -LiteralPath $file.FullName -Pattern $scope.Pattern
        foreach ($match in $matches) {
            $relative = $file.FullName.Substring($repoRoot.Length + 1)
            $found += "${relative}:$($match.LineNumber): $($match.Line.Trim())"
        }
    }
    if ($found.Count -gt 0) {
        Write-Host "Boundary violation: $($scope.Name)/ imports a forbidden package." -ForegroundColor Red
        foreach ($violation in $found) {
            Write-Host "  $violation"
        }
        Write-Host $scope.Reason -ForegroundColor Red
        $failed = $true
    }
    $counts += "$($files.Count) $($scope.Name) files"
}

if ($failed) {
    exit 1
}

Write-Host "check-boundary: ok ($($counts -join ', ') scanned)"
exit 0
