$script:RemoteHost = 'fpga-vm'
$script:RemoteRoot = 'C:/Users/PanGucheng/ise-builds'
$script:Settings = 'C:\Xilinx\14.7\ISE_DS\settings32.bat'

function Write-Utf8($Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}
function Write-Json($Path, $Value) { Write-Utf8 $Path ($Value | ConvertTo-Json -Depth 12) }
# Read a text file, returning $null instead of throwing when it is absent.
function Get-TextSafe([string]$Path) {
    if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) { return [IO.File]::ReadAllText($Path) }
    return $null
}
# Read a small integer out of a file written by CMD (e.g. an *.exitcode file).
function Get-IntSafe([string]$Path) {
    $text = Get-TextSafe $Path
    if ($null -eq $text) { return $null }
    $text = $text.Trim()
    if ($text -match '^-?\d+$') { return [int]$text }
    return $null
}
# Build run ids (yyyyMMdd-HHmmss-xxxxxxxx) newest first. sim-/verify- runs are excluded.
# Sorted by creation time, not by name: two runs can share the same second and
# then only the random suffix would decide the order.
function Get-BuildRunIds([string]$Name) {
    Assert-Name $Name
    $dir = "$root\projects\$Name\artifacts"
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Directory |
        Where-Object { $_.Name -match '^\d{8}-\d{6}-[a-f0-9]{8}$' } |
        Sort-Object -Property @{ Expression = 'CreationTimeUtc'; Descending = $true }, @{ Expression = 'Name'; Descending = $true } |
        ForEach-Object { $_.Name })
}
function Get-LatestBuildRunId([string]$Name) {
    $ids = @(Get-BuildRunIds $Name)
    if ($ids.Count -eq 0) { return $null }
    return $ids[0]
}
function Assert-Name([string]$Name) {
    if ($Name -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,47}$') { throw 'Project name must start with a letter and contain only ASCII letters, digits, _ or - (max 48).' }
}
function Invoke-Ssh([string]$RemoteCommand) {
    $result = & ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 $script:RemoteHost $RemoteCommand 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "SSH exit $code : $($result -join "`n")" }
    return ($result -join "`n")
}
function Invoke-Sftp([string[]]$Lines) {
    $result = ($Lines -join "`n") | & sftp -b - -o BatchMode=yes -o ConnectTimeout=10 $script:RemoteHost 2>&1
    if ($LASTEXITCODE -ne 0) { throw "SFTP failed: $($result -join "`n")" }
}
# Same as Invoke-Ssh but bounded by a wall-clock timeout. On expiry the local ssh
# process tree is killed and a 'TIMEOUT: ...' error is thrown, so callers can tell
# a hung remote command apart from a normal failure.
function Invoke-SshTimed([string]$RemoteCommand, [int]$TimeoutSeconds) {
    if ($TimeoutSeconds -lt 1) { throw 'Invoke-SshTimed needs a positive timeout.' }
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'ssh'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($a in @('-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3', $script:RemoteHost, $RemoteCommand)) {
        $psi.ArgumentList.Add($a)
    }
    $proc = [Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        try { $proc.Kill($true) } catch { }
        try { $proc.WaitForExit(5000) } catch { }
        throw "TIMEOUT: remote command exceeded $TimeoutSeconds s and the local SSH session was terminated."
    }
    $text = ($outTask.Result + $errTask.Result)
    if ($proc.ExitCode -ne 0) { throw "SSH exit $($proc.ExitCode) : $text" }
    return $text
}
function New-IseProject([string]$Name) {
    Assert-Name $Name
    $dir = Join-Path "$root\projects" $Name
    if (Test-Path -LiteralPath $dir) { throw "Already exists: $dir" }
    New-Item -ItemType Directory -Path $dir | Out-Null
    foreach ($sub in @('src','constraints','ip','artifacts')) { New-Item -ItemType Directory -Path "$dir\$sub" | Out-Null }
    Copy-Item -LiteralPath "$root\templates\project.json" -Destination "$dir\project.json"
    Write-Host "Created $dir. Set device, top and sources before building."
}
function Resolve-Input([string]$Dir, [string]$Relative) {
    # Strict portable paths also prevent CMD/XST metacharacter injection.
    if ($Relative -notmatch '^[A-Za-z0-9_./-]+$' -or [IO.Path]::IsPathRooted($Relative)) { throw "Use portable relative paths without spaces: $Relative" }
    $full = [IO.Path]::GetFullPath((Join-Path $Dir $Relative))
    if (-not $full.StartsWith(($Dir.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw "Input escapes project: $Relative" }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Missing input: $Relative" }
    $cursor = Get-Item -LiteralPath $full
    while ($cursor -and $cursor.FullName -ne $Dir) {
        if ($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked inputs are not supported: $Relative" }
        if ($cursor -is [IO.FileInfo]) { $cursor = $cursor.Directory } else { $cursor = $cursor.Parent }
    }
    return [IO.Path]::GetFullPath((Join-Path $Dir $Relative))
}
function Read-Project([string]$Name, [string]$Target) {
    Assert-Name $Name
    $dir = [IO.Path]::GetFullPath((Join-Path "$root\projects" $Name))
    $cfg = Get-Content -LiteralPath "$dir\project.json" -Raw | ConvertFrom-Json
    if ($cfg.device -notmatch '^xc[a-z0-9]+-[1-9][0-9]*[a-z]?-[a-z]+[0-9]+$') { throw 'Set complete device, for example xc6slx9-2-tqg144 (example only; choose your actual part).' }
    if ($cfg.top -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw 'Set a valid top module/entity.' }
    if (@($cfg.sources).Count -eq 0) { throw 'List source files explicitly in project.json.' }
    if ($cfg.optimization -notin @('Speed','Area')) { throw 'optimization must be Speed or Area.' }
    if ($cfg.optimizationLevel -notin @(1,2)) { throw 'optimizationLevel must be 1 or 2.' }
    $files = New-Object 'System.Collections.Generic.List[string]'
    foreach ($s in $cfg.sources) {
        if ($s.language -notin @('verilog','vhdl')) { throw 'Source language must be verilog or vhdl.' }
        if ($s.library -notmatch '^[A-Za-z][A-Za-z0-9_]*$') { throw 'Each source needs a valid library (normally work).' }
        $null = Resolve-Input $dir $s.path
        $files.Add([string]$s.path)
    }
    foreach ($f in @($cfg.includeFiles) + @($cfg.netlists)) {
        if ($f) { $null = Resolve-Input $dir $f; $files.Add([string]$f) }
    }
    foreach ($inc in $cfg.includeDirs) {
        if ($inc -notmatch '^[A-Za-z0-9_/-]+$' -or $inc -match '(^|/)\.\.(/|$)') { throw "Invalid include directory: $inc" }
        if (-not (Test-Path -LiteralPath (Join-Path $dir $inc) -PathType Container)) { throw "Missing include directory: $inc" }
    }
    foreach ($define in $cfg.defines) {
        if ($define -notmatch '^[A-Za-z_][A-Za-z0-9_]*(=[A-Za-z0-9_]+)?$') { throw "Unsupported define: $define" }
    }
    if ($cfg.ucf) { $null = Resolve-Input $dir $cfg.ucf; $files.Add([string]$cfg.ucf) }
    if ($Target -ne 'synth' -and (-not $cfg.ucf -or $cfg.constraintsReviewed -ne $true)) {
        throw 'Implementation needs a UCF and constraintsReviewed=true after confirming clocks, pins and timing intent.'
    }
    return @{ Directory=$dir; Config=$cfg; Files=@($files | Sort-Object -Unique) }
}
function Invoke-Doctor([switch]$TransferTest) {
    foreach ($exe in @('ssh','sftp')) { $null = Get-Command $exe -ErrorAction Stop }
    $helpText = Invoke-Ssh ('call ' + $script:Settings + ' >nul && xst -help && bitgen -help')
    Write-Host (($helpText -split "`n" | Where-Object { $_ -match '^Release ' }) -join "`n")
    Invoke-Sftp @('pwd')
    Write-Host 'PASS: SSH, SFTP, ISE XST and Bitgen startup. License and full build NOT verified.'
    if ($TransferTest) {
        $id = 'probe-' + [Guid]::NewGuid().ToString('N')
        $local = Join-Path "$root\tools\.work" $id
        New-Item -ItemType Directory -Force -Path $local | Out-Null
        Write-Utf8 "$local\sent.txt" $id
        $probeScript = @('@echo off','cd /d "%~dp0"',('call "' + $script:Settings + '" >nul'),'if errorlevel 1 exit /b 1','xst -help > startup.log 2>&1','if errorlevel 1 exit /b 1','echo COMPLETE>probe.status','exit /b 0')
        Write-Utf8 "$local\probe.cmd" ($probeScript -join "`r`n")
        $remote = "$script:RemoteRoot/$id"
        $windowsRemote = $remote.Replace('/','\')
        $null = Invoke-Ssh ('if not exist "' + $windowsRemote + '" mkdir "' + $windowsRemote + '"')
        $unix = $local.Replace('\','/')
        Invoke-Sftp @("put -r `"$unix`" `"/$remote/inputs`"")
        $null = Invoke-Ssh ('cmd /d /c "' + ($remote + '/inputs/probe.cmd').Replace('/','\') + '"')
        Invoke-Sftp @("get -r `"/$remote/inputs`" `"$unix/received`"")
        if ((Get-FileHash "$local\sent.txt").Hash -ne (Get-FileHash "$local\received\sent.txt").Hash) { throw 'Transfer hash mismatch.' }
        if ((Get-Content "$local\received\probe.status" -Raw).Trim() -ne 'COMPLETE') { throw 'Remote CMD startup failed.' }
        Write-Host "PASS: recursive transfer SHA256 and remote CMD/ISE startup. Probe retained: $remote"
    }
}
function New-RunScript($ProjectData, [string]$Target, [string]$InputDir) {
    $cfg = $ProjectData.Config
    $toolDir = Join-Path $InputDir '_tool'
    New-Item -ItemType Directory -Path $toolDir | Out-Null
    $prj = foreach ($s in $cfg.sources) { '{0} {1} "../inputs/{2}"' -f $s.language,$s.library,$s.path }
    Write-Utf8 "$toolDir\sources.prj" ($prj -join "`r`n")
    $xst = @('run','-ifn ../inputs/_tool/sources.prj','-ifmt mixed','-ofn design.ngc','-ofmt NGC',"-p $($cfg.device)","-top $($cfg.top)","-opt_mode $($cfg.optimization)","-opt_level $($cfg.optimizationLevel)")
    if (@($cfg.includeDirs).Count) { $xst += '-vlgincdir {' + (($cfg.includeDirs | ForEach-Object { '../inputs/' + $_ }) -join ' ') + '}' }
    if (@($cfg.defines).Count) { $xst += '-define {' + ($cfg.defines -join ' ') + '}' }
    Write-Utf8 "$toolDir\synth.xst" ($xst -join "`r`n")
    $steps = @(@{Name='synth'; Cmd='xst -ifn ../inputs/_tool/synth.xst -ofn synthesis.srp'; Output='design.ngc'})
    if ($Target -ne 'synth') {
        $sd = (@($cfg.netlists | ForEach-Object { [IO.Path]::GetDirectoryName($_).Replace('\','/') } | Sort-Object -Unique) | ForEach-Object { '-sd "../inputs/' + $_ + '"' }) -join ' '
        $steps += @{Name='translate'; Cmd="ngdbuild -p $($cfg.device) -uc ../inputs/$($cfg.ucf) $sd design.ngc design.ngd"; Output='design.ngd'}
        $steps += @{Name='map'; Cmd="map -p $($cfg.device) -o mapped.ncd design.ngd design.pcf"; Output='mapped.ncd'}
        $steps += @{Name='par'; Cmd='par mapped.ncd routed.ncd design.pcf'; Output='routed.ncd'}
        $steps += @{Name='timing'; Cmd='trce -v 10 -u 10 -o timing.twr routed.ncd design.pcf'; Output='timing.twr'}
    }
    if ($Target -eq 'bitstream') { $steps += @{Name='bitgen'; Cmd='bitgen routed.ncd design.bit design.pcf'; Output='design.bit'} }
    $bat = @('@echo off','setlocal','cd /d "%~dp0..\..\out"','if errorlevel 1 exit /b 1',('call "' + $script:Settings + '" > environment.log 2>&1'),'if errorlevel 1 exit /b 1')
    foreach ($step in $steps) {
        $bat += @("echo RUNNING:$($step.Name)>run.status", "echo Starting $($step.Name)", ($step.Cmd + " > $($step.Name).log 2>&1"), 'set ISE_EXIT=%ERRORLEVEL%', "echo %ISE_EXIT% > $($step.Name).exitcode", 'if not "%ISE_EXIT%"=="0" goto failed', "if not exist $($step.Output) goto failed")
    }
    $bat += @('echo COMPLETE>run.status','exit /b 0',':failed','echo FAILED>>run.status','exit /b 1')
    Write-Utf8 "$toolDir\run.cmd" ($bat -join "`r`n")
}
function Invoke-Build([string]$Name, [string]$Target) {
    $p = Read-Project $Name $Target
    $id = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
    $run = Join-Path $p.Directory "artifacts\$id"
    $inputs = Join-Path $run 'inputs'
    New-Item -ItemType Directory -Force -Path $inputs | Out-Null
    $hashes = foreach ($relative in $p.Files) {
        $dest = Join-Path $inputs $relative
        New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
        Copy-Item -LiteralPath (Join-Path $p.Directory $relative) -Destination $dest
        @{ path=$relative; sha256=(Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash }
    }
    # Include lookup directories may be empty; create them in the staged snapshot.
    foreach ($inc in $p.Config.includeDirs) { New-Item -ItemType Directory -Force -Path (Join-Path $inputs $inc) | Out-Null }
    New-RunScript $p $Target $inputs
    $meta = @{ project=$Name; runId=$id; stage=$Target; config=$p.Config; files=@($hashes); host=$script:RemoteHost; toolchain='ISE 14.7 nt (verify logs)'; status='prepared' }
    Write-Json "$run\run.json" $meta
    $remote = "$script:RemoteRoot/$Name/$id"
    $null = Invoke-Ssh ('mkdir "' + ($remote + '/out').Replace('/','\') + '"')
    Invoke-Sftp @("put -r `"$($inputs.Replace('\','/'))`" `"/$remote/inputs`"")
    $meta.status = 'running'; Write-Json "$run\run.json" $meta
    $remoteError = $null
    try { Write-Host (Invoke-Ssh ('cmd /d /c "' + ($remote + '/inputs/_tool/run.cmd').Replace('/','\') + '"')) }
    catch { $remoteError = $_.Exception.Message; Write-Utf8 "$run\connection-error.txt" $remoteError }
    Receive-Build $Name $id
    if ($remoteError) { throw "Remote execution failed or connection interrupted. Inspect $run. $remoteError" }
    $status = Get-Content -LiteralPath "$run\results\run.status" -Raw
    if ($status.Trim() -ne 'COMPLETE') { throw "Build did not complete: $run" }
    Write-Host "PASS: tool flow completed. Timing assessment is separate. Results: $run\results"
    return $id
}
function Receive-Build([string]$Name, [string]$Id) {
    Assert-Name $Name
    if ($Id -notmatch '^\d{8}-\d{6}-[a-f0-9]{8}$') { throw 'Invalid run ID.' }
    $run = Join-Path "$root\projects\$Name\artifacts" $Id
    $metaPath = Join-Path $run 'run.json'
    $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
    if ($meta.project -ne $Name -or $meta.runId -ne $Id) { throw 'Run metadata mismatch.' }
    # Download to a new folder each time so a retry cannot leave stale results.
    $incoming = Join-Path $run ('download-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
    $remote = "$script:RemoteRoot/$Name/$Id/out"
    Invoke-Sftp @("get -r `"/$remote`" `"$($incoming.Replace('\','/'))`"")
    $results = Join-Path $run 'results'
    if (Test-Path -LiteralPath $results) { Move-Item -LiteralPath $results -Destination (Join-Path $run ('previous-' + [Guid]::NewGuid().ToString('N').Substring(0,8))) }
    Move-Item -LiteralPath $incoming -Destination $results
    $state = 'unknown'
    if (Test-Path -LiteralPath "$results\run.status") { $state = (Get-Content -LiteralPath "$results\run.status" -Raw).Trim() }
    $meta.status = $state
    Write-Json $metaPath $meta
    $summary = @("Project: $Name", "Run: $Id", "Tool flow: $state", 'Timing: NEEDS_REVIEW (not automatically certified)', 'Inspect timing.twr for failed constraints and unconstrained paths.', 'A generated bitstream is not a board-safety confirmation.')
    Write-Utf8 "$run\summary.txt" ($summary -join "`r`n")
    Write-Host ($summary -join "`n")
    if ($state -match 'FAILED') { throw "Remote build failed. Logs: $results" }
}

#-----------------------------------------------------------------------------
# Additional entry points. Loaded last so that everything above (and the
# $script: settings) is available to them.
#-----------------------------------------------------------------------------
. "$PSScriptRoot\ise-sim.ps1"
. "$PSScriptRoot\ise-report.ps1"
. "$PSScriptRoot\ise-verify.ps1"
. "$PSScriptRoot\ise-program.ps1"
. "$PSScriptRoot\ise-probe-diag.ps1"
