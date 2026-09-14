#Requires -Version 7.0
#=============================================================================
# tools/ise-report.ps1 -- read existing artifacts and emit a structured report.
#
# report NEVER re-runs a build. It only reads what is already on disk and turns
# it into facts (report.json), so an agent does not have to guess from prose
# logs. Timing is deliberately conservative: a timing.twr that exists is
# reported as NEEDS_REVIEW, never as PASS, unless somebody actually reads it.
#
# Loaded by tools/ise-tools.ps1.
#=============================================================================

if (-not $script:RemoteHost) { throw 'tools/ise-report.ps1 must be loaded through tools/ise-tools.ps1 (remote settings not initialised).' }

# Last integer captured by a pattern (XST prints several summary blocks; the
# final one is the authoritative one).
function Get-MetricLast {
    param([AllowNull()][string]$Text, [Parameter(Mandatory)][string]$Pattern)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $matches = [regex]::Matches($Text, $Pattern)
    if ($matches.Count -eq 0) { return $null }
    $value = $matches[$matches.Count - 1].Groups[1].Value
    if ($value -match '^-?\d+$') { return [int]$value }
    return $null
}

function Get-MatchCount {
    param([AllowNull()][string]$Text, [Parameter(Mandatory)][string]$Pattern)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    return ([regex]::Matches($Text, $Pattern, 'IgnoreCase')).Count
}

#-----------------------------------------------------------------------------
# Synthesis facts from synthesis.srp (+ files next to it)
#-----------------------------------------------------------------------------
function Get-SynthesisFacts {
    param(
        [AllowNull()][string]$ReportText,
        [bool]$NgcExists = $false,
        [AllowNull()]$ExitCode = $null,
        [AllowNull()][string]$ToolFlow = $null
    )
    $errors = Get-MetricLast $ReportText 'Number of errors\s*:\s*(\d+)'
    $warnings = Get-MetricLast $ReportText 'Number of warnings\s*:\s*(\d+)'
    $registers = Get-MetricLast $ReportText '#\s*Registers\s*:\s*(\d+)'
    $io = Get-MetricLast $ReportText '#\s*IOs\s*:\s*(\d+)'
    $latches = Get-MatchCount $ReportText 'latch inferred'
    $multiSource = Get-MatchCount $ReportText 'multi-source|multi-driven'
    $flow = ''
    if ($null -ne $ToolFlow) { $flow = $ToolFlow.Trim() }

    $reportAvailable = -not [string]::IsNullOrEmpty($ReportText)
    $ok = $reportAvailable
    if ($null -eq $errors -or $errors -ne 0) { $ok = $false }
    if ($latches -ne 0) { $ok = $false }
    if ($multiSource -ne 0) { $ok = $false }
    if (-not $NgcExists) { $ok = $false }
    if ($null -eq $ExitCode -or [int]$ExitCode -ne 0) { $ok = $false }
    if ($flow -ne 'COMPLETE') { $ok = $false }

    return [pscustomobject]@{
        Result         = $(if ($ok) { 'PASS' } else { 'FAIL' })
        ReportAvailable = $reportAvailable
        ExitCode       = $ExitCode
        Errors         = $errors
        Warnings       = $warnings
        Latches        = $latches
        MultiSource    = $multiSource
        Registers      = $registers
        Io             = $io
        NgcExists      = $NgcExists
        ToolFlow       = $flow
    }
}

#-----------------------------------------------------------------------------
# Timing facts from timing.twr. First version: presence only, never PASS.
#-----------------------------------------------------------------------------
function Get-TimingFacts {
    param([AllowNull()][string]$TwrText, [bool]$TwrExists = $false)
    if (-not $TwrExists) {
        return [pscustomobject]@{
            Status            = 'NOT_RUN'
            ReportPresent     = $false
            ConstraintsPresent = $false
            WorstSlack        = $null
            Note              = 'timing.twr not present (synth-only run, or the tool flow did not reach trce).'
        }
    }
    $constraintHits = Get-MatchCount $TwrText 'TIMESPEC|TS_|Timing constraint|constraint'
    return [pscustomobject]@{
        Status            = 'NEEDS_REVIEW'
        ReportPresent     = $true
        ConstraintsPresent = ($constraintHits -gt 0)
        WorstSlack        = $null
        Note              = 'A report exists, but this tool does not certify timing: read timing.twr for failed constraints and unconstrained paths by hand.'
    }
}

