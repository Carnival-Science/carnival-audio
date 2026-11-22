# Shared helpers for Pulse's PowerShell tools.
$ErrorActionPreference = 'Stop'

function Resolve-PulseOdin {
    param(
        [AllowNull()]
        [string]$Requested
    )

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($Requested)) { $candidates += $Requested }
    if (-not [string]::IsNullOrWhiteSpace($env:PULSE_ODIN)) { $candidates += $env:PULSE_ODIN }
    # This development machine has a working compiler here while `odin` on PATH
    # is broken; the PATH entry is still tried afterwards for portable setups.
    $candidates += 'C:\odin\odin.exe'
    $candidates += 'odin'

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $hasSeparator = $candidate.Contains([IO.Path]::DirectorySeparatorChar) -or
            $candidate.Contains([IO.Path]::AltDirectorySeparatorChar)
        $resolved = $null
        if ([IO.Path]::IsPathRooted($candidate) -or $hasSeparator) {
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
            $resolved = (Resolve-Path -LiteralPath $candidate).Path
        } else {
            $command = Get-Command -Name $candidate -CommandType Application -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if (-not $command) { continue }
            $resolved = $command.Source
        }

        # A PATH candidate may exist but be a broken shim. Prove it runs.
        & $resolved version *> $null
        if ($LASTEXITCODE -eq 0) {
            return $resolved
        }
    }

    throw @"
Odin was not found or did not run.

Use -Odin <path>, set PULSE_ODIN, or install a working compiler.
Tried: $($candidates -join ', ')
"@
}

function Get-PulseRepoRoot {
    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
}

function Get-PulsePackages {
    return @(
        'core/audio',
        'core/analysis',
        'core/transport',
        'tests'
    )
}
