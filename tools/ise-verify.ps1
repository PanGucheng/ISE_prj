#Requires -Version 7.0
#=============================================================================
# tools/ise-verify.ps1 -- static design rules, verification orchestration and
# the (reserved) board-check entry.
#
# verify runs, in order:
#   1. configuration gate            (Read-Project)
#   2. static checks                 (Verilog-2001, single clock domain, no
#                                     invented constraints, referenced files)
#   3. synthesis                     (build -Stage synth, then parse the report)
#   4. every enabled simulation      (tools/ise-sim.ps1)
#   5. implementation gate           (expected-vs-actual block, from config)
#   6. verification.json + summary.txt + console report
#
# The implementation gate is driven by project.json:
#   "verification": { "expectImplementationBlocked": true }
# so no project-specific special cases live in this file.
#
# Loaded by tools/ise-tools.ps1.
#=============================================================================

if (-not $script:RemoteHost) { throw 'tools/ise-verify.ps1 must be loaded through tools/ise-tools.ps1 (remote settings not initialised).' }

#-----------------------------------------------------------------------------
# Comment-aware scanners. Keywords inside comments must never be reported as
# violations, and keywords in real code must never be excused as comments.
# (Naive on string literals containing "//"; no RTL here relies on that.)
#-----------------------------------------------------------------------------
function Remove-VerilogComments([AllowNull()][string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = [regex]::Replace($Text, '(?s)/\*.*?\*/', ' ')
    return [regex]::Replace($t, '//[^\r\n]*', ' ')
}

function Remove-UcfComments([AllowNull()][string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return [regex]::Replace($Text, '#[^\r\n]*', ' ')
}

#-----------------------------------------------------------------------------
# Static checks. Returns PASS/FAIL plus INFO/WARNING/ERROR item lists.
#-----------------------------------------------------------------------------
function Get-StaticCheckFacts {
    param(
        [Parameter(Mandatory)]$ProjectData,
        [string]$ClockName = 'clk',
        [string[]]$ResetNames = @('rst_n', 'rst_n_sync'),
        # Signals that must never appear in an edge list (posedge/negedge).
        # A top-level output such as audio_out is a legitimate net, so this is
        # deliberately NOT a "signal must not exist" list.
        [string[]]$ForbiddenEdgeSignals = @('clk_2m', 'audio_out'),
        # Optional opt-in list of signals that must not appear in RTL code at all.
        [string[]]$ForbiddenSignals = @(),
        [string[]]$AllowExtraEdgeSignals = @()
    )
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $infos = New-Object System.Collections.Generic.List[string]
    $cfg = $ProjectData.Config

    $svPattern = '\b(always_ff|always_comb|always_latch|typedef|enum|interface|logic|bit|byte|shortint|longint|automatic)\b'

    # ---- RTL sources and include files -------------------------------------
    $rtlFiles = New-Object System.Collections.Generic.List[string]
    foreach ($s in $cfg.sources) { $rtlFiles.Add([string]$s.path) }
    foreach ($f in $cfg.includeFiles) { if ($f) { $rtlFiles.Add([string]$f) } }
    $rtlFiles = @($rtlFiles | Sort-Object -Unique)

    foreach ($rel in $rtlFiles) {
        $path = Join-Path $ProjectData.Directory $rel
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $errors.Add("[ERROR] FILE_MISSING $rel referenced by project.json but not found")
            continue
        }
        $raw = [IO.File]::ReadAllText($path)
        $code = Remove-VerilogComments $raw

        foreach ($m in [regex]::Matches($code, 'for\s*\(\s*genvar')) {
            $errors.Add("[ERROR] GENVAR $rel 'for (genvar ...)' is not Verilog-2001; declare 'genvar i;' separately")
        }
        foreach ($m in [regex]::Matches($code, $svPattern)) {
            $errors.Add("[ERROR] SV_KEYWORD $rel SystemVerilog keyword '$($m.Value)' is not supported by this toolchain")
        }
        foreach ($m in [regex]::Matches($code, '\b(posedge|negedge)\s+([A-Za-z_][A-Za-z0-9_]*)')) {
            $edge = $m.Groups[1].Value
            $signal = $m.Groups[2].Value
            if ($ForbiddenEdgeSignals -contains $signal) {
                $errors.Add("[ERROR] FORBIDDEN_CLOCK $rel '$edge $signal' uses a signal that must never drive an edge (no second clock domain)")
            } elseif ($edge -eq 'posedge') {
                if ($signal -ne $ClockName -and ($AllowExtraEdgeSignals -notcontains $signal)) {
                    $errors.Add("[ERROR] CLOCK_EDGE $rel 'posedge $signal' would create a clock other than '$ClockName' (single clock domain rule)")
                }
            } else {
                if (($ResetNames -notcontains $signal) -and ($AllowExtraEdgeSignals -notcontains $signal)) {
                    $errors.Add("[ERROR] CLOCK_EDGE $rel 'negedge $signal' is not a declared reset ($($ResetNames -join ', '))")
                }
            }
        }
        foreach ($bad in $ForbiddenSignals) {
            if ($bad -and $code -match ('\b' + [regex]::Escape($bad) + '\b')) {
                $errors.Add("[ERROR] FORBIDDEN_SIGNAL $rel forbidden signal '$bad' used in RTL code")
            }
        }
        foreach ($bad in @($ForbiddenEdgeSignals + $ForbiddenSignals | Where-Object { $_ } | Sort-Object -Unique)) {
            if ($raw -match ('\b' + [regex]::Escape($bad) + '\b') -and -not ($code -match ('\b' + [regex]::Escape($bad) + '\b'))) {
                $infos.Add("[INFO] COMMENT_ONLY $rel '$bad' appears in comments only")
            }
        }
        if ($code -match '\b(BUFG|BUFGMUX|DCM_SP|DCM_BASE|PLL_BASE|PLL_ADV)\b') {
            $warnings.Add("[WARNING] CLOCK_PRIMITIVE $rel clock buffer / DCM / PLL primitive instantiated; confirm this is intended")
        }
    }

    # ---- project flags -----------------------------------------------------
    if ($cfg.constraintsReviewed -isnot [bool]) {
        $errors.Add('[ERROR] CONSTRAINTS_FLAG project.json "constraintsReviewed" must be a JSON boolean (true/false)')
    }

    # ---- UCF: never invent constraints while unreviewed ---------------------
    if ($cfg.ucf) {
        $ucfPath = Join-Path $ProjectData.Directory ([string]$cfg.ucf)
        if (-not (Test-Path -LiteralPath $ucfPath -PathType Leaf)) {
            $errors.Add("[ERROR] FILE_MISSING $($cfg.ucf) referenced by project.json but not found")
        } else {
            $lineNo = 0
            foreach ($line in [IO.File]::ReadAllLines($ucfPath)) {
                $lineNo++
                $active = (Remove-UcfComments $line).Trim()
                if ([string]::IsNullOrEmpty($active)) { continue }
                if ($active -match '\bLOC\b') {
                    if ($cfg.constraintsReviewed -eq $true) {
                        $infos.Add("[INFO] UCF_LOC $($cfg.ucf):$lineNo LOC present in a reviewed design")
                    } else {
                        $errors.Add("[ERROR] UCF_LOC $($cfg.ucf):$lineNo active LOC while constraintsReviewed=false (pins must never be invented)")
                    }
                } elseif ($active -match '\b(IOSTANDARD|TIMESPEC|TNM_NET|OFFSET|PULLUP|DRIVE|CONFIG)\b') {
                    if ($cfg.constraintsReviewed -eq $true) {
                        $infos.Add("[INFO] UCF_CONSTRAINT $($cfg.ucf):$lineNo active constraint in a reviewed design")
                    } else {
                        $warnings.Add("[WARNING] UCF_CONSTRAINT $($cfg.ucf):$lineNo active constraint while constraintsReviewed=false")
                    }
                }
            }
        }
    }

    # ---- every referenced file exists --------------------------------------
    $referenced = New-Object System.Collections.Generic.List[string]
    foreach ($s in $cfg.sources) { $referenced.Add([string]$s.path) }
    foreach ($f in $cfg.includeFiles) { if ($f) { $referenced.Add([string]$f) } }
    foreach ($f in $cfg.netlists) { if ($f) { $referenced.Add([string]$f) } }
    if ($cfg.ucf) { $referenced.Add([string]$cfg.ucf) }
    if ($cfg.PSObject.Properties['simulations']) {
        foreach ($sim in @($cfg.simulations)) {
            foreach ($f in @($sim.sources)) { if ($f) { $referenced.Add([string]$f) } }
        }
    }
    foreach ($rel in @($referenced | Sort-Object -Unique)) {
        if (-not (Test-Path -LiteralPath (Join-Path $ProjectData.Directory $rel) -PathType Leaf)) {
            $errors.Add("[ERROR] FILE_MISSING $rel referenced by project.json but not found")
        }
    }

    return [pscustomobject]@{
        Result   = $(if ($errors.Count -eq 0) { 'PASS' } else { 'FAIL' })
        Errors   = @($errors | Sort-Object -Unique)
        Warnings = @($warnings | Sort-Object -Unique)
        Infos    = @($infos | Sort-Object -Unique)
    }
}

function Invoke-StaticChecks {
    param([Parameter(Mandatory)][string]$ProjectName)
    $p = Read-Project $ProjectName 'synth'
    $clockName = 'clk'
    $resetNames = @('rst_n', 'rst_n_sync')
    $forbiddenEdge = @('clk_2m', 'audio_out')
    $forbiddenSignals = @()
    $allowExtra = @()
    $v = $p.Config.PSObject.Properties['verification']
    if ($v -and $v.Value) {
        $ver = $v.Value
        if ($ver.PSObject.Properties['clockName'] -and $ver.clockName) { $clockName = [string]$ver.clockName }
        if ($ver.PSObject.Properties['resetNames'] -and $ver.resetNames) { $resetNames = @($ver.resetNames | ForEach-Object { [string]$_ }) }
        if ($ver.PSObject.Properties['forbiddenEdgeSignals'] -and $ver.forbiddenEdgeSignals) { $forbiddenEdge = @($ver.forbiddenEdgeSignals | ForEach-Object { [string]$_ }) }
        if ($ver.PSObject.Properties['forbiddenSignals'] -and $ver.forbiddenSignals) { $forbiddenSignals = @($ver.forbiddenSignals | ForEach-Object { [string]$_ }) }
        if ($ver.PSObject.Properties['allowExtraEdgeSignals'] -and $ver.allowExtraEdgeSignals) { $allowExtra = @($ver.allowExtraEdgeSignals | ForEach-Object { [string]$_ }) }
    }
    return Get-StaticCheckFacts -ProjectData $p -ClockName $clockName -ResetNames $resetNames `
        -ForbiddenEdgeSignals $forbiddenEdge -ForbiddenSignals $forbiddenSignals -AllowExtraEdgeSignals $allowExtra
}

#-----------------------------------------------------------------------------
# board-check (reserved): never guesses pins, never flips constraintsReviewed
#-----------------------------------------------------------------------------
function Invoke-BoardCheck {
    param([Parameter(Mandatory)][string]$ProjectName)
    $p = Read-Project $ProjectName 'synth'
    $boardPath = Join-Path $p.Directory 'board.json'
    if (-not (Test-Path -LiteralPath $boardPath -PathType Leaf)) {
        Write-Host 'BOARD_CHECK: NOT_CONFIGURED'
        Write-Host "  missing    : projects/$ProjectName/board.json"
        Write-Host '  expected   : { "device": "...", "clockHz": <int>, "pins": { "<port>": { "loc": "Pxx", "iostandard": "..." } } }'
        Write-Host '  this tool never guesses pins, never edits the UCF and never sets constraintsReviewed automatically.'
        return
    }
    Write-Host 'BOARD_CHECK: NOT_IMPLEMENTED'
    Write-Host "  found      : projects/$ProjectName/board.json"
    Write-Host '  board-level checks are intentionally not implemented yet: waiting for the real TQ144 schematic.'
    Write-Host '  planned    : device/clockHz/PERIOD consistency, every top port handled, no duplicate LOC,'
    Write-Host '               debug ports constrained or removed, explicit IOSTANDARD, bank voltage confirmed by hand.'
    Write-Host '  board-check PASS would still never set constraintsReviewed=true automatically.'
}

#-----------------------------------------------------------------------------
# Verification orchestration
#-----------------------------------------------------------------------------
function Invoke-Verification {
    param([Parameter(Mandatory)][string]$ProjectName)
    Assert-Name $ProjectName

    $verifyId = 'verify-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $runDir = Join-Path "$root\projects\$ProjectName\artifacts" $verifyId
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    $notes = New-Object System.Collections.Generic.List[string]

    # 1. configuration -------------------------------------------------------
    $configResult = 'PASS'
    $configError = $null
    $p = $null
    try { $p = Read-Project $ProjectName 'synth' }
    catch { $configResult = 'FAIL'; $configError = $_.Exception.Message }
    if ($configError) { $notes.Add("configuration: $configError") }

    # 2. static checks -------------------------------------------------------
    $static = [pscustomobject]@{ Result = 'NOT_RUN'; Errors = @(); Warnings = @(); Infos = @() }
    if ($p) {
        try { $static = Invoke-StaticChecks $ProjectName }
        catch { $static = [pscustomobject]@{ Result = 'FAIL'; Errors = @("[ERROR] CHECKER " + $_.Exception.Message); Warnings = @(); Infos = @() } }
    }

    # 3. synthesis -----------------------------------------------------------
    $synthRunId = $null
    $synthFacts = $null
    $synthResult = 'NOT_RUN'
    $synthError = $null
    if ($p) {
        try { $synthRunId = Invoke-Build $ProjectName 'synth' }
        catch {
            $synthError = $_.Exception.Message
            $synthRunId = Get-LatestBuildRunId $ProjectName
        }
        if ($synthRunId) {
            try {
                $buildFacts = Get-BuildRunFacts $ProjectName $synthRunId
                $synthFacts = $buildFacts.Synthesis
                $synthResult = $synthFacts.Result
            } catch { $synthResult = 'FAIL'; $synthError = $_.Exception.Message }
        } else {
            $synthResult = 'FAIL'
        }
        if ($synthError) {
            $synthResult = 'FAIL'
            $notes.Add("synthesis: $synthError")
        }
    }

    # Optional policy from project.json: verification.failOnSynthesisWarnings.
    # When it is not configured the historical behaviour is kept (warnings are
    # reported but do not fail verification).
    $failOnWarnings = $false
    if ($p) {
        $vFlag = $p.Config.PSObject.Properties['verification']
        if ($vFlag -and $vFlag.Value -and $vFlag.Value.PSObject.Properties['failOnSynthesisWarnings']) {
            $failOnWarnings = [bool]$vFlag.Value.failOnSynthesisWarnings
        }
    }
    $warningsBlocking = ($failOnWarnings -and $synthFacts -and $null -ne $synthFacts.Warnings -and $synthFacts.Warnings -gt 0)
    if ($warningsBlocking) {
        $synthResult = 'FAIL'
        $notes.Add("synthesis: $($synthFacts.Warnings) warning(s) and verification.failOnSynthesisWarnings=true")
    }

    # 4. simulations ---------------------------------------------------------
    $simResults = New-Object System.Collections.Generic.List[object]
    $simulationResult = 'NOT_CONFIGURED'
    if ($p) {
        $sims = @()
        try { $sims = @(Get-SimulationConfig $p | Where-Object { $_.Enabled }) }
        catch { $notes.Add("simulation configuration: $($_.Exception.Message)"); $simulationResult = 'FAIL' }
        if ($sims.Count -gt 0) {
            $simulationResult = 'PASS'
            foreach ($sim in $sims) {
                try {
                    $simResults.Add((Invoke-SingleSimulation -ProjectName $ProjectName -ProjectData $p -SimDef $sim))
                } catch {
                    $simResults.Add([pscustomobject]@{ Name = $sim.Name; Top = $sim.Top; RunId = $null; RunDir = $null; Result = 'FAIL'; Reasons = @($_.Exception.Message); Generics = $sim.Generics })
                }
            }
            if (@($simResults | Where-Object { $_.Result -ne 'PASS' }).Count -gt 0) { $simulationResult = 'FAIL' }
        } else {
            $notes.Add('no enabled simulations declared in project.json (section "simulations")')
        }
    }

    # 5. implementation gate -------------------------------------------------
    $gate = [pscustomobject]@{ ExpectedBlocked = $true; ActualBlocked = $null; Result = 'NOT_RUN'; Detail = 'not evaluated' }
    if ($p) {
        $expected = $true
        $v = $p.Config.PSObject.Properties['verification']
        if ($v -and $v.Value -and $v.Value.PSObject.Properties['expectImplementationBlocked']) {
            $expected = [bool]$v.Value.expectImplementationBlocked
        }
        $actual = $null
        $detail = ''
        try {
            $null = Read-Project $ProjectName 'implement'
            $actual = $false
            $detail = 'implement gate open (UCF present and constraintsReviewed=true)'
        } catch {
            $message = $_.Exception.Message
            if ($message -match 'constraintsReviewed') {
                $actual = $true
                $detail = $message
            } else {
                $actual = $null
                $detail = "configuration error: $message"
            }
        }
        $gateResult = 'FAIL'
        if ($null -eq $actual) { $gateResult = 'FAIL' }
        elseif ($actual -eq $expected) { $gateResult = 'PASS' }
        $gate = [pscustomobject]@{ ExpectedBlocked = $expected; ActualBlocked = $actual; Result = $gateResult; Detail = $detail }
    }

    # 6. aggregate -----------------------------------------------------------
    $overall = 'PASS'
    foreach ($r in @($configResult, $static.Result, $synthResult, $simulationResult, $gate.Result)) {
        if ($r -eq 'FAIL') { $overall = 'FAIL' }
    }
    if (-not $p) { $overall = 'FAIL' }
    $stage = 'PRE_BOARD'
    if ($gate.ActualBlocked -eq $false) { $stage = 'IMPLEMENT_ALLOWED' }

    $verification = [ordered]@{
        project       = $ProjectName
        verifyId      = $verifyId
        result        = $overall
        stage         = $stage
        timestamp     = (Get-Date -Format 'o')
        configResult  = $configResult
        synthesisRun  = $synthRunId
        staticChecks  = [ordered]@{
            result   = $static.Result
            errors   = @($static.Errors)
            warnings = @($static.Warnings)
            infos    = @($static.Infos)
        }
        synthesis     = [ordered]@{
            result     = $synthResult
            errors     = $(if ($synthFacts) { $synthFacts.Errors } else { $null })
            warnings   = $(if ($synthFacts) { $synthFacts.Warnings } else { $null })
            latches    = $(if ($synthFacts) { $synthFacts.Latches } else { $null })
            registers  = $(if ($synthFacts) { $synthFacts.Registers } else { $null })
            io         = $(if ($synthFacts) { $synthFacts.Io } else { $null })
            ngcExists  = $(if ($synthFacts) { $synthFacts.NgcExists } else { $false })
            exitCode   = $(if ($synthFacts) { $synthFacts.ExitCode } else { $null })
            failOnWarnings    = $failOnWarnings
            warningsBlocking  = $warningsBlocking
        }
        simulationResult = $simulationResult
        simulations   = @($simResults | ForEach-Object {
            [ordered]@{ name = $_.Name; top = $_.Top; runId = $_.RunId; result = $_.Result; reasons = @($_.Reasons) }
        })
        implementationGate = [ordered]@{
            expectedBlocked = $gate.ExpectedBlocked
            actualBlocked   = $gate.ActualBlocked
            result          = $gate.Result
            detail          = $gate.Detail
        }
        notes         = @($notes)
    }
    Write-Json (Join-Path $runDir 'verification.json') $verification

    # console report ---------------------------------------------------------
    $svErrors = @($static.Errors | Where-Object { $_ -match 'SV_KEYWORD|GENVAR' }).Count
    $clockErrors = @($static.Errors | Where-Object { $_ -match 'CLOCK_EDGE|FORBIDDEN_CLOCK' }).Count
    $ucfErrors = @($static.Errors | Where-Object { $_ -match 'UCF_|CONSTRAINTS_FLAG' }).Count
    $otherErrors = @($static.Errors).Count - $svErrors - $clockErrors - $ucfErrors
    function Show-ResultLine([string]$Label, [string]$Value, [int]$Width = 24) {
        Write-Host ('  ' + $Label.PadRight($Width) + $Value)
    }
    $yesNo = { param($b) if ($null -eq $b) { 'unknown' } elseif ($b) { 'yes' } else { 'no' } }

    Write-Host '=================================================='
    Write-Host 'ISE PROJECT VERIFICATION'
    Write-Host "Project : $ProjectName"
    Write-Host "Verify  : $verifyId"
    Write-Host '=================================================='
    Write-Host ''
    Write-Host 'Configuration'
    Show-ResultLine 'project.json' $configResult
    Show-ResultLine 'sources' $configResult
    Show-ResultLine 'include files' $configResult
    if ($configError) { Write-Host "    $configError" }
    Write-Host ''
    Write-Host 'Static checks'
    Show-ResultLine 'Verilog-2001' $(if ($svErrors -eq 0) { 'PASS' } else { 'FAIL' })
    Show-ResultLine 'single clock domain' $(if ($clockErrors -eq 0) { 'PASS' } else { 'FAIL' })
    Show-ResultLine 'no fake constraints' $(if ($ucfErrors -eq 0) { 'PASS' } else { 'FAIL' })
    Show-ResultLine 'referenced files' $(if ($otherErrors -eq 0) { 'PASS' } else { 'FAIL' })
    Show-ResultLine 'result' $static.Result
    foreach ($w in @($static.Warnings)) { Write-Host "    $w" }
    foreach ($e in @($static.Errors)) { Write-Host "    $e" }
    Write-Host ''
    Write-Host 'Synthesis'
    Show-ResultLine 'run' $(if ($synthRunId) { $synthRunId } else { 'NOT_AVAILABLE' })
    Show-ResultLine 'XST exit' $(if ($synthFacts -and $null -ne $synthFacts.ExitCode) { [string]$synthFacts.ExitCode } else { 'NOT_AVAILABLE' })
    Show-ResultLine 'errors' $(if ($synthFacts -and $null -ne $synthFacts.Errors) { [string]$synthFacts.Errors } else { 'NOT_AVAILABLE' })
    Show-ResultLine 'warnings' $(if ($synthFacts -and $null -ne $synthFacts.Warnings) { [string]$synthFacts.Warnings } else { 'NOT_AVAILABLE' })
    Show-ResultLine 'warnings policy' $(if ($failOnWarnings) { 'blocking (failOnSynthesisWarnings=true)' } else { 'reported only' })
    Show-ResultLine 'latches' $(if ($synthFacts) { [string]$synthFacts.Latches } else { 'NOT_AVAILABLE' })
    Show-ResultLine 'result' $synthResult
    Write-Host ''
    Write-Host 'Simulation'
    if ($simResults.Count -eq 0) {
        Show-ResultLine 'simulations' $simulationResult
    } else {
        foreach ($r in $simResults) {
            Show-ResultLine $r.Name $r.Result
            foreach ($reason in @($r.Reasons)) { Write-Host "    $reason" }
        }
        Show-ResultLine 'result' $simulationResult
    }
    Write-Host ''
    Write-Host 'Implementation gate'
    Show-ResultLine 'constraintsReviewed' $(if ($p) { [string]$p.Config.constraintsReviewed } else { 'unknown' })
    Show-ResultLine 'expected blocked' (& $yesNo $gate.ExpectedBlocked)
    Show-ResultLine 'actual blocked' (& $yesNo $gate.ActualBlocked)
    Show-ResultLine 'result' $gate.Result
    if ($gate.Detail) { Write-Host "    $($gate.Detail)" }
    Write-Host ''
    foreach ($n in $notes) { Write-Host "NOTE: $n" }
    Write-Host ('Overall'.PadRight(26) + $overall)
    Write-Host ('Stage'.PadRight(26) + $stage)
    Write-Host ("verification.json : " + (Join-Path $runDir 'verification.json'))

    $summary = @(
        "Project: $ProjectName"
        "Verify: $verifyId"
        "Overall: $overall"
        "Stage: $stage"
        "Configuration: $configResult"
        "Static checks: $($static.Result) (errors=$(@($static.Errors).Count), warnings=$(@($static.Warnings).Count))"
        "Synthesis: $synthResult (run=$synthRunId)"
        "Synthesis warnings: $(if ($synthFacts) { $synthFacts.Warnings } else { 'n/a' }) (failOnSynthesisWarnings=$failOnWarnings)"
        "Simulation: $simulationResult"
        "Implementation gate: $($gate.Result) (expectedBlocked=$($gate.ExpectedBlocked), actualBlocked=$($gate.ActualBlocked))"
        'Timing: NOT_RUN/NEEDS_REVIEW (verify never certifies timing)'
    )
    Write-Utf8 (Join-Path $runDir 'summary.txt') ($summary -join "`r`n")

    if ($overall -ne 'PASS') { throw "Verification FAILED for $ProjectName (see $runDir)." }
    Write-Host "PASS: verification completed for $ProjectName."
    return $verification
}
