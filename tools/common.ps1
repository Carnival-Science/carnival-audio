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
        'core/meter',
        'tests'
    )
    # Optional layers exist only after their milestone commit. Keeping the
    # discovery dynamic lets the CI harness land before those packages without
    # a dead path in the package list.
    foreach ($optional in @('third_party/clap/abi', 'adapters/clap', 'adapters/wasapi', 'products/pulse', 'products/pulse-mini/presentation')) {
        if (Test-Path -LiteralPath (Join-Path (Get-PulseRepoRoot) $optional) -PathType Container) {
            $packages += $optional
        }
    }
    return $packages
}

# Pulse Mini's graphical product needs an Alicorn checkout. Alicorn is a
# separate repository (Carnival-Science/Alicorn); carnival-audio does not vendor
# it. Resolution order: an explicit -AlicornRoot, PULSE_ALICORN_ROOT, then the
# sibling `alicorn` directory. Returns $null when none is available, so headless
# CI can still run the rest of the repository.
function Resolve-PulseAlicornRoot {
    param(
        [AllowNull()]
        [string]$Requested
    )

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($Requested)) { $candidates += $Requested }
    if (-not [string]::IsNullOrWhiteSpace($env:PULSE_ALICORN_ROOT)) { $candidates += $env:PULSE_ALICORN_ROOT }
    $candidates += (Join-Path (Split-Path -Parent (Get-PulseRepoRoot)) 'alicorn')

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }
        $resolved = (Resolve-Path -LiteralPath $candidate).Path
        # These files carry the pins this milestone needs: the native host and
        # the beginner-facing run API. Tests and builds fail with a clear
        # message if the checkout predates them.
        $hostFile = Join-Path $resolved 'native\sdl_gpu\application_api.odin'
        $runFile = Join-Path $resolved 'ui\run_native.odin'
        if ((Test-Path -LiteralPath $hostFile -PathType Leaf) -and (Test-Path -LiteralPath $runFile -PathType Leaf)) {
            return $resolved
        }
    }
    return $null
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
