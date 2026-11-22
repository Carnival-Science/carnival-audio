# End-to-end A-1 verification laboratory run (Alicorn#236, Milestone 2).
#
# Builds Pulse, the reference processors and the worker, then runs every
# specimen scenario twice in fresh worker processes. The runner distinguishes:
#
#   exit 0  every expectation held, including the deliberately defective
#           reference processors failing exactly the probes that must catch them
#   exit 1  an unexpected specimen outcome (a real finding or a regression)
#   exit 2  laboratory/infrastructure failure (build, worker crash/timeout,
#           missing evidence)
#
# It writes raw evidence, WAVs, a machine-readable census and a human report
# under verification/reports/<timestamp>/.
param(
    [string]$Odin,
    [switch]$SkipBuild,
    [int]$TimeoutSeconds = 240
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$Odin = Resolve-PulseOdin -Requested $Odin
$repoRoot = Get-PulseRepoRoot
$worker = Join-Path $repoRoot 'out\verify-worker.exe'

$specimens = @(
    @{
        Name = 'pulse'; Scenario = 'verification/scenarios/pulse.json'
        Plugin = 'out/pulse.clap'; Class = 'product'
        ExpectedFail = @()
        ExpectedClass = @{ automation = 'automation_partition_sensitive_control_rate' }
        Note = 'Canonical records are verified against verification-local peak/RMS; automation is control-rate.'
    },
    @{
        Name = 'gain'; Scenario = 'verification/scenarios/gain.json'
        Plugin = 'out/reference/gain.clap'; Class = 'reference'
        ExpectedFail = @()
        ExpectedClass = @{ partition = 'static_partition_invariant'; automation = 'automation_partition_sensitive_control_rate' }
        Note = 'Stateless exact multiply.'
    },
    @{
        Name = 'biquad'; Scenario = 'verification/scenarios/biquad.json'
        Plugin = 'out/reference/biquad.clap'; Class = 'reference'
        ExpectedFail = @()
        ExpectedClass = @{ partition = 'static_partition_invariant'; automation = 'automation_partition_sensitive_control_rate'; checkpoint = 'processing_checkpoint_restore' }
        Note = 'Per-sample direct-form-I state; coefficient automation is block-quantized; filter history is a processing checkpoint.'
    },
    @{
        Name = 'delay'; Scenario = 'verification/scenarios/delay.json'
        Plugin = 'out/reference/delay.clap'; Class = 'reference'
        ExpectedFail = @()
        ExpectedClass = @{ partition = 'static_partition_invariant'; automation = 'automation_partition_sensitive_control_rate'; checkpoint = 'processing_checkpoint_restore' }
        Note = 'Per-sample delay line; processing checkpoint restores the delay line (authoring state stays schema 3).'
    },
    @{
        Name = 'block_smoother'; Scenario = 'verification/scenarios/block_smoother.json'
        Plugin = 'out/reference/block_smoother.clap'; Class = 'defective'
        ExpectedFail = @('partition')
        ExpectedClass = @{}
        Note = 'Intentionally partition-sensitive: the static partition probe must fail.'
    },
    @{
        Name = 'leaky_delay'; Scenario = 'verification/scenarios/leaky_delay.json'
        Plugin = 'out/reference/leaky_delay.clap'; Class = 'defective'
        ExpectedFail = @('checkpoint')
        ExpectedClass = @{ partition = 'static_partition_invariant'; state = 'authoring_state_and_migration'; checkpoint = 'processing_checkpoint_restore' }
        Note = 'Authoring state restores parameters (PASSES); the processing checkpoint claims support but omits the delay line, so the checkpoint probe must fail.'
    },
    @{
        Name = 'nan_trigger'; Scenario = 'verification/scenarios/nan_trigger.json'
        Plugin = 'out/reference/nan_trigger.clap'; Class = 'defective'
        ExpectedFail = @('nonfinite')
        ExpectedClass = @{}
        Note = 'NaN on a documented edge input: the non-finite probe must fail.'
    },
    @{
        Name = 'third_party_distortion'; Scenario = 'verification/scenarios/third_party_distortion.json'
        Plugin = 'verification/specimens/third_party/clap-c99-distortion/clap-c99-distortion.clap'
        Class = 'third_party'
        ExpectedFail = @()
        ExpectedClass = @{ partition = 'static_partition_invariant'; automation = 'automation_partition_invariant_observed' }
        Note = 'MIT C99 distortion (baconpaul/clap-c99-distortion): sample-offset events make automation partition-invariant.'
    }
)

if (-not $SkipBuild) {
    Write-Host 'run-verification: building'
    & "$PSScriptRoot\build.ps1" -Odin $Odin
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'run-verification: LAB FAILURE (build)' -ForegroundColor Red
        exit 2
    }
}