#-----------------------------------------------------------------------------
# Facts for one build run
#-----------------------------------------------------------------------------
function Get-BuildRunFacts {
    param([Parameter(Mandatory)][string]$ProjectName, [Parameter(Mandatory)][string]$RunId)
    Assert-Name $ProjectName
    if ($RunId -notmatch '^\d{8}-\d{6}-[a-f0-9]{8}$') { throw "Invalid build run id: $RunId" }
    $runDir = Join-Path "$root\projects\$ProjectName\artifacts" $RunId
    if (-not (Test-Path -LiteralPath $runDir -PathType Container)) { throw "Build run not found: $RunId" }

    $results = Join-Path $runDir 'results'
    $meta = $null
    $metaPath = Join-Path $runDir 'run.json'
    if (Test-Path -LiteralPath $metaPath -PathType Leaf) {
        $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
    }
    $stage = 'unknown'
    if ($meta -and $meta.stage) { $stage = [string]$meta.stage }

    $srpText = Get-TextSafe (Join-Path $results 'synthesis.srp')
    $ngc = Test-Path -LiteralPath (Join-Path $results 'design.ngc') -PathType Leaf
    $statusText = Get-TextSafe (Join-Path $results 'run.status')
    $exitCode = Get-IntSafe (Join-Path $results 'synth.exitcode')
    $twrExists = Test-Path -LiteralPath (Join-Path $results 'timing.twr') -PathType Leaf
    $twrText = Get-TextSafe (Join-Path $results 'timing.twr')

    $synthesis = Get-SynthesisFacts -ReportText $srpText -NgcExists $ngc -ExitCode $exitCode -ToolFlow $statusText
    $timing = Get-TimingFacts -TwrText $twrText -TwrExists $twrExists

    $resultsAvailable = (Test-Path -LiteralPath $results -PathType Container)
    return [pscustomobject]@{
        RunId            = $RunId
        RunDir           = $runDir
        Stage            = $stage
        ResultsAvailable = $resultsAvailable
        Status           = $(if ($null -eq $statusText) { 'NOT_AVAILABLE' } else { $statusText.Trim() })
        Synthesis        = $synthesis
        Timing           = $timing
    }
}

function Get-SimulationRunFacts {
    param([Parameter(Mandatory)][string]$ProjectName, [Parameter(Mandatory)][string]$RunId)
    Assert-Name $ProjectName
    if ($RunId -notmatch '^sim-\d{8}-\d{6}-[a-f0-9]{8}$') { throw "Invalid simulation run id: $RunId" }
    $runDir = Join-Path "$root\projects\$ProjectName\artifacts" $RunId
    if (-not (Test-Path -LiteralPath $runDir -PathType Container)) { throw "Simulation run not found: $RunId" }
    $simPath = Join-Path $runDir 'sim.json'
    if (-not (Test-Path -LiteralPath $simPath -PathType Leaf)) {
        return [pscustomobject]@{ RunId = $RunId; RunDir = $runDir; Kind = 'simulation'; Status = 'NOT_AVAILABLE' }
    }
    $sim = Get-Content -LiteralPath $simPath -Raw | ConvertFrom-Json
    return [pscustomobject]@{ RunId = $RunId; RunDir = $runDir; Kind = 'simulation'; Status = 'AVAILABLE'; Simulation = $sim }
}

