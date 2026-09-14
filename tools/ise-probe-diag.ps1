#=============================================================================
# probe-diag - layered JTAG cable diagnostics
#
# Purpose: find out WHICH layer between Windows and iMPACT fails when iMPACT
# reports "Digilent Plugin: no JTAG device was found". Measured fact that motivates
# this: the FTDI device can be present and healthy in Windows (wmic Win32_PnPEntity
# Status=OK) immediately before AND after such a failure, so "the cable is not
# visible to the VM" is NOT an established conclusion.
#
# Everything here is READ-ONLY hardware-wise: the iMPACT scripts it runs only do
# setMode / setCable / identify / readIdcode / closeCable / quit. No assignFile,
# no program, no erase.
#
# Layers recorded per iteration:
#   sessionname          Services (Session 0, via SSH) vs Console (interactive)
#   ftdi_pnp             is USB\VID_0403&PID_6014 present in Windows right now
#   auto_result          iMPACT `setCable -p auto` probe
#   sn_result            iMPACT `setCable -target "digilent_plugin DEVICE=SN:.."` probe
#   reopen_result        a second probe after a configurable delay (close/reopen race)
#   impact_leftover      was an impact.exe still alive after the step
#=============================================================================

# The cable identity is taken from our own transcripts - never invented.
function Get-KnownCableIdentity {
    param([Parameter(Mandatory)][string]$ArtifactRoot)
    $serial = $null; $freq = $null
    if (-not (Test-Path -LiteralPath $ArtifactRoot)) { return [pscustomobject]@{ Serial = $null; FrequencyHz = $null } }
    $dirs = @(Get-ChildItem -LiteralPath $ArtifactRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(probe|program)-' } |
        Sort-Object -Property CreationTimeUtc -Descending | Select-Object -First 60)
    foreach ($d in $dirs) {
        foreach ($name in @('probe.log', 'program.log')) {
            $p = Join-Path $d.FullName ('results/' + $name)
            if (-not (Test-Path -LiteralPath $p)) { continue }
            $t = Get-TextSafe $p
            if (-not $serial -and $t -match 'Serial Number:\s*(\d+)') { $serial = $Matches[1] }
            if (-not $freq -and $t -match 'JTAG Clock Frequency:\s*(\d+)\s*Hz') { $freq = $Matches[1] }
        }
        if ($serial -and $freq) { break }
    }
    return [pscustomobject]@{ Serial = $serial; FrequencyHz = $freq }
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

# The full worker. It is pure ASCII cmd: non-ASCII text inside a .cmd is read as
# GBK by cmd on this VM and corrupts the script. The launch label arrives as
# argument 1 so the CSV records how the worker was started (ssh vs scheduled task)
# independently of whether the host defines %SESSIONNAME% for that context.
function New-DiagWorkerWithSn {
    param([Parameter(Mandatory)][int]$Iterations)
    return @"
@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"
if not exist logs mkdir logs
set LAUNCH=%~1
if "%LAUNCH%"=="" set LAUNCH=unknown
set SESS=%SESSIONNAME%
if "%SESS%"=="" set SESS=none
echo iteration,time,launch,sessionname,ftdi_pnp,auto_result,sn_result,reopen_delay_s,reopen_result,impact_leftover>results.csv
call "C:\Xilinx\14.7\ISE_DS\settings32.bat" > env.log 2>&1
for /L %%i in (1,1,$Iterations) do (
  set /a m=%%i %% 5
  set D=0
  if !m!==1 set D=1
  if !m!==2 set D=3
  if !m!==3 set D=10
  if !m!==4 set D=30
  set PNP=ABSENT
  wmic path Win32_PnPEntity where "DeviceID like '%%VID_0403%%'" get DeviceID 2>nul | findstr /i "0403" >nul
  if not errorlevel 1 set PNP=PRESENT
  call :probe auto %%i auto
  set AUTO=!RES!
  call :probe sn %%i sn
  set SNRES=!RES!
  ping -n !D! 127.0.0.1 > nul
  call :probe auto %%i reopen
  set REOPEN=!RES!
  set LEFT=no
  tasklist /fi "imagename eq impact.exe" 2>nul | findstr /i "impact.exe" >nul
  if not errorlevel 1 set LEFT=YES
  echo %%i,!TIME!,!LAUNCH!,!SESS!,!PNP!,!AUTO!,!SNRES!,!D!,!REOPEN!,!LEFT!>>results.csv
)
echo DONE>>results.csv
exit /b 0

:probe
set TAG=%~1
set IDX=%~2
set ROLE=%~3
rem < nul matters: without it the ssh session can stay open after the worker is
rem done, because the child inherits the channel handle as stdin.
impact -batch probe_%TAG%.cmd < nul > logs\%ROLE%_%IDX%.log 2>&1
set RES=ENUM_FAILED
findstr /c:"Digilent Plugin: opening device" logs\%ROLE%_%IDX%.log >nul
if not errorlevel 1 set RES=OPENED
findstr /c:"Added Device" logs\%ROLE%_%IDX%.log >nul
if not errorlevel 1 set RES=PASS
exit /b 0
"@
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
    $artifacts = Join-Path $p.Directory 'artifacts'
    $identity = Get-KnownCableIdentity -ArtifactRoot $artifacts
    $hasSn = [bool]$identity.Serial

    $run = New-ProgrammerRunDirectory -ProjectDataDirectory $p.Directory -Prefix 'diag'
    $workLocal = Join-Path $run.RunDir 'work'
    $resultsLocal = Join-Path $run.RunDir 'results'
    New-Item -ItemType Directory -Force -Path $workLocal, $resultsLocal | Out-Null

    Write-Utf8 (Join-Path $workLocal 'probe_auto.cmd') (New-DiagProbeScript -CableArgument '-p auto')
    if ($hasSn) {
        $freq = $(if ($identity.FrequencyHz) { $identity.FrequencyHz } else { '10000000' })
        $target = 'digilent_plugin DEVICE=SN:' + $identity.Serial + ' FREQUENCY=' + $freq
        Write-Utf8 (Join-Path $workLocal 'probe_sn.cmd') (New-DiagProbeScript -CableArgument ('-target "' + $target + '"'))
    }
    Write-Utf8 (Join-Path $workLocal 'worker.cmd') (New-DiagWorkerWithSn -Iterations $Iterations)

    # The remote paths must be known BEFORE the task XML is generated: an empty
    # path here makes the scheduled action fail instantly with no output at all.
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

    Write-Host ("probe-diag: {0} iteration(s), session={1}, cable SN={2}, freq={3} Hz" -f $Iterations, $Session, $(if ($hasSn) { $identity.Serial } else { 'UNKNOWN' }), $(if ($identity.FrequencyHz) { $identity.FrequencyHz } else { 'UNKNOWN' }))
    if (-not $hasSn) { Write-Host 'probe-diag: no cable serial found in own transcripts - the SN variant is skipped.' }

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
        $null = Invoke-Ssh ('schtasks /delete /tn ' + $InteractiveTaskName + ' /f < nul') 2>$null
    }
    try { Invoke-Sftp @("get -r `"$remote/work/logs`" `"$($resultsLocal.Replace('\','/'))/logs`"") } catch { }

    $csvText = Get-TextSafe (Join-Path $resultsLocal 'results.csv')
    $rows = @()
    foreach ($line in ($csvText -split "`r?`n")) {
        if ($line -notmatch '^\d+,') { continue }
        $f = $line -split ','
        $rows += [pscustomobject]@{
            Iteration = $f[0]; Time = $f[1]; Launch = $f[2]; SessionName = $f[3]; FtdiPnp = $f[4]
            Auto = $f[5]; Sn = $f[6]; ReopenDelay = $f[7]; Reopen = $f[8]; ImpactLeftover = $f[9]
        }
    }

    $summary = New-Object System.Collections.Generic.List[string]
    $summary.Add('==================================================')
    $summary.Add('ISE PROBE-DIAG - JTAG CABLE LAYER DIAGNOSTIC')
    $summary.Add(('Project  : ' + $ProjectName))
    $summary.Add(('Run      : ' + $run.RunId))
    $summary.Add(('Session  : ' + $Session + ' (' + $mode + ')'))
    $summary.Add(('Iterations: ' + $Iterations))
    $summary.Add('==================================================')
    $summary.Add('This diagnostic is read only: no assignFile, no program, no erase.')
    $summary.Add('')
    foreach ($r in $rows) {
        $summary.Add(('  #{0,-3} {1} launch={2,-12} session={3,-9} ftdiPnp={4,-7} auto={5,-12} sn={6,-12} reopen(+{7}s)={8,-12} leftoverImpact={9}' -f
            $r.Iteration, $r.Time, $r.Launch, $r.SessionName, $r.FtdiPnp, $r.Auto, $r.Sn, $r.ReopenDelay, $r.Reopen, $r.ImpactLeftover))
    }
    $summary.Add('')
    if ($rows.Count -gt 0) {
        $autoPass = @($rows | Where-Object { $_.Auto -eq 'PASS' }).Count
        $pnpPresent = @($rows | Where-Object { $_.FtdiPnp -eq 'PRESENT' }).Count
        $summary.Add(('Layer result: Windows PnP present in {0}/{1} iterations; iMPACT auto probe PASS in {2}/{1}.' -f $pnpPresent, $rows.Count, $autoPass))
        if ($hasSn) {
            $snPass = @($rows | Where-Object { $_.Sn -eq 'PASS' }).Count
            $summary.Add(('             iMPACT explicit-SN probe PASS in {0}/{1}.' -f $snPass, $rows.Count))
        }
        $leftover = @($rows | Where-Object { $_.ImpactLeftover -eq 'YES' }).Count
        $summary.Add(('             impact.exe still alive after a step in {0}/{1} iterations.' -f $leftover, $rows.Count))
        $mismatch = @($rows | Where-Object { $_.FtdiPnp -eq 'PRESENT' -and $_.Auto -ne 'PASS' }).Count
        $summary.Add(('             "device in Windows but iMPACT cannot use it" in {0}/{1} iterations.' -f $mismatch, $rows.Count))
        $reopenRows = @($rows | Where-Object { $_.Auto -eq 'PASS' })
        if ($reopenRows.Count -gt 0) {
            $reopenPass = @($reopenRows | Where-Object { $_.Reopen -eq 'PASS' }).Count
            $summary.Add(('             after a successful probe, an immediate re-probe succeeded in {0}/{1} cases (close/reopen race).' -f $reopenPass, $reopenRows.Count))
        }
    }
    if (-not $ready) { $summary.Add(('WARNING: results.csv did not report DONE before the timeout ({0} polls); data may be partial.' -f $polls)) }

    Write-Json (Join-Path $run.RunDir 'run.json') ([ordered]@{
        operation = 'probe-diag'; project = $ProjectName; runId = $run.RunId
        session = $Session; mode = $mode; iterations = $Iterations
        cableSerial = $identity.Serial; cableFrequencyHz = $identity.FrequencyHz
        rows = $rows; completed = $ready; startedAt = (Get-Date -Format 'o')
    })
    Write-Utf8 (Join-Path $run.RunDir 'summary.txt') (($summary.ToArray()) -join "`r`n")
    foreach ($line in $summary) { Write-Host $line }
    Write-Host ('run directory: ' + $run.RunDir)
    return [pscustomobject]@{ RunId = $run.RunId; RunDir = $run.RunDir; Rows = $rows; Completed = $ready }
}