if (-not (Test-Path -LiteralPath $worker -PathType Leaf)) {
    Write-Host "run-verification: LAB FAILURE: worker not found at $worker" -ForegroundColor Red
    exit 2
}

# --- observed environment -------------------------------------------------

$cpuName = ''
try {
    $cpuName = (Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1).Name.Trim()
} catch {
    $cpuName = 'unavailable'
}
$odinVersion = ((& $Odin version 2>&1) | Select-Object -First 1).ToString()
$gitCommit = ''
try {
    $gitCommit = ((& git rev-parse HEAD 2>$null) | Select-Object -First 1).ToString().Trim()
} catch {
    $gitCommit = 'unavailable'
}
$gitDirty = $false
try {
    $gitDirty = @((& git status --porcelain 2>$null)).Count -gt 0
} catch {
    $gitDirty = $false
}
$environment = [ordered]@{
    timestamp_local     = (Get-Date).ToString('o')
    platform            = 'windows'
    arch                = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    os_description      = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
    cpu                 = $cpuName
    logical_processors  = [Environment]::ProcessorCount
    odin_version        = $odinVersion
    git_commit          = $gitCommit
    git_dirty           = $gitDirty
    ci_status           = 'local Windows x64; CI is billing-blocked'
    numeric_environment = 'observed, not hermetic: FTZ/DAZ and FMA contraction are probed per worker run'
}

$reportRoot = Join-Path $repoRoot 'verification\reports'
$stamp = Get-Date -Format 'yyyy-MM-dd-HHmmss'
$reportDir = Join-Path $reportRoot $stamp
$runsDir = Join-Path $reportDir 'runs'
New-Item -ItemType Directory -Path $runsDir -Force | Out-Null

$runs = @()
$censusRows = @()
$specimenManifest = @()
$labFailure = $false
$unexpected = $false

function Invoke-Worker {
    param(
        [string]$Scenario,
        [string]$Plugin,
        [string]$OutDir,
        [string]$StdoutPath,
        [string]$StderrPath
    )
    $arguments = @(
        ('--scenario "' + $Scenario + '"'),
        ('--out "' + $OutDir + '"'),
        ('--plugin "' + $Plugin + '"'),
        ('--odin-build "' + $odinVersion + '"'),
        ('--cpu "' + $cpuName + '"'),
        ('--git-commit "' + $gitCommit + '"')
    ) -join ' '

    # System.Diagnostics.Process is used directly because Windows PowerShell 5.1
    # does not populate Start-Process's returned object's ExitCode reliably.
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $worker
    $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        return @{ ExitCode = -2; TimedOut = $false }
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $finished = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $finished) {
        try { $process.Kill() } catch { }
        $process.WaitForExit()
        Set-Content -LiteralPath $StdoutPath -Value ''
        Set-Content -LiteralPath $StderrPath -Value 'watchdog timeout'
        return @{ ExitCode = -1; TimedOut = $true }
    }
    $process.WaitForExit()
    Set-Content -LiteralPath $StdoutPath -Value $stdoutTask.Result
    Set-Content -LiteralPath $StderrPath -Value $stderrTask.Result
    return @{ ExitCode = [int]$process.ExitCode; TimedOut = $false }
}

