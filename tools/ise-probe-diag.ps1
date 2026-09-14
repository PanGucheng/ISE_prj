#=============================================================================
# probe-diag - layered JTAG cable diagnostics
#
# Purpose: find out WHICH layer between Windows and iMPACT fails when iMPACT
# cannot use the cable. Measured fact that motivates the layering: the FTDI device
# can be present and healthy in Windows immediately before AND after a failure, so
# "the cable is not visible to the VM" is NOT an established conclusion.
#
# Everything here is READ-ONLY hardware-wise: the iMPACT scripts it runs only do
# setMode / setCable / identify / readIdcode / closeCable / quit.
#
# `setCable -p auto` is allowed HERE and only here: the formal probe/program path
# pins the cable by serial number (programming.cableSerial / cableFrequencyHz).
#
# Per iteration the worker records:
#   launch, sessionname      how/where it ran (ssh = Session 0, task = interactive)
#   target_pnp               TARGET_PNP_PRESENT / TARGET_PNP_ABSENT for OUR serial
#   auto_result              `-p auto` probe: PASS | OPENED | DIGILENT_OPEN_FAILED | ENUM_FAILED
#   sn_result                explicit `-target "digilent_plugin DEVICE=SN:.."` probe
#   requested/actual delay   real measured delay (VBScript), not `ping -n`
#   reopen_result            probe after that delay (close/reopen behaviour)
#   impact_leftover          was an impact.exe still alive after the step
#=============================================================================

# Cable identity comes from the project configuration first and from our own
# successful transcripts second. It is NEVER defaulted: a fabricated frequency
# would silently change what the tool talks to.
function Get-CableIdentity {
    param(
        [Parameter(Mandatory)][string]$ArtifactRoot,
        [AllowNull()][string]$ConfiguredSerial = $null,
        [AllowNull()][System.Nullable[int]]$ConfiguredFrequencyHz = $null
    )
    $serial = $ConfiguredSerial
    $freq = $ConfiguredFrequencyHz
    $source = $(if ($serial -and $freq) { 'project.json (programming.cableSerial/cableFrequencyHz)' } else { $null })
    if ((-not $serial -or -not $freq) -and (Test-Path -LiteralPath $ArtifactRoot)) {
        $dirs = @(Get-ChildItem -LiteralPath $ArtifactRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(probe|program|diag)-' } |
            Sort-Object -Property CreationTimeUtc -Descending | Select-Object -First 60)
        foreach ($d in $dirs) {
            $candidates = @()
            foreach ($name in @('probe.log', 'program.log')) { $candidates += (Join-Path $d.FullName ('results/' + $name)) }
            $logsDir = Join-Path $d.FullName 'results/logs'
            if (Test-Path -LiteralPath $logsDir) { $candidates += @(Get-ChildItem -LiteralPath $logsDir -File -Filter '*.log' | ForEach-Object { $_.FullName }) }
            foreach ($p in $candidates) {
                if (-not (Test-Path -LiteralPath $p)) { continue }
                $t = Get-TextSafe $p
                if (-not $serial -and $t -match 'Serial Number:\s*(\d+)') { $serial = $Matches[1]; $source = 'measured: ' + $p }
                if (-not $freq -and $t -match 'JTAG Clock Frequency:\s*(\d+)\s*Hz') { $freq = [int]$Matches[1]; if (-not $source) { $source = 'measured: ' + $p } }
            }
            if ($serial -and $freq) { break }
        }
    }
    return [pscustomobject]@{ Serial = $serial; FrequencyHz = $freq; Source = $source }
}

function New-DiagProbeScript {
    param([Parameter(Mandatory)][string]$CableArgument)
    return (@(
        'setMode -bs'
        ('setCable ' + $CableArgument)
        'identify'
        'readIdcode -p 1'
        'closeCable'
        'quit'
    ) -join "`r`n") + "`r`n"
}

# Precise, measurable delay helper. `ping -n D 127.0.0.1` does NOT sleep D seconds,
# so the requested and the actually elapsed delay are both recorded.
function New-DiagDelayHelper {
    return @'
' measured delay helper: prints the elapsed milliseconds
Dim ms, t0, t1
If WScript.Arguments.Count < 1 Then
  WScript.Echo "0"
  WScript.Quit 0
End If
ms = CLng(WScript.Arguments(0))
t0 = Timer
WScript.Sleep ms
t1 = Timer
WScript.Echo CStr(CLng((t1 - t0) * 1000))
'@
}

