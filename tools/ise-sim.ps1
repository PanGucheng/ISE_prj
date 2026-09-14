#Requires -Version 7.0
#=============================================================================
# tools/ise-sim.ps1 -- ISim behavioural simulation runner (fuse + tclbatch).
#
# Loaded by tools/ise-tools.ps1 and relies on its settings ($script:RemoteHost,
# $script:RemoteRoot, $script:Settings) and helpers (Write-Utf8, Write-Json,
# Resolve-Input, Assert-Name, Invoke-Ssh, Invoke-Sftp, Invoke-SshTimed).
#
# Hard-won ISim rules baked in here so that no caller has to remember them:
#   1. The generated simulator executable only runs in a shell where
#      settings32.bat has been called; otherwise it exits silently.
#   2. It must be driven with "-tclbatch run_all.tcl" (run all / exit);
#      without it the design is loaded, nothing runs and ISim exits.
#   3. --generic_top belongs to fuse (compile/elaboration), never to the run
#      step, so every parameter combination is compiled again.
#   4. An exit code of 0 is NOT a PASS: the transcript must contain passPattern.
#   5. A run whose transcript contains neither passPattern nor failPattern is a
#      FAIL (INCONCLUSIVE), not a PASS.
#   6. Every run uses its own directory; nothing from a previous run is reused.
#=============================================================================

if (-not $script:RemoteHost) { throw 'tools/ise-sim.ps1 must be loaded through tools/ise-tools.ps1 (remote settings not initialised).' }

# Strict token check for anything that ends up in a remote CMD line or file name.
function Assert-SafeToken {
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$Kind)
    if ($Value -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        throw "Unsafe $Kind (expected [A-Za-z_][A-Za-z0-9_]*): '$Value'"
    }
}

#-----------------------------------------------------------------------------
# Simulation configuration parser (project.json -> normalised simulation defs)
#-----------------------------------------------------------------------------
function Get-SimulationConfig {
    param([Parameter(Mandatory)]$ProjectData)

    $cfg = $ProjectData.Config
    $sims = New-Object System.Collections.Generic.List[object]
    if (-not $cfg.PSObject.Properties['simulations']) { return @() }

    $seen = @{}
    foreach ($sim in @($cfg.simulations)) {
        if (-not $sim.name) { throw 'Every entry of "simulations" needs a "name".' }
        $simName = [string]$sim.name
        Assert-SafeToken $simName 'simulation name'
        if ($seen.ContainsKey($simName)) { throw "Duplicate simulation name: $simName" }
        $seen[$simName] = $true

        if (-not $sim.top) { throw 'Simulation ' + $simName + ' needs a "top".' }
        $top = [string]$sim.top
        Assert-SafeToken $top 'simulation top'

        $srcList = @($sim.sources)
        if ($srcList.Count -eq 0) { throw "Simulation '$simName' needs at least one source (its testbench)." }
        $files = New-Object System.Collections.Generic.List[string]
        foreach ($f in $srcList) {
            $null = Resolve-Input $ProjectData.Directory ([string]$f)
            $files.Add([string]$f)
        }

        $genericsTable = [ordered]@{}
        if ($sim.PSObject.Properties['generics'] -and $sim.generics) {
            foreach ($prop in $sim.generics.PSObject.Properties) {
                Assert-SafeToken ([string]$prop.Name) 'generic name'
                $value = [string]$prop.Value
                if ($value -notmatch '^[A-Za-z0-9_]+$') { throw "Unsafe generic value for '$($prop.Name)': '$value'" }
                $genericsTable[[string]$prop.Name] = $value
            }
        }
        # PSCustomObject (not an ordered dictionary) so that the shape matches what
        # ConvertFrom-Json produces and JSON round-trips cleanly.
        $generics = [pscustomobject]$genericsTable

        $timeout = 120
        if ($sim.PSObject.Properties['timeoutSeconds'] -and $sim.timeoutSeconds) {
            $timeout = [int]$sim.timeoutSeconds
            if ($timeout -lt 1 -or $timeout -gt 7200) { throw "Simulation '$simName': timeoutSeconds out of range (1..7200): $timeout" }
        }

        $pass = [string]$sim.passPattern
        if ([string]::IsNullOrWhiteSpace($pass)) { throw "Simulation '$simName' needs a passPattern." }
        $fail = ''
        if ($sim.PSObject.Properties['failPattern']) { $fail = [string]$sim.failPattern }

        $enabled = $true
        if ($sim.PSObject.Properties['enabled']) { $enabled = [bool]$sim.enabled }

        $sims.Add([pscustomobject]@{
            Name           = $simName
            Top            = $top
            Sources        = $files.ToArray()
            Generics       = $generics
            TimeoutSeconds = $timeout
            PassPattern    = $pass
            FailPattern    = $fail
            Enabled        = $enabled
        })
    }
    # .ToArray(): PowerShell in this environment throws "Argument types do not
    # match" for @() applied directly to a generic List[object].
    return $sims.ToArray()
}

