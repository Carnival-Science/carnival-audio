# Structural boundary gate for the carnival-audio monorepo.
#
# AGENTS.md makes these boundaries non-negotiable:
#
#   core/          may import Odin core: packages and sibling core packages only.
#                  It never imports Alicorn, SDL, miniaudio, a platform audio
#                  backend, CLAP, third_party/, adapters/, products/ or
#                  verification/.
#
#   verification/  may import core record formats and the neutral CLAP ABI
#                  declarations in third_party/clap, but never core/dsp (the
#                  implementation it must verify independently), adapters/,
#                  products/, Alicorn or a plugin implementation. Sharing the
#                  protocol declaration is fine; sharing the DSP that computes
#                  expected results is not.
#
#   third_party/   is neutral protocol/ABI surface. It may import Odin core:
#                  packages and its own subpackages only; it never imports
#                  core/, adapters/, products/ or verification/.
#
# This is intentionally a simple textual gate, not a compiler.
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path

$importPrefix = '^\s*(?:foreign\s+)?import\s+(?:[A-Za-z_][A-Za-z0-9_]*\s+)?"'

$scopes = @(
    @{
        Name    = 'core'
        Root    = Join-Path $repoRoot 'core'
        Pattern = '(?im)' + $importPrefix + '(?:alicorn[^"]*|vendor:(?:sdl3|miniaudio|wasapi|alsa|coreaudio)[^"]*|[^"]*clap[^"]*|[^"]*third_party/[^"]*|[^"]*verification[^"]*|[^"]*(?:adapters|products)/[^"]*)"'
        Reason  = 'core/ may import only Odin core: packages and sibling core packages.'
    },
    @{
        Name    = 'verification'
        Root    = Join-Path $repoRoot 'verification'
        Pattern = '(?im)' + $importPrefix + '(?:[^"]*core/dsp[^"]*|alicorn[^"]*|vendor:(?:sdl3|miniaudio|wasapi|alsa|coreaudio)[^"]*|[^"]*clap[^"]*|[^"]*(?:adapters|products)/[^"]*)"'
        # Protocol declarations are allowed; plugin implementations are not.
        Allow   = '(?im)' + $importPrefix + '(?:carnival:)?third_party/clap(?:/[^"]*)?"'
        Reason  = 'verification/ must not import core/dsp, adapters/, products/, Alicorn or a CLAP implementation; third_party/clap ABI declarations are allowed.'
    },
    @{
        Name    = 'third_party'
        Root    = Join-Path $repoRoot 'third_party'
        Pattern = '(?im)' + $importPrefix + '(?:alicorn[^"]*|vendor:(?:sdl3|miniaudio|wasapi|alsa|coreaudio)[^"]*|(?:carnival:)?(?:core|adapters|products|verification)/[^"]*)"'
        Reason  = 'third_party/ is neutral ABI surface: it must not import core/, adapters/, products/, verification/ or platform UI/audio libraries.'
    },
    @{
        Name    = 'adapters'
        Root    = Join-Path $repoRoot 'adapters'
        Pattern = '(?im)' + $importPrefix + '(?:alicorn[^"]*|vendor:(?:sdl3|wasapi|alsa|coreaudio)[^"]*|(?:carnival:)?(?:products|verification)/[^"]*)"'
        Reason  = 'adapters/ may import core/, third_party/clap and vendor:miniaudio (the platform capture backend); it must not import products/, verification/, Alicorn or another UI/audio backend.'
    },
    @{
        Name    = 'products'
        Root    = Join-Path $repoRoot 'products'
        Pattern = '(?im)' + $importPrefix + '(?:alicorn[^"]*|vendor:(?:sdl3|miniaudio|wasapi|alsa|coreaudio)[^"]*|(?:carnival:)?verification/[^"]*)"'
        Reason  = 'headless products/ may import adapters/, core/ and third_party/clap; this milestone must not import verification/, Alicorn or a platform UI/audio backend. (Alicorn becomes allowed only for the standalone/editor product in Milestone 3.)'
    }
)

$counts = @()
$failed = $false
foreach ($scope in $scopes) {
    if (-not (Test-Path -LiteralPath $scope.Root -PathType Container)) {
        # Stacked milestone commits may not have created every optional layer
        # yet; the gate applies as soon as the directory exists.
        continue
    }
    $files = @(Get-ChildItem -LiteralPath $scope.Root -Recurse -File -Filter '*.odin')
    $found = @()
    foreach ($file in $files) {
        $matches = Select-String -LiteralPath $file.FullName -Pattern $scope.Pattern
        foreach ($match in $matches) {
            if ($scope.ContainsKey('Allow') -and $match.Line -match $scope.Allow) {
                continue
            }
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