# The worker is pure ASCII cmd: non-ASCII text inside a .cmd is read as GBK by cmd
# on this VM and corrupts the script.
function New-DiagWorker {
    param(
        [Parameter(Mandatory)][int]$Iterations,
        [Parameter(Mandatory)][string]$TargetSerial
    )
    $snFind = '"' + $TargetSerial + '"'
    return @"
@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"
if not exist logs mkdir logs
set LAUNCH=%~1
if "%LAUNCH%"=="" set LAUNCH=unknown
set SESS=%SESSIONNAME%
if "%SESS%"=="" set SESS=none
echo iteration,time,launch,sessionname,target_pnp,auto_result,sn_result,requested_delay_ms,actual_delay_ms,reopen_result,impact_leftover>results.csv
call "C:\Xilinx\14.7\ISE_DS\settings32.bat" > env.log 2>&1
for /L %%i in (1,1,$Iterations) do (
  set /a m=%%i %% 5
  set DMS=0
  if !m!==1 set DMS=1000
  if !m!==2 set DMS=3000
  if !m!==3 set DMS=10000
  if !m!==4 set DMS=30000
  set PNP=TARGET_PNP_ABSENT
  wmic path Win32_PnPEntity where "DeviceID like '%%VID_0403&PID_6014%%'" get DeviceID 2>nul | findstr /i $snFind >nul
  if not errorlevel 1 set PNP=TARGET_PNP_PRESENT
  call :probe auto %%i auto
  set AUTO=!RES!
  call :probe sn %%i sn
  set SNRES=!RES!
  set ACT=0
  for /f %%e in ('cscript //nologo delay.vbs !DMS! 2^>nul') do set ACT=%%e
  call :probe auto %%i reopen
  set REOPEN=!RES!
  set LEFT=no
  tasklist /fi "imagename eq impact.exe" 2>nul | findstr /i "impact.exe" >nul
  if not errorlevel 1 set LEFT=YES
  echo %%i,!TIME!,!LAUNCH!,!SESS!,!PNP!,!AUTO!,!SNRES!,!DMS!,!ACT!,!REOPEN!,!LEFT!>>results.csv
)
echo DONE>>results.csv
exit /b 0

:probe
set TAG=%~1
set IDX=%~2
set ROLE=%~3
impact -batch probe_%TAG%.cmd < nul > logs\%ROLE%_%IDX%.log 2>&1
rem Priority matters: a verified chain beats a failed Adept open, and a failed
rem Adept open beats the bare "Opening device" line.
set RES=ENUM_FAILED
findstr /i /c:"Added Device" logs\%ROLE%_%IDX%.log >nul
if not errorlevel 1 set RES=PASS
if "!RES!"=="PASS" exit /b 0
findstr /i /c:"failed to open device (DmgrOpenEx" logs\%ROLE%_%IDX%.log >nul
if not errorlevel 1 set RES=DIGILENT_OPEN_FAILED
if "!RES!"=="DIGILENT_OPEN_FAILED" exit /b 0
findstr /i /c:"Digilent Plugin: opening device" logs\%ROLE%_%IDX%.log >nul
if not errorlevel 1 set RES=OPENED
exit /b 0
"@
}

function Get-AdeptErrorFacts {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return [pscustomobject]@{ Erc = $null; ErcName = $null } }
    $m = [regex]::Match($Text, 'DmgrOpenEx,\s*erc\s*=\s*(\d+)')
    if (-not $m.Success) { return [pscustomobject]@{ Erc = $null; ErcName = $null } }
    $erc = [int]$m.Groups[1].Value
    # 3072 is the one value measured on this board; everything else is reported raw
    # rather than guessed.
    $name = $(if ($erc -eq 3072) { 'ercConnectionFailed' } else { $null })
    return [pscustomobject]@{ Erc = $erc; ErcName = $name }
}