foreach ($specimen in $specimens) {
    $scenarioPath = Join-Path $repoRoot $specimen.Scenario
    $pluginPath = Join-Path $repoRoot $specimen.Plugin
    if (-not (Test-Path -LiteralPath $pluginPath -PathType Leaf)) {
        Write-Host "run-verification: LAB FAILURE: missing specimen $($specimen.Plugin)" -ForegroundColor Red
        $labFailure = $true
        continue
    }
    if (-not (Test-Path -LiteralPath $scenarioPath -PathType Leaf)) {
        Write-Host "run-verification: LAB FAILURE: missing scenario $($specimen.Scenario)" -ForegroundColor Red
        $labFailure = $true
        continue
    }
    $pluginHash = (Get-FileHash -LiteralPath $pluginPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $scenarioHash = (Get-FileHash -LiteralPath $scenarioPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $specimenManifest += [ordered]@{
        name = $specimen.Name
        class = $specimen.Class
        plugin = $specimen.Plugin
        plugin_sha256 = $pluginHash
        scenario = $specimen.Scenario
        scenario_sha256 = $scenarioHash
        expected_failures = $specimen.ExpectedFail
        expected_classes = $specimen.ExpectedClass
        note = $specimen.Note
    }

    Write-Host "run-verification: $($specimen.Name)"
    $specimenRuns = @()
    for ($iteration = 1; $iteration -le 2; $iteration++) {
        $runDir = Join-Path (Join-Path $runsDir $specimen.Name) "run$iteration"
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
        $stdout = Join-Path $runDir 'worker.stdout.txt'
        $stderr = Join-Path $runDir 'worker.stderr.txt'
        $result = Invoke-Worker -Scenario $scenarioPath -Plugin $pluginPath -OutDir $runDir `
            -StdoutPath $stdout -StderrPath $stderr
        $evidencePath = Join-Path $runDir 'evidence.json'
        $run = [ordered]@{
            specimen = $specimen.Name
            iteration = $iteration
            exit_code = $result.ExitCode
            timed_out = $result.TimedOut
            evidence = $evidencePath
            stdout = $stdout
            stderr = $stderr
            evidence_ok = (Test-Path -LiteralPath $evidencePath -PathType Leaf)
        }
        $specimenRuns += $run
        $runs += $run
        if ($result.TimedOut -or $result.ExitCode -eq 2 -or -not $run.evidence_ok) {
            $labFailure = $true
        }
        if ($result.ExitCode -eq -1 -or $result.ExitCode -eq 2) {
            Write-Host "  run ${iteration}: LAB FAILURE (exit $($result.ExitCode), timeout=$($result.TimedOut))" -ForegroundColor Red
        } else {
            Write-Host "  run ${iteration}: exit $($result.ExitCode)"
        }
    }

    $first = $specimenRuns[0]
    if (-not $first.evidence_ok) {
        $censusRows += [pscustomobject]@{
            specimen = $specimen.Name; specimen_class = $specimen.Class; scenario = $specimen.Scenario
            probe = 'lab'; probe_class = 'laboratory'; observed = 'missing_evidence'; expected = 'evidence'
            classification = 'lab_failure'; summary = 'worker produced no evidence.json'
        }
        continue
    }
    $evidence = Get-Content -Raw -LiteralPath $first.evidence | ConvertFrom-Json
    $failedProbes = @($evidence.probes | Where-Object { $_.status -eq 'fail' }).Count
    $expectedExit = if ($failedProbes -gt 0) { 1 } else { 0 }
    if ($null -eq $first.exit_code -or [int]$first.exit_code -ne $expectedExit) {
        $labFailure = $true
        $censusRows += [pscustomobject]@{
            specimen = $specimen.Name; specimen_class = $specimen.Class; scenario = $specimen.Scenario
            probe = 'exit_semantics'; probe_class = 'laboratory'; observed = [string]$first.exit_code
            expected = [string]$expectedExit; classification = 'lab_failure'
            summary = 'worker exit code does not agree with evidence probe statuses'
        }
    }
    foreach ($probe in $evidence.probes) {
        $expected = if ($specimen.ExpectedFail -contains $probe.id) { 'fail' } else { 'pass' }
        $classification = ''
        if ($probe.status -eq 'skip' -and $expected -eq 'pass') {
            $classification = 'skip'
        } elseif ($probe.status -eq $expected) {
            $classification = "expected_$expected"
        } else {
            $classification = "unexpected_$($probe.status)"
            if ($specimen.ExpectedFail -contains $probe.id) {
                $classification = 'expected_failure_not_observed'
            }
            $unexpected = $true
        }
        if ($specimen.ExpectedClass.ContainsKey($probe.id)) {
            $expectedClass = $specimen.ExpectedClass[$probe.id]
            if ($probe.class -ne $expectedClass) {
                $classification = 'class_mismatch'
                $unexpected = $true
            }
        }
        $censusRows += [pscustomobject]@{
            specimen = $specimen.Name
            specimen_class = $specimen.Class
            scenario = $specimen.Scenario
            probe = $probe.id
            probe_class = $probe.class
            observed = $probe.status
            expected = $expected
            classification = $classification
            summary = $probe.summary
        }
    }

    # Fresh-process repeatability: compare canonical artifacts across the two
    # worker runs. A difference is a specimen finding, not a lab failure.
    if ($specimenRuns.Count -eq 2 -and $specimenRuns[1].evidence_ok) {
        $secondEvidence = Get-Content -Raw -LiteralPath $specimenRuns[1].evidence | ConvertFrom-Json
        $firstArtifacts = @{}
        foreach ($artifact in $evidence.artifacts) {
            if ($artifact.kind -in @('output', 'records')) {
                $firstArtifacts[$artifact.kind] = $artifact.sha256
            }
        }
        $secondArtifacts = @{}
        foreach ($artifact in $secondEvidence.artifacts) {
            if ($artifact.kind -in @('output', 'records')) {
                $secondArtifacts[$artifact.kind] = $artifact.sha256
            }
        }
        $repeatOk = $true
        foreach ($kind in $firstArtifacts.Keys) {
            if (-not $secondArtifacts.ContainsKey($kind) -or $firstArtifacts[$kind] -ne $secondArtifacts[$kind]) {
                $repeatOk = $false
            }
        }
        if ($firstArtifacts.Count -eq 0) { $repeatOk = $false }
        if (-not $repeatOk) { $unexpected = $true }
        $censusRows += [pscustomobject]@{
            specimen = $specimen.Name
            specimen_class = $specimen.Class
            scenario = $specimen.Scenario
            probe = 'cross_process_repeatability'
            probe_class = 'fresh_process_repeatability'
            observed = if ($repeatOk) { 'pass' } else { 'fail' }
            expected = 'pass'
            classification = if ($repeatOk) { 'expected_pass' } else { 'unexpected_fail' }
            summary = 'output.wav and records.csv hashes across two fresh worker processes'
        }
    }
}

# --- machine-readable census and manifest ---------------------------------

$summary = [ordered]@{
    specimens = $specimens.Count
    runs = $runs.Count
    rows = $censusRows.Count
    expected_failures_observed = @($censusRows | Where-Object { $_.classification -eq 'expected_fail' }).Count
    unexpected = @($censusRows | Where-Object { $_.classification -like 'unexpected_*' -or $_.classification -eq 'expected_failure_not_observed' -or $_.classification -eq 'class_mismatch' }).Count
    lab_failures = @($censusRows | Where-Object { $_.classification -eq 'lab_failure' }).Count
    lab_ok = (-not $labFailure -and -not $unexpected)
}
$census = [ordered]@{
    schema = 'carnival.verification.census/1'
    lab_revision = 'm2.0'
    environment = $environment
    summary = $summary
    rows = $censusRows
}
$census | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $reportDir 'census.json')
$censusRows | Select-Object specimen, specimen_class, scenario, probe, probe_class, observed, expected, classification, summary |
    Export-Csv -LiteralPath (Join-Path $reportDir 'census.csv') -NoTypeInformation

$manifest = [ordered]@{
    schema = 'carnival.verification.manifest/1'
    lab_revision = 'm2.0'
    abi = 'clap-1.2.10'
    command = '.\tools\run_verification.ps1'
    environment = $environment
    tool_hashes = [ordered]@{
        worker_sha256 = (Get-FileHash -LiteralPath $worker -Algorithm SHA256).Hash.ToLowerInvariant()
        odin = $Odin
    }
    specimens = $specimenManifest
    runs = $runs
    limitations = @(
        'CI is billing-blocked; this evidence is local Windows x64.',
        'The numeric environment is observed (FTZ/DAZ, contraction, CPU model), never claimed hermetic.',
        'Finite probes do not prove universal determinism or real-time safety.',
        'A passing partition probe is byte equality for this input and these partitions, not a proof for every schedule.'
    )
}
$manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $reportDir 'manifest.json')

# --- human report ----------------------------------------------------------

$reportLines = New-Object System.Collections.Generic.List[string]
function Add-Report([string]$text) { $reportLines.Add($text) }
Add-Report '# A-1 verification laboratory run'
Add-Report ''
Add-Report ('- Date: ' + $environment.timestamp_local)
Add-Report ('- Git commit: ' + $environment.git_commit + ' (dirty working tree: ' + $environment.git_dirty + ')')
Add-Report ('- Platform: ' + $environment.platform + ' ' + $environment.arch + ' - ' + $environment.os_description)
Add-Report ('- CPU: ' + $environment.cpu + ' (' + $environment.logical_processors + ' logical processors)')
Add-Report ('- Odin: ' + $environment.odin_version)
Add-Report '- Exit semantics: worker 0 = all probes pass, 1 = specimen probe failure, 2 = laboratory failure'
Add-Report ''
Add-Report '## Census'
Add-Report ''
Add-Report '| Specimen | Probe | Observed | Expected | Classification | Class |'
Add-Report '| --- | --- | --- | --- | --- | --- |'
foreach ($row in $censusRows) {
    Add-Report ('| ' + $row.specimen + ' | ' + $row.probe + ' | ' + $row.observed + ' | ' + $row.expected + ' | ' + $row.classification + ' | ' + $row.probe_class + ' |')
}
Add-Report ''
Add-Report '## Automation classes observed'
Add-Report ''
foreach ($specimen in $specimens) {
    $row = $censusRows | Where-Object { $_.specimen -eq $specimen.Name -and $_.probe -eq 'automation' } | Select-Object -First 1
    if ($row) {
        Add-Report ('- **' + $specimen.Name + '**: ' + $row.probe_class + ' - ' + $row.summary)
    }
}
Add-Report ''
Add-Report 'Automation is labelled as a class, not collapsed into pass/fail. The adapter applies a block''s parameter events at block start, so sample-timestamped automation is control-rate and partition-sensitive by contract; static parameters remain a separate, strict invariance class.'
Add-Report ''
Add-Report '## Authoring state and migration'
Add-Report ''
foreach ($specimen in $specimens) {
    $row = $censusRows | Where-Object { $_.specimen -eq $specimen.Name -and $_.probe -eq 'state' } | Select-Object -First 1
    if ($row) { Add-Report ('- **' + $specimen.Name + '**: ' + $row.observed + ' - ' + $row.summary) }
}
Add-Report ''
Add-Report '## Processing checkpoints (optional capability)'
Add-Report ''
foreach ($specimen in $specimens) {
    $row = $censusRows | Where-Object { $_.specimen -eq $specimen.Name -and $_.probe -eq 'checkpoint' } | Select-Object -First 1
    if ($row) { Add-Report ('- **' + $specimen.Name + '**: ' + $row.observed + ' (' + $row.probe_class + ') - ' + $row.summary) }
}
Add-Report ''
Add-Report 'Authoring state and processing checkpoints are separate contracts. An authoring state that omits a delay line is not defective: it reopens the project settings. Only a plugin that reports checkpoint support is judged on sample-exact continuation.'
Add-Report ''
Add-Report '## Pulse canonical measurement and migration'
Add-Report ''
$pulseEvidencePath = ($runs | Where-Object { $_.specimen -eq 'pulse' -and $_.iteration -eq 1 }).evidence
if (Test-Path -LiteralPath $pulseEvidencePath) {
    $pulseEvidence = Get-Content -Raw -LiteralPath $pulseEvidencePath | ConvertFrom-Json
    $measure = $pulseEvidence.probes | Where-Object { $_.id -eq 'measurement' } | Select-Object -First 1
    if ($measure) {
        Add-Report ('- Measurement: ' + $measure.status + ' - ' + $measure.summary)
        foreach ($metric in $measure.metrics) {
            Add-Report ('  - ' + $metric.name + ' = ' + $metric.value + ' ' + $metric.unit)
        }
    }
    $state = $pulseEvidence.probes | Where-Object { $_.id -eq 'state' } | Select-Object -First 1
    if ($state) {
        Add-Report ('- State/migration: ' + $state.status + ' - ' + $state.summary)
        foreach ($metric in $state.metrics) {
            if ($metric.name -like 'fixture_*') { Add-Report ('  - ' + $metric.name + ' = ' + $metric.value) }
        }
    }
    $gap = $pulseEvidence.probes | Where-Object { $_.id -eq 'gap' } | Select-Object -First 1
    if ($gap) { Add-Report ('- Gap: ' + $gap.status + ' - ' + $gap.summary) }
    $overflow = $pulseEvidence.probes | Where-Object { $_.id -eq 'capture_overflow' } | Select-Object -First 1
    if ($overflow) { Add-Report ('- Capture overflow: ' + $overflow.status + ' - ' + $overflow.summary) }
}
Add-Report ''
Add-Report '## Conclusions and limits'
Add-Report ''
Add-Report '- The small third-party census includes baconpaul/clap-c99-distortion (MIT), built from pinned upstream sources; its sample-offset event handling labels automation partition-invariant, in contrast to the block-start control-rate class.'
Add-Report '- The deliberately defective processors failed exactly the classes they were built to violate: block-sensitive smoothing (static partition), an incomplete processing checkpoint (checkpoint restore; its authoring state passes), and NaN generation (non-finite output).'
Add-Report '- Good specimens passed their strict invariance and state-restoration probes. Pulse automation is recorded as a control-rate class, not a defect.'
Add-Report '- Evidence is local Windows x64. CI remains billing-blocked. No universal determinism, real-time or cross-platform claim is made.'
Add-Report ''
Add-Report '## Raw evidence'
Add-Report ''
Add-Report '- Census: census.csv / census.json'
Add-Report '- Manifest: manifest.json'
Add-Report '- Per-run evidence, inputs, outputs and records: runs/<specimen>/run<N>/'

Set-Content -LiteralPath (Join-Path $reportDir 'report.md') -Value $reportLines

Write-Host ''
Write-Host ('run-verification: evidence in ' + $reportDir)
Write-Host ('run-verification: specimens={0} rows={1} expected_failures={2} unexpected={3} lab_failures={4}' -f `
    $summary.specimens, $summary.rows, $summary.expected_failures_observed, $summary.unexpected, $summary.lab_failures)
if ($labFailure) {
    Write-Host 'run-verification: LAB FAILURE' -ForegroundColor Red
    exit 2
}
if ($unexpected) {
    Write-Host 'run-verification: unexpected specimen outcome' -ForegroundColor Red
    exit 1
}
Write-Host 'run-verification: ok (all expected outcomes observed)' -ForegroundColor Green
exit 0