#-----------------------------------------------------------------------------
# Generated remote scripts (pure text generation, no side effects beyond files)
#-----------------------------------------------------------------------------
function New-SimRunScripts {
    param(
        [Parameter(Mandatory)]$SimDef,
        [Parameter(Mandatory)]$ProjectData,
        [Parameter(Mandatory)][string]$GeneratedDir
    )
    $cfg = $ProjectData.Config
    New-Item -ItemType Directory -Force -Path $GeneratedDir | Out-Null

    # fuse project file: RTL sources first, then the testbench. Include files are
    # NOT listed here (they are pulled in with `include and passed with -i).
    $prj = New-Object System.Collections.Generic.List[string]
    foreach ($s in $cfg.sources) { $prj.Add(('{0} {1} "{2}"' -f $s.language, $s.library, $s.path)) }
    foreach ($f in $SimDef.Sources) { $prj.Add(('verilog work "{0}"' -f $f)) }
    Write-Utf8 (Join-Path $GeneratedDir 'sim.prj') (($prj -join "`r`n") + "`r`n")

    # ISim in this ISE installation is an interactive Tcl-driven simulator:
    # it only runs the testbench when it is fed these commands.
    Write-Utf8 (Join-Path $GeneratedDir 'run_all.tcl') ("run all`r`nexit`r`n")

    $incDirs = New-Object System.Collections.Generic.List[string]
    foreach ($d in $cfg.includeDirs) { if ($d) { $incDirs.Add(([string]$d).Replace('\', '/')) } }
    foreach ($f in $cfg.includeFiles) {
        if ($f) {
            $parent = [IO.Path]::GetDirectoryName([string]$f)
            if ($parent) { $incDirs.Add($parent.Replace('\', '/')) }
        }
    }
    $incArgs = (@($incDirs | Sort-Object -Unique) | ForEach-Object { '-i "{0}"' -f $_ }) -join ' '
    $genArgs = (@($SimDef.Generics.PSObject.Properties | Sort-Object Name) | ForEach-Object { '--generic_top "{0}={1}"' -f $_.Name, $_.Value }) -join ' '
    $exe = '{0}.exe' -f $SimDef.Top

    $fuseLines = @(
        '@echo off'
        'setlocal'
        'cd /d "%~dp0"'
        'if not exist "..\results" mkdir "..\results"'
        'rem never reuse a previous run: clear status, exit codes and the old exe'
        'if exist ..\results\fuse.status del /q ..\results\fuse.status'
        'if exist ..\results\fuse.exitcode del /q ..\results\fuse.exitcode'
        'if exist ..\results\run.status del /q ..\results\run.status'
        'if exist ..\results\simulation.exitcode del /q ..\results\simulation.exitcode'
        ('if exist "{0}" del /q "{0}"' -f $exe)
        ('call "{0}" > ..\results\fuse.environment.log 2>&1' -f $script:Settings)
        'if errorlevel 1 goto failed'
        'if exist isim rmdir /s /q isim'
        'echo RUNNING:fuse>..\results\run.status'
        ('fuse -prj sim.prj -top {0} {1} {2} -o {3} > ..\results\fuse.log 2>&1' -f $SimDef.Top, $incArgs, $genArgs, $exe).Trim()
        'set RC=%ERRORLEVEL%'
        'echo %RC% > ..\results\fuse.exitcode'
        'if not "%RC%"=="0" goto failed'
        ('if not exist "{0}" goto failed' -f $exe)
        'echo COMPLETE>..\results\fuse.status'
        'exit /b 0'
        ':failed'
        'echo FAILED>..\results\fuse.status'
        'exit /b 1'
    )
    # NOTE: the wrapper scripts must NOT be called "fuse.cmd" or "run.cmd".
    # CMD resolves a bare command name from the current directory first, so a
    # local "fuse.cmd" shadows the Xilinx fuse.exe that settings32.bat puts on
    # PATH - the script then calls itself until CMD aborts the recursion.
    Write-Utf8 (Join-Path $GeneratedDir 'sim_fuse.cmd') (($fuseLines -join "`r`n") + "`r`n")

    $runLines = @(
        '@echo off'
        'setlocal'
        'cd /d "%~dp0"'
        'if not exist "..\results" mkdir "..\results"'
        'if exist ..\results\simulation.exitcode del /q ..\results\simulation.exitcode'
        ('call "{0}" > ..\results\run.environment.log 2>&1' -f $script:Settings)
        'if errorlevel 1 goto failed'
        'echo RUNNING:simulation>..\results\run.status'
        ('{0} -tclbatch run_all.tcl -log ..\results\simulation.log > ..\results\simulation.stdout.log 2>&1' -f $exe)
        'set RC=%ERRORLEVEL%'
        'echo %RC% > ..\results\simulation.exitcode'
        'if not "%RC%"=="0" goto failed'
        'echo COMPLETE>..\results\run.status'
        'exit /b 0'
        ':failed'
        'echo FAILED>..\results\run.status'
        'exit /b 1'
    )
    Write-Utf8 (Join-Path $GeneratedDir 'sim_run.cmd') (($runLines -join "`r`n") + "`r`n")
}

#-----------------------------------------------------------------------------
# Result parser: pure function over the downloaded facts
#-----------------------------------------------------------------------------
function Get-SimVerdict {
    param(
        [AllowNull()]$FuseExitCode,
        [AllowNull()]$SimulationExitCode,
        [AllowNull()][string]$RunStatus,
        [AllowNull()][string]$LogText,
        [Parameter(Mandatory)][string]$PassPattern,
        [AllowNull()][string]$FailPattern,
        [bool]$TimedOut = $false
    )
    $reasons = New-Object System.Collections.Generic.List[string]

    if ($TimedOut) { $reasons.Add('simulation timed out') }
    if ($null -eq $FuseExitCode) { $reasons.Add('fuse.exitcode missing') }
    elseif ([int]$FuseExitCode -ne 0) { $reasons.Add("fuse exit code $FuseExitCode") }
    if ($null -eq $SimulationExitCode) { $reasons.Add('simulation.exitcode missing') }
    elseif ([int]$SimulationExitCode -ne 0) { $reasons.Add("simulation exit code $SimulationExitCode") }

    $status = ''
    if ($null -ne $RunStatus) { $status = $RunStatus.Trim() }
    if ($status -ne 'COMPLETE') { $reasons.Add("run.status is '$status' (expected COMPLETE)") }

    $hasPass = $false
    $hasFail = $false
    if ([string]::IsNullOrEmpty($LogText)) {
        $reasons.Add('simulation log missing or empty')
    } else {
        $hasPass = $LogText.Contains($PassPattern)
        if ($FailPattern) { $hasFail = $LogText.Contains($FailPattern) }
        if ($hasFail) { $reasons.Add("failPattern found: $FailPattern") }
        if (-not $hasPass) { $reasons.Add("passPattern not found: $PassPattern") }
    }

    return [pscustomobject]@{
        Result              = $(if ($reasons.Count -eq 0) { 'PASS' } else { 'FAIL' })
        Reasons             = @($reasons)
        PassPatternFound    = $hasPass
        FailPatternFound    = $hasFail
        FuseExitCode        = $FuseExitCode
        SimulationExitCode  = $SimulationExitCode
        ToolFlow            = $status
        TimedOut            = $TimedOut
    }
}

#-----------------------------------------------------------------------------
# Download results into the run directory (new folder each time)
#-----------------------------------------------------------------------------
function Receive-SimResults {
    param([Parameter(Mandatory)][string]$ProjectName, [Parameter(Mandatory)][string]$SimRunId)
    Assert-Name $ProjectName
    if ($SimRunId -notmatch '^sim-\d{8}-\d{6}-[a-f0-9]{8}$') { throw "Invalid simulation run id: $SimRunId" }
    $runDir = Join-Path "$root\projects\$ProjectName\artifacts" $SimRunId
    $incoming = Join-Path $runDir ('download-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $remote = "$script:RemoteRoot/$ProjectName/$SimRunId/results"
    Invoke-Sftp @("get -r `"/$remote`" `"$($incoming.Replace('\', '/'))`"")
    $results = Join-Path $runDir 'results'
    if (Test-Path -LiteralPath $results) {
        Move-Item -LiteralPath $results -Destination (Join-Path $runDir ('previous-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)))
    }
    Move-Item -LiteralPath $incoming -Destination $results
}

#-----------------------------------------------------------------------------
# One simulation: stage -> upload -> fuse -> run -> download -> judge
#-----------------------------------------------------------------------------
function Invoke-SingleSimulation {
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)]$ProjectData,
        [Parameter(Mandatory)]$SimDef
    )
    $cfg = $ProjectData.Config
    $simRunId = 'sim-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $runDir = Join-Path $ProjectData.Directory ('artifacts/' + $simRunId)
    $inputs = Join-Path $runDir 'inputs'
    $generated = Join-Path $runDir 'generated'
    $localResults = Join-Path $runDir 'results'
    New-Item -ItemType Directory -Force -Path $inputs, $generated, $localResults | Out-Null

    $relFiles = New-Object System.Collections.Generic.List[string]
    foreach ($s in $cfg.sources) { $relFiles.Add([string]$s.path) }
    foreach ($f in $cfg.includeFiles) { if ($f) { $relFiles.Add([string]$f) } }
    foreach ($f in $SimDef.Sources) { $relFiles.Add([string]$f) }
    $relFiles = @($relFiles | Sort-Object -Unique)

    $hashes = foreach ($rel in $relFiles) {
        $dest = Join-Path $inputs $rel
        New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
        Copy-Item -LiteralPath (Join-Path $ProjectData.Directory $rel) -Destination $dest
        @{ path = $rel; sha256 = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash }
    }
    foreach ($d in $cfg.includeDirs) { New-Item -ItemType Directory -Force -Path (Join-Path $inputs $d) | Out-Null }

    New-SimRunScripts -SimDef $SimDef -ProjectData $ProjectData -GeneratedDir $generated
    $generatedNames = @('sim.prj', 'run_all.tcl', 'sim_fuse.cmd', 'sim_run.cmd')
    $generatedHashes = foreach ($g in $generatedNames) {
        @{ path = 'generated/' + $g; sha256 = (Get-FileHash -LiteralPath (Join-Path $generated $g) -Algorithm SHA256).Hash }
    }

    $remote = "$script:RemoteRoot/$ProjectName/$simRunId"
    $winRemote = $remote.Replace('/', '\')
    $meta = [ordered]@{
        project         = $ProjectName
        simRunId        = $simRunId
        kind            = 'simulation'
        simulation      = $SimDef.Name
        top             = $SimDef.Top
        generics        = $SimDef.Generics
        timeoutSeconds  = $SimDef.TimeoutSeconds
        passPattern     = $SimDef.PassPattern
        failPattern     = $SimDef.FailPattern
        config          = $cfg
        files           = @($hashes)
        generatedFiles  = @($generatedHashes)
        host            = $script:RemoteHost
        remotePath      = $remote
        status          = 'prepared'
    }
    Write-Json (Join-Path $runDir 'run.json') $meta

    # Only the run root and results are pre-created: `put -r inputs` must create
    # <remote>/inputs itself, otherwise SFTP nests the local directory inside the
    # existing one (<remote>/inputs/inputs) and sim.prj's relative paths break.
    $null = Invoke-Ssh ('if not exist "' + $winRemote + '" mkdir "' + $winRemote + '"')
    $null = Invoke-Ssh ('if not exist "' + $winRemote + '\results" mkdir "' + $winRemote + '\results"')
    Invoke-Sftp @("put -r `"$($inputs.Replace('\', '/'))`" `"/$remote/inputs`"")
    $puts = foreach ($g in $generatedNames) {
        "put `"$((Join-Path $generated $g).Replace('\', '/'))`" `"/$remote/inputs/$g`""
    }
    Invoke-Sftp @($puts)

    Write-Host "Simulating '$($SimDef.Name)' ($simRunId, top $($SimDef.Top)) ..."
    $timedOut = $false
    $remoteError = $null
    $fuseTimeout = [Math]::Max(300, $SimDef.TimeoutSeconds)
    try {
        $null = Invoke-SshTimed ('cmd /d /c "' + $winRemote + '\inputs\sim_fuse.cmd"') $fuseTimeout
        $null = Invoke-SshTimed ('cmd /d /c "' + $winRemote + '\inputs\sim_run.cmd"') $SimDef.TimeoutSeconds
    } catch {
        $remoteError = $_.Exception.Message
        if ($remoteError -match '^TIMEOUT:') {
            $timedOut = $true
            try { $null = Invoke-Ssh ('cmd /d /c "echo TIMEOUT>> ' + $winRemote + '\results\run.status"') } catch { }
            try { $null = Invoke-Ssh ('taskkill /f /im ' + $SimDef.Top + '.exe') } catch { }
        }
    }

    Receive-SimResults $ProjectName $simRunId

    $fuseExit = Get-IntSafe (Join-Path $localResults 'fuse.exitcode')
    $simExit = Get-IntSafe (Join-Path $localResults 'simulation.exitcode')
    $status = Get-TextSafe (Join-Path $localResults 'run.status')
    $logText = Get-TextSafe (Join-Path $localResults 'simulation.log')
    $logFile = 'results/simulation.log'
    if (-not $logText) {
        $logText = Get-TextSafe (Join-Path $localResults 'simulation.stdout.log')
        $logFile = 'results/simulation.stdout.log'
    }

    $verdict = Get-SimVerdict -FuseExitCode $fuseExit -SimulationExitCode $simExit -RunStatus $status `
        -LogText $logText -PassPattern $SimDef.PassPattern -FailPattern $SimDef.FailPattern -TimedOut $timedOut
    $reasons = New-Object System.Collections.Generic.List[string]
    foreach ($r in $verdict.Reasons) { $reasons.Add($r) }
    if ($remoteError -and -not $timedOut) { $reasons.Add("remote execution error: $remoteError") }
    $result = $verdict.Result
    if ($reasons.Count -gt 0) { $result = 'FAIL' }

    $meta.status = $result
    $meta.fuseExitCode = $fuseExit
    $meta.simulationExitCode = $simExit
    Write-Json (Join-Path $runDir 'run.json') $meta

    $simJson = [ordered]@{
        project            = $ProjectName
        simRunId           = $simRunId
        simulation         = $SimDef.Name
        top                = $SimDef.Top
        generics           = $SimDef.Generics
        timeoutSeconds     = $SimDef.TimeoutSeconds
        fuseExitCode       = $fuseExit
        simulationExitCode = $simExit
        toolFlow           = $verdict.ToolFlow
        timedOut           = $timedOut
        passPattern        = $SimDef.PassPattern
        failPattern        = $SimDef.FailPattern
        passPatternFound   = $verdict.PassPatternFound
        failPatternFound   = $verdict.FailPatternFound
        logFile            = $logFile
        result             = $result
        reasons            = @($reasons)
        files              = @($hashes)
        remotePath         = $remote
    }
    Write-Json (Join-Path $runDir 'sim.json') $simJson

    $summary = @(
        "Project: $ProjectName",
        "Simulation run: $simRunId",
        "Simulation: $($SimDef.Name) (top $($SimDef.Top))",
        "Generics: $(if (@($SimDef.Generics.PSObject.Properties).Count -eq 0) { '(none)' } else { (@($SimDef.Generics.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', ') })",
        "fuse exit code: $(if ($null -eq $fuseExit) { 'NOT_AVAILABLE' } else { $fuseExit })",
        "simulation exit code: $(if ($null -eq $simExit) { 'NOT_AVAILABLE' } else { $simExit })",
        "run.status: $(if ($null -eq $status) { 'NOT_AVAILABLE' } else { $status.Trim() })",
        "timed out: $timedOut",
        "pass pattern found: $($verdict.PassPatternFound) ('$($SimDef.PassPattern)')",
        "fail pattern found: $($verdict.FailPatternFound)",
        "result: $result",
        "reasons: $(if ($reasons.Count -eq 0) { '(none)' } else { $reasons -join '; ' })"
    )
    Write-Utf8 (Join-Path $runDir 'summary.txt') ($summary -join "`r`n")
    Write-Host (($summary | ForEach-Object { '  ' + $_ }) -join "`n")

    return [pscustomobject]@{
        Name     = $SimDef.Name
        Top      = $SimDef.Top
        RunId    = $simRunId
        RunDir   = $runDir
        Result   = $result
        Reasons  = @($reasons)
        Generics = $SimDef.Generics
    }
}

#-----------------------------------------------------------------------------
# CLI entry: sim -Project <p> [-Test <name>]
#-----------------------------------------------------------------------------
function Invoke-Simulation {
    param([Parameter(Mandatory)][string]$ProjectName, [string]$Test)

    $p = Read-Project $ProjectName 'synth'
    $sims = @(Get-SimulationConfig $p)
    if ($sims.Count -eq 0) { throw 'Project ' + $ProjectName + ' has no "simulations" section in project.json.' }

    if ($Test) {
        $selected = @($sims | Where-Object { $_.Name -eq $Test })
        if ($selected.Count -eq 0) {
            $available = (@($sims | ForEach-Object { $_.Name }) -join ', ')
            throw "Unknown simulation '$Test' for project '$ProjectName'. Available: $available"
        }
    } else {
        $selected = @($sims | Where-Object { $_.Enabled })
        if ($selected.Count -eq 0) { throw "Project '$ProjectName' has no enabled simulations." }
    }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($sim in $selected) {
        $results.Add((Invoke-SingleSimulation -ProjectName $ProjectName -ProjectData $p -SimDef $sim))
    }

    $failed = @($results | Where-Object { $_.Result -ne 'PASS' })
    if ($failed.Count -gt 0) {
        throw "Simulation FAILED: $(($failed | ForEach-Object { $_.Name }) -join ', ')"
    }
    Write-Host "PASS: $($results.Count) simulation(s) passed for $ProjectName."
    return $results.ToArray()
}