function Get-VerificationRunFacts {
    param([Parameter(Mandatory)][string]$ProjectName, [Parameter(Mandatory)][string]$RunId)
    Assert-Name $ProjectName
    if ($RunId -notmatch '^verify-\d{8}-\d{6}-[a-f0-9]{8}$') { throw "Invalid verification run id: $RunId" }
    $runDir = Join-Path "$root\projects\$ProjectName\artifacts" $RunId
    if (-not (Test-Path -LiteralPath $runDir -PathType Container)) { throw "Verification run not found: $RunId" }
    $vPath = Join-Path $runDir 'verification.json'
    if (-not (Test-Path -LiteralPath $vPath -PathType Leaf)) {
        return [pscustomobject]@{ RunId = $RunId; RunDir = $runDir; Kind = 'verification'; Status = 'NOT_AVAILABLE' }
    }
    $v = Get-Content -LiteralPath $vPath -Raw | ConvertFrom-Json
    return [pscustomobject]@{ RunId = $RunId; RunDir = $runDir; Kind = 'verification'; Status = 'AVAILABLE'; Verification = $v }
}

#-----------------------------------------------------------------------------
# CLI entry: report -Project <p> (-RunId <id> | -Latest) [-Json]
#-----------------------------------------------------------------------------
function Invoke-Report {
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [string]$RunId,
        [switch]$Latest,
        [switch]$Json
    )
    Assert-Name $ProjectName
    $artifacts = "$root\projects\$ProjectName\artifacts"
    if (-not (Test-Path -LiteralPath $artifacts -PathType Container)) {
        throw "report: no artifacts directory for project '$ProjectName' (nothing has been built or simulated yet)."
    }

    if ($Latest) {
        $ids = @(Get-BuildRunIds $ProjectName)
        if ($ids.Count -eq 0) { throw "report: no build run found for project '$ProjectName'." }
        $RunId = $ids[0]
    }
    if (-not $RunId) { throw 'report: pass -RunId <id> or -Latest.' }

    if ($RunId -match '^sim-') {
        $facts = Get-SimulationRunFacts $ProjectName $RunId
        if ($facts.Status -ne 'AVAILABLE') {
            Write-Host "SIMULATION REPORT: $RunId"
            Write-Host '  sim.json                 NOT_AVAILABLE'
            if ($Json) { [pscustomobject]@{ project = $ProjectName; runId = $RunId; kind = 'simulation'; status = 'NOT_AVAILABLE' } | ConvertTo-Json -Depth 12 }
            throw "report: sim.json is NOT_AVAILABLE for $RunId."
        }
        $sim = $facts.Simulation
        Write-Host "SIMULATION REPORT: $RunId"
        Write-Host '  simulation               : ' $sim.simulation
        Write-Host '  top                      : ' $sim.top
        Write-Host '  fuse exit code           : ' $sim.fuseExitCode
        Write-Host '  simulation exit code     : ' $sim.simulationExitCode
        Write-Host '  run.status               : ' $sim.toolFlow
        Write-Host '  timed out                : ' $sim.timedOut
        Write-Host '  passPattern found        : ' $sim.passPatternFound
        Write-Host '  failPattern found        : ' $sim.failPatternFound
        Write-Host '  result                   : ' $sim.result
        if (@($sim.reasons).Count -gt 0) { Write-Host ('  reasons                  : ' + (@($sim.reasons) -join '; ')) }
        if ($Json) { $sim | ConvertTo-Json -Depth 12 }
        if ($sim.result -ne 'PASS') { throw "report: simulation $RunId is $($sim.result)." }
        return
    }

    if ($RunId -match '^verify-') {
        $facts = Get-VerificationRunFacts $ProjectName $RunId
        if ($facts.Status -ne 'AVAILABLE') {
            Write-Host "VERIFICATION REPORT: $RunId"
            Write-Host '  verification.json        NOT_AVAILABLE'
            if ($Json) { [pscustomobject]@{ project = $ProjectName; runId = $RunId; kind = 'verification'; status = 'NOT_AVAILABLE' } | ConvertTo-Json -Depth 12 }
            throw "report: verification.json is NOT_AVAILABLE for $RunId."
        }
        $v = $facts.Verification
        Write-Host "VERIFICATION REPORT: $RunId"
        Write-Host '  overall                  : ' $v.result
        Write-Host '  stage                    : ' $v.stage
        Write-Host '  synthesis run            : ' $v.synthesisRun
        if ($Json) { $v | ConvertTo-Json -Depth 12 }
        if ($v.result -ne 'PASS') { throw "report: verification $RunId is $($v.result)." }
        return
    }

    # Build run
    $build = Get-BuildRunFacts $ProjectName $RunId
    $report = [ordered]@{
        project          = $ProjectName
        runId            = $build.RunId
        kind             = 'build'
        stage            = $build.Stage
        toolFlow         = $build.Status
        resultsAvailable = $build.ResultsAvailable
        synthesis        = [ordered]@{
            result        = $build.Synthesis.Result
            reportAvailable = $build.Synthesis.ReportAvailable
            exitCode      = $build.Synthesis.ExitCode
            errors        = $build.Synthesis.Errors
            warnings      = $build.Synthesis.Warnings
            latches       = $build.Synthesis.Latches
            multiSource   = $build.Synthesis.MultiSource
            registers     = $build.Synthesis.Registers
            io            = $build.Synthesis.Io
            ngcExists     = $build.Synthesis.NgcExists
        }
        timing           = [ordered]@{
            status             = $build.Timing.Status
            reportPresent      = $build.Timing.ReportPresent
            constraintsPresent = $build.Timing.ConstraintsPresent
            worstSlack         = $build.Timing.WorstSlack
            note               = $build.Timing.Note
        }
        reportPath       = (Join-Path $build.RunDir 'report.json')
    }
    Write-Json (Join-Path $build.RunDir 'report.json') $report

    Write-Host '=================================================='
    Write-Host 'BUILD RUN REPORT'
    Write-Host "Project : $ProjectName"
    Write-Host "Run     : $($build.RunId)   Stage: $($build.Stage)"
    Write-Host '=================================================='
    Write-Host 'Tool flow'
    Write-Host ('  run.status               : ' + $build.Status)
    Write-Host ('  results available        : ' + $build.ResultsAvailable)
    Write-Host 'Synthesis'
    Write-Host ('  XST exit code            : ' + $(if ($null -eq $build.Synthesis.ExitCode) { 'NOT_AVAILABLE' } else { $build.Synthesis.ExitCode }))
    Write-Host ('  errors                   : ' + $(if ($null -eq $build.Synthesis.Errors) { 'NOT_AVAILABLE' } else { $build.Synthesis.Errors }))
    Write-Host ('  warnings                 : ' + $(if ($null -eq $build.Synthesis.Warnings) { 'NOT_AVAILABLE' } else { $build.Synthesis.Warnings }))
    Write-Host ('  latches                  : ' + $build.Synthesis.Latches)
    Write-Host ('  multi-source             : ' + $build.Synthesis.MultiSource)
    Write-Host ('  registers                : ' + $(if ($null -eq $build.Synthesis.Registers) { 'NOT_AVAILABLE' } else { $build.Synthesis.Registers }))
    Write-Host ('  IOs                      : ' + $(if ($null -eq $build.Synthesis.Io) { 'NOT_AVAILABLE' } else { $build.Synthesis.Io }))
    Write-Host ('  design.ngc               : ' + $build.Synthesis.NgcExists)
    Write-Host ('  result                   : ' + $build.Synthesis.Result)
    Write-Host 'Timing'
    Write-Host ('  report present           : ' + $build.Timing.ReportPresent)
    Write-Host ('  constraints present      : ' + $build.Timing.ConstraintsPresent)
    Write-Host ('  worst slack              : ' + $(if ($null -eq $build.Timing.WorstSlack) { 'NOT_PARSED' } else { $build.Timing.WorstSlack }))
    Write-Host ('  status                   : ' + $build.Timing.Status)
    Write-Host ('  note                     : ' + $build.Timing.Note)
    Write-Host ("report.json : " + (Join-Path $build.RunDir 'report.json'))
    if ($Json) { $report | ConvertTo-Json -Depth 12 }

    if (-not $build.ResultsAvailable) { throw "report: results for $($build.RunId) are NOT_AVAILABLE." }
}
