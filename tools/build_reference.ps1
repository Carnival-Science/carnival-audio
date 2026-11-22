# Build the verification reference processors and the worker executable.
#
# Each reference processor is a separate CLAP DLL (one plugin per DSO) built
# from the same `adapters/clap` contract as Pulse. The worker is an ordinary
# executable that loads plugins at runtime; it is not linked against them.
param(
    [string]$Odin
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$Odin = Resolve-PulseOdin -Requested $Odin
$repoRoot = Get-PulseRepoRoot
$outDir = Join-Path $repoRoot 'out\reference'
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

foreach ($plugin in Get-PulseReferencePlugins) {
    $output = Join-Path $outDir $plugin.Output
    Write-Host "build reference $($plugin.Output)"
    & $Odin build (Join-Path $repoRoot $plugin.Package) "-collection:carnival=$repoRoot" `
        -build-mode:dll -out:$output -o:minimal
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

$workerDir = Join-Path $repoRoot 'verification\worker'
if (Test-Path -LiteralPath $workerDir -PathType Container) {
    $workerOut = Join-Path $repoRoot 'out\verify-worker.exe'
    Write-Host "build verification worker"
    & $Odin build $workerDir "-collection:carnival=$repoRoot" -out:$workerOut -o:minimal
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

Write-Host "build: reference processors ok"
exit 0
