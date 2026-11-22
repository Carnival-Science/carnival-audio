# Shared helpers for the carnival-audio PowerShell tools.
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
    $packages = @(
        'core/stream',
        'core/dsp',
        'core/transport',
        'tests'
    )
    # Optional layers exist only after their milestone commit. Keeping the
    # discovery dynamic lets the CI harness land before those packages without
    # a dead path in the package list.
    foreach ($optional in @('third_party/clap/abi', 'adapters/clap', 'products/pulse')) {
        if (Test-Path -LiteralPath (Join-Path (Get-PulseRepoRoot) $optional) -PathType Container) {
            $packages += $optional
        }
    }
    return $packages
}

# Verification reference processors. Each is its own DLL (one CLAP plugin per
# DSO on this host), built like Pulse from the same adapter.
function Get-PulseReferencePlugins {
    return @(
        @{ Package = 'products/reference/gain';          Output = 'gain.clap' },
        @{ Package = 'products/reference/biquad';        Output = 'biquad.clap' },
        @{ Package = 'products/reference/delay';         Output = 'delay.clap' },
        @{ Package = 'products/reference/block_smoother'; Output = 'block_smoother.clap' },
        @{ Package = 'products/reference/leaky_delay';   Output = 'leaky_delay.clap' },
        @{ Package = 'products/reference/nan_trigger';   Output = 'nan_trigger.clap' }
    )
}

function Get-PulseVerificationPackages {
    return @(
        'verification/host',
        'verification/lab',
        'verification/worker'
    )
}