function Invoke-ProbeDiag {
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [int]$Iterations = 10,
        [ValidateSet('Ssh', 'Interactive')][string]$Session = 'Ssh',
        [int]$TimeoutSeconds = 1800,
        [string]$InteractiveTaskName = 'ISE_JTAG_DIAG'
    )
    Assert-Name $ProjectName
    if ($Iterations -lt 1 -or $Iterations -gt 200) { throw "probe-diag: -Iterations must be 1..200 (got $Iterations)" }

    $p = Read-Project $ProjectName 'synth'
    $pcfg = Get-ProgrammingConfig $p
    $identity = Get-CableIdentity -ArtifactRoot (Join-Path $p.Directory 'artifacts') `
        -ConfiguredSerial $pcfg.CableSerial -ConfiguredFrequencyHz $pcfg.CableFrequencyHz
    $hasSn = [bool]($identity.Serial -and $identity.FrequencyHz)

    $run = New-ProgrammerRunDirectory -ProjectDataDirectory $p.Directory -Prefix 'diag'
    $workLocal = Join-Path $run.RunDir 'work'
    $resultsLocal = Join-Path $run.RunDir 'results'
    New-Item -ItemType Directory -Force -Path $workLocal, $resultsLocal | Out-Null

    Write-Utf8 (Join-Path $workLocal 'probe_auto.cmd') (New-DiagProbeScript -CableArgument '-p auto')
    if ($hasSn) {
        $target = 'digilent_plugin DEVICE=SN:' + $identity.Serial + ' FREQUENCY=' + $identity.FrequencyHz
        Write-Utf8 (Join-Path $workLocal 'probe_sn.cmd') (New-DiagProbeScript -CableArgument ('-target "' + $target + '"'))
    }
    Write-Utf8 (Join-Path $workLocal 'delay.vbs') (New-DiagDelayHelper)
    Write-Utf8 (Join-Path $workLocal 'worker.cmd') (New-DiagWorker -Iterations $Iterations -TargetSerial $identity.Serial)

    # The remote paths must be known BEFORE the task XML is generated: an empty
    # path there makes the scheduled action fail instantly with no output at all.
    $remote = "$script:RemoteRoot/$ProjectName/$($run.RunId)"
    $win = $remote.Replace('/', '\')

    # Interactive mode needs a task with an interactive token. `/IT` refuses to be
    # combined with `/NP` (measured: "/IT cannot be used together with /NP"), so the
    # task is defined with XML, which carries LogonType=InteractiveToken and needs no
    # password. schtasks requires this file to be UTF-16.
    if ($Session -eq 'Interactive') {
        $remoteUser = (Invoke-Ssh 'echo %USERNAME%').Trim()
        if (-not $remoteUser) { throw 'probe-diag: could not determine the remote user name.' }
        $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>ise-tools probe-diag</Author>
    <Description>Read-only JTAG cable diagnostic in the interactive session.</Description>
  </RegistrationInfo>
  <Triggers />
  <Principals>
    <Principal id="Author">
      <UserId>$remoteUser</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT2H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>cmd</Command>
      <Arguments>/d /c $win\work\worker.cmd interactive</Arguments>
    </Exec>
  </Actions>
</Task>
"@
        Set-Content -Path (Join-Path $workLocal 'task.xml') -Value $xml -Encoding Unicode
    }

    $null = Invoke-Ssh ('if not exist "' + $win + '" mkdir "' + $win + '"')
    $null = Invoke-Ssh ('if not exist "' + $win + '\results" mkdir "' + $win + '\results"')
    Invoke-Sftp @("put -r `"$($workLocal.Replace('\','/'))`" `"$remote/`"")

    Write-Host ("probe-diag: {0} iteration(s), session={1}, cable SN={2}, frequency={3} Hz ({4})" -f
        $Iterations, $Session, $(if ($identity.Serial) { $identity.Serial } else { 'UNKNOWN' }),
        $(if ($identity.FrequencyHz) { $identity.FrequencyHz } else { 'UNKNOWN' }),
        $(if ($identity.Source) { $identity.Source } else { 'UNKNOWN SOURCE' }))
    if (-not $hasSn) {
        Write-Host 'probe-diag: explicit SN test skipped: NO_MEASURED_CABLE_FREQUENCY (no default is ever assumed).'
    }

    $mode = 'direct-ssh'
    if ($Session -eq 'Interactive') {
        $create = 'schtasks /create /tn ' + $InteractiveTaskName + ' /xml "' + $win + '\work\task.xml" /f < nul'
        $createOut = Invoke-Ssh $create
        Write-Host ('probe-diag: schtasks create -> ' + ($createOut | Out-String).Trim())
        $runOut = Invoke-Ssh ('schtasks /run /tn ' + $InteractiveTaskName + ' < nul')
        Write-Host ('probe-diag: schtasks run -> ' + ($runOut | Out-String).Trim())
        $mode = 'scheduled-task-interactive'
        # Independently observe the session an impact.exe actually runs in, instead
        # of trusting the launcher label. findstr exits 1 when nothing matches, and
        # Invoke-Ssh treats a non-zero exit as an error, so this must be guarded.
        Start-Sleep -Seconds 12
        try {
            $observed = (Invoke-Ssh 'tasklist /fo csv /v | findstr /i "impact.exe"') 2>$null
            if ($observed) { Write-Host ('probe-diag: observed impact.exe row -> ' + (($observed | Out-String).Trim())) }
            else { Write-Host 'probe-diag: no impact.exe observed during the first sampling window.' }
        } catch {
            Write-Host 'probe-diag: no impact.exe observed during the first sampling window.'
        }
    } else {
        # Bounded wait: the worker may finish while its ssh session lingers (a child
        # can inherit the channel handle). The CSV polled below is the evidence, so a
        # launch that does not return must not block the diagnostic.
        try { $null = Invoke-SshTimed ('cmd /d /c "' + $win + '\work\worker.cmd ssh"') 180 }
        catch { Write-Host 'probe-diag: the launch ssh session did not return; polling for results.csv instead.' }
    }

    # poll for results.csv to appear and finish. The worker writes it in ITS working
    # directory (the uploaded work/ folder), not in the run root.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $ready = $false
    $polls = 0
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 10
        $polls++
        try {
            Invoke-Sftp @("get `"$remote/work/results.csv`" `"$($resultsLocal.Replace('\','/'))/results.csv`"")
            $csv = Get-TextSafe (Join-Path $resultsLocal 'results.csv')
            if ($csv -match 'DONE') { $ready = $true; break }
        } catch { }
    }
    if ($Session -eq 'Interactive') {
        try { $null = Invoke-Ssh ('schtasks /delete /tn ' + $InteractiveTaskName + ' /f < nul') } catch { }
    }
    try { Invoke-Sftp @("get -r `"$remote/work/logs`" `"$($resultsLocal.Replace('\','/'))/logs`"") } catch { }

    $csvText = Get-TextSafe (Join-Path $resultsLocal 'results.csv')
    $rows = @()
    foreach ($line in ($csvText -split "`r?`n")) {
        if ($line -notmatch '^\d+,') { continue }
        $f = $line -split ','
        $idx = $f[0]
        $row = [pscustomobject]@{
            Iteration = $idx; Time = $f[1]; Launch = $f[2]; SessionName = $f[3]; TargetPnp = $f[4]
            Auto = $f[5]; Sn = $f[6]; RequestedDelayMs = $f[7]; ActualDelayMs = $f[8]
            Reopen = $f[9]; ImpactLeftover = $f[10]
            AdeptErc = $null; AdeptErcName = $null
        }
        # Adept error codes are read from the fetched logs (cmd parsing of that line
        # is fragile), so the summary can name the actual failure.
        foreach ($role in @('sn', 'auto', 'reopen')) {
            $logPath = Join-Path $resultsLocal ('logs/' + $role + '_' + $idx + '.log')
            if (-not (Test-Path -LiteralPath $logPath)) { continue }
            $facts = Get-AdeptErrorFacts (Get-TextSafe $logPath)
            if ($facts.Erc) { $row.AdeptErc = $facts.Erc; $row.AdeptErcName = $facts.ErcName; break }
        }
        $rows += $row
    }

    $summary = New-Object System.Collections.Generic.List[string]
    $summary.Add('==================================================')
    $summary.Add('ISE PROBE-DIAG - JTAG CABLE LAYER DIAGNOSTIC')
    $summary.Add(('Project  : ' + $ProjectName))
    $summary.Add(('Run      : ' + $run.RunId))
    $summary.Add(('Session  : ' + $Session + ' (' + $mode + ')'))
    $summary.Add(('Iterations: ' + $Iterations))
    $summary.Add(('Cable SN : ' + $(if ($identity.Serial) { $identity.Serial } else { 'UNKNOWN' }) +
                  '   frequency: ' + $(if ($identity.FrequencyHz) { $identity.FrequencyHz.ToString() + ' Hz' } else { 'UNKNOWN' })))
    $summary.Add(('Identity source: ' + $(if ($identity.Source) { $identity.Source } else { 'UNKNOWN - no frequency is ever defaulted' })))
    $summary.Add('==================================================')
    $summary.Add('This diagnostic is read only: no assignFile, no program, no erase.')
    $summary.Add('The Windows PnP state is reported separately from what iMPACT can use.')
    $summary.Add('')
    foreach ($r in $rows) {
        $summary.Add(('  #{0,-3} {1} launch={2,-12} session={3,-9} {4,-19} auto={5,-20} sn={6,-20} delay={7}ms(actual {8}ms) reopen={9,-20} leftover={10}' -f
            $r.Iteration, $r.Time, $r.Launch, $r.SessionName, $r.TargetPnp, $r.Auto, $r.Sn, $r.RequestedDelayMs, $r.ActualDelayMs, $r.Reopen, $r.ImpactLeftover))
        if ($r.AdeptErc) { $summary.Add(('        adept erc = ' + $r.AdeptErc + $(if ($r.AdeptErcName) { ' (' + $r.AdeptErcName + ')' } else { '' }))) }
    }
    $summary.Add('')
    if ($rows.Count -gt 0) {
        $pnpPresent = @($rows | Where-Object { $_.TargetPnp -eq 'TARGET_PNP_PRESENT' }).Count
        $autoPass = @($rows | Where-Object { $_.Auto -eq 'PASS' }).Count
        $summary.Add(('Layer result: target PnP present in {0}/{1}; auto probe PASS in {2}/{1}.' -f $pnpPresent, $rows.Count, $autoPass))
        if ($hasSn) {
            $snPass = @($rows | Where-Object { $_.Sn -eq 'PASS' }).Count
            $snOpenFailed = @($rows | Where-Object { $_.Sn -eq 'DIGILENT_OPEN_FAILED' }).Count
            $summary.Add(('             explicit-SN probe PASS in {0}/{1}; DIGILENT_OPEN_FAILED in {2}/{1}.' -f $snPass, $rows.Count, $snOpenFailed))
        }
        $leftover = @($rows | Where-Object { $_.ImpactLeftover -eq 'YES' }).Count
        $summary.Add(('             impact.exe still alive after a step in {0}/{1} iterations.' -f $leftover, $rows.Count))
        $erces = @($rows | Where-Object { $_.AdeptErc } | ForEach-Object { $_.AdeptErc } | Select-Object -Unique)
        if ($erces.Count -gt 0) { $summary.Add(('             adept error codes seen: ' + ($erces -join ', '))) }
        $reopenRows = @($rows | Where-Object { $_.Auto -eq 'PASS' })
        if ($reopenRows.Count -gt 0) {
            $reopenPass = @($reopenRows | Where-Object { $_.Reopen -eq 'PASS' }).Count
            $summary.Add(('             after a successful probe, the delayed re-probe succeeded in {0}/{1} cases (close/reopen behaviour).' -f $reopenPass, $reopenRows.Count))
        }
    }
    if (-not $ready) { $summary.Add(('WARNING: results.csv did not report DONE before the timeout ({0} polls); data may be partial.' -f $polls)) }

    Write-Json (Join-Path $run.RunDir 'run.json') ([ordered]@{
        operation = 'probe-diag'; project = $ProjectName; runId = $run.RunId
        session = $Session; mode = $mode; iterations = $Iterations
        cableSerial = $identity.Serial; cableFrequencyHz = $identity.FrequencyHz; identitySource = $identity.Source
        rows = $rows; completed = $ready; startedAt = (Get-Date -Format 'o')
    })
    Write-Utf8 (Join-Path $run.RunDir 'summary.txt') (($summary.ToArray()) -join "`r`n")
    foreach ($line in $summary) { Write-Host $line }
    Write-Host ('run directory: ' + $run.RunDir)
    return [pscustomobject]@{ RunId = $run.RunId; RunDir = $run.RunDir; Rows = $rows; Completed = $ready }
}
