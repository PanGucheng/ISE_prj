#Requires -Version 7.0
# Isolated orchestration tests for the local ISE toolchain.
# SSH/SFTP/ISE are simulated by a filesystem-backed fake remote; no real build,
# no real simulation and no network access happens here. The synthesis report
# written by the fake remote is marked MOCK and is only used to exercise the
# parsers. Real evidence lives in projects/*/artifacts.
$ErrorActionPreference = 'Stop'
$workspace = Split-Path $PSScriptRoot
$root = Join-Path $PSScriptRoot ('.work/test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path "$root/templates" | Out-Null
Copy-Item "$workspace/templates/project.json" "$root/templates/project.json"
. "$PSScriptRoot/ise-tools.ps1"

function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Expect-Failure([scriptblock]$Action, [string]$Pattern) {
    try { $null = & $Action } catch { if ($_.Exception.Message -match $Pattern) { return }; throw }
    throw "Expected failure: $Pattern"
}

#=============================================================================
# Minimal fixture helpers
#=============================================================================
function Write-FixtureConfig([string]$ProjectName, [hashtable]$Overrides) {
    $config = [ordered]@{
        device             = 'xc3s50an-4-tqg144'
        top                = 'top'
        sources            = @(@{ path = 'src/top.v'; language = 'verilog'; library = 'work' })
        includeDirs        = @()
        includeFiles       = @()
        defines            = @()
        netlists           = @()
        ucf                = 'constraints/top.ucf'
        constraintsReviewed = $false
        optimization       = 'Speed'
        optimizationLevel  = 1
        simulations        = @(
            [ordered]@{ name = 'one'; top = 'tb_one'; sources = @('sim/tb_one.v'); generics = [ordered]@{}; timeoutSeconds = 30; passPattern = 'MOCK_TB: PASS'; failPattern = 'MOCK_TB: FAIL' },
            [ordered]@{ name = 'two'; top = 'tb_two'; sources = @('sim/tb_two.v'); generics = [ordered]@{ TB_MODE = '0' }; timeoutSeconds = 30; passPattern = 'MOCK_TB: PASS'; failPattern = 'MOCK_TB: FAIL' }
        )
        verification       = [ordered]@{
            expectImplementationBlocked = $true
            clockName                   = 'clk'
            resetNames                  = @('rst_n', 'rst_n_sync')
            forbiddenEdgeSignals        = @('clk_2m', 'audio_out')
        }
    }
    foreach ($key in $Overrides.Keys) { $config[$key] = $Overrides[$key] }
    Write-Json "$root/projects/$ProjectName/project.json" $config
}

function New-Fixture([string]$ProjectName, [hashtable]$Overrides = @{}) {
    if (-not (Test-Path "$root/projects/$ProjectName")) { New-IseProject $ProjectName | Out-Null }
    foreach ($sub in @('src', 'sim', 'constraints')) { New-Item -ItemType Directory -Force -Path "$root/projects/$ProjectName/$sub" | Out-Null }
    Write-Utf8 "$root/projects/$ProjectName/src/top.v" @'
module top(input wire clk, input wire rst_n, output reg b);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) b <= 1'b0; else b <= ~b;
    end
endmodule
'@
    Write-Utf8 "$root/projects/$ProjectName/sim/tb_one.v" 'module tb_one; initial begin $display("MOCK_TB: PASS"); $finish; end endmodule'
    Write-Utf8 "$root/projects/$ProjectName/sim/tb_two.v" 'module tb_two; initial begin $display("MOCK_TB: PASS"); $finish; end endmodule'
    Write-Utf8 "$root/projects/$ProjectName/constraints/top.ucf" "# All constraints are TODO comments in this fixture.`n"
    Write-FixtureConfig $ProjectName $Overrides
}

#=============================================================================
# Fake remote: a directory tree that behaves like the Win7 build host
#=============================================================================
$script:Scenario = 'pass'   # pass | fusefail | simfail | no-pattern | fail-pattern | timeout
$script:Mode = 'success'    # success | failure | disconnect (build flow)
$script:SynthWarnings = 0   # XST warning count written into the mock synthesis report
$script:ProgProbe = 'ok'     # ok | nocable | mismatch | twoDevices
$script:ProgProgram = 'ok'   # ok | timeout | interrupted | fail
$script:ProgVerify = 'ok'    # ok | fail | notapplicable | noreport
$script:Remote = $null
$script:ImpactSteps = New-Object System.Collections.Generic.List[string]

function Get-FakeBsdl {
    return @'
-- MOCK BSDL (unit test fixture, not a real Xilinx file)
attribute INSTRUCTION_LENGTH of XC3S50AN_TQ144 : entity is 6;
attribute IDCODE_REGISTER of XC3S50AN_TQ144 : entity is "XXXX" & "0010011" &
    "000010000" & "00001001001" & "1";
'@
}
function New-FakeProbeLog {
    switch ($script:ProgProbe) {
        'nocable' {
            return @'
Release 14.7 - iMPACT P.20131013 (nt)
INFO:iMPACT - Digilent Plugin: found 0 device(s).
ERROR:iMPACT - Cable is not detected. Please connect a cable.
'@
        }
        'mismatch' {
            return @'
Release 14.7 - iMPACT P.20131013 (nt)
INFO:iMPACT - Digilent Plugin: opening device: "JtagHs2", SN:210241672559
INFO:iMPACT - Digilent Plugin: Serial Number: 210241672559
INFO:iMPACT - Digilent Plugin: JTAG Clock Frequency: 10000000 Hz
Identifying chain contents...done.
'1': IDCODE = 0x04001093
'1': : Manufacturer's ID = Xilinx xc6slx9, Version : 2
'@
        }
        'twoDevices' {
            return @'
Release 14.7 - iMPACT P.20131013 (nt)
INFO:iMPACT - Digilent Plugin: opening device: "JtagHs2", SN:210241672559
INFO:iMPACT - Digilent Plugin: JTAG Clock Frequency: 10000000 Hz
Identifying chain contents...done.
'1': IDCODE = 0x02610093
'1': : Manufacturer's ID = Xilinx xc3s50an, Version : 4
'2': IDCODE = 0x04001093
'2': : Manufacturer's ID = Xilinx xc6slx9, Version : 2
'@
        }
        default {
            return @'
Release 14.7 - iMPACT P.20131013 (nt)
INFO:iMPACT - Digilent Plugin: Plugin Version: 2.4.4
INFO:iMPACT - Digilent Plugin: found 1 device(s).
INFO:iMPACT - Digilent Plugin: opening device: "JtagHs2", SN:210241672559
INFO:iMPACT - Digilent Plugin: Product Name: Digilent JTAG-HS2
INFO:iMPACT - Digilent Plugin: Serial Number: 210241672559
INFO:iMPACT - Digilent Plugin: JTAG Clock Frequency: 10000000 Hz
Identifying chain contents...'0': : Manufacturer's ID = Xilinx xc3s50an, Version : 0
INFO:iMPACT:501 - '1': Added Device xc3s50an successfully.
'1': IDCODE is '00000010011000010000000010010011'
'1': IDCODE is '02610093' (in hex).
'1': : Manufacturer's ID = Xilinx xc3s50an, Version : 0
Elapsed time =      1 sec.
'@
        }
    }
}

function Get-RemoteRun([string]$RemotePath) {
    $m = [regex]::Match($RemotePath, '(?<id>(?:sim-|verify-|probe-|program-)?\d{8}-\d{6}-[a-f0-9]{8})/(?<rest>[^"]+)$')
    if (-not $m.Success) { throw "Unexpected remote path in test mock: $RemotePath" }
    return @{ Id = $m.Groups['id'].Value; Rest = $m.Groups['rest'].Value.Replace('/', '\') }
}
function Initialize-FakeRemote([string]$RunId) {
    $dir = Join-Path $root ('remote-' + $RunId)
    foreach ($sub in @('inputs', 'results', 'out', 'work')) { New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null }
    $script:Remote = $dir
    return $dir
}
function Invoke-Ssh([string]$RemoteCommand) {
    if ($RemoteCommand -match 'mkdir') {
        $id = [regex]::Match($RemoteCommand, '(?<id>(?:sim-|verify-|probe-|program-)?\d{8}-\d{6}-[a-f0-9]{8})')
        if ($id.Success) { $null = Initialize-FakeRemote $id.Groups['id'].Value }
        return ''
    }
    if ($RemoteCommand -match 'if exist .*\.bsd') { return 'FOUND' }
    if ($RemoteCommand -match 'dir /b /s .*\.bsd') { return 'C:\Xilinx\14.7\ISE_DS\ISE\spartan3a\data\xc3s50an_tq144.bsd' }
    if ($RemoteCommand -match 'taskkill|echo TIMEOUT') {
        $statusFile = Join-Path $script:Remote 'results/run.status'
        Add-Content -LiteralPath $statusFile -Value 'TIMEOUT'
        return ''
    }
    if ($RemoteCommand -match 'sim_fuse\.cmd') {
        if ($script:Scenario -eq 'fusefail') {
            Write-Utf8 "$script:Remote/results/fuse.exitcode" '1'
            Write-Utf8 "$script:Remote/results/fuse.status" 'FAILED'
            Write-Utf8 "$script:Remote/results/run.status" "RUNNING:fuse`nFAILED"
            Write-Utf8 "$script:Remote/results/fuse.log" 'MOCK fuse failure (unit test)'
            throw 'SSH exit 1: simulated fuse failure'
        }
        Write-Utf8 "$script:Remote/results/fuse.exitcode" '0'
        Write-Utf8 "$script:Remote/results/fuse.status" 'COMPLETE'
        return ''
    }
    if ($RemoteCommand -match '_tool[\\/]run\.cmd') {
        switch ($script:Mode) {
            'success' {
                Write-Utf8 "$script:Remote/out/run.status" 'COMPLETE'
                Write-Utf8 "$script:Remote/out/design.ngc" 'MOCK OUTPUT, NOT A REAL NETLIST'
                Write-Utf8 "$script:Remote/out/synth.exitcode" '0'
                Write-Utf8 "$script:Remote/out/synthesis.srp" ("MOCK SYNTHESIS REPORT (unit test fixture, not a real XST run)`n" +
                    "Number of errors   :    0 (   0 filtered)`n" +
                    "Number of warnings :    $($script:SynthWarnings) (   0 filtered)`n" +
                    "# Registers                                            : 231`n" +
                    "# IOs                              : 20`n")
            }
            'failure' { Write-Utf8 "$script:Remote/out/run.status" "RUNNING:synth`nFAILED"; throw 'SSH exit 1: simulated tool failure' }
            'disconnect' { Write-Utf8 "$script:Remote/out/run.status" 'RUNNING:synth'; throw 'SSH exit 255: simulated interruption' }
        }
        return ''
    }
    if ($RemoteCommand -match 'sim_run\.cmd') {
        switch ($script:Scenario) {
            'simfail' {
                Write-Utf8 "$script:Remote/results/simulation.exitcode" '1'
                Write-Utf8 "$script:Remote/results/simulation.log" 'MOCK LOG (unit test)'
                Write-Utf8 "$script:Remote/results/run.status" "RUNNING:simulation`nFAILED"
                throw 'SSH exit 1: simulated simulation failure'
            }
            'no-pattern' {
                Write-Utf8 "$script:Remote/results/simulation.exitcode" '0'
                Write-Utf8 "$script:Remote/results/simulation.log" "MOCK LOG: no verdict line at all`n"
                Write-Utf8 "$script:Remote/results/run.status" 'COMPLETE'
            }
            'fail-pattern' {
                Write-Utf8 "$script:Remote/results/simulation.exitcode" '0'
                Write-Utf8 "$script:Remote/results/simulation.log" "MOCK LOG`nMOCK_TB: FAIL (checks=1, errors=1)`n"
                Write-Utf8 "$script:Remote/results/run.status" 'COMPLETE'
            }
            default {
                Write-Utf8 "$script:Remote/results/simulation.exitcode" '0'
                Write-Utf8 "$script:Remote/results/simulation.log" "MOCK LOG`nMOCK_TB: PASS (checks=1, errors=0)`n"
                Write-Utf8 "$script:Remote/results/run.status" 'COMPLETE'
            }
        }
        return ''
    }
    throw "Unexpected remote command in test mock: $RemoteCommand"
}
function Invoke-SshTimed([string]$RemoteCommand, [int]$TimeoutSeconds) {
    if ($script:Scenario -eq 'timeout' -and $RemoteCommand -match 'run\.cmd' -and $RemoteCommand -notmatch '_tool' -and $RemoteCommand -notmatch 'run_(probe|program|verify)') {
        throw 'TIMEOUT: simulated simulation timeout'
    }
    if ($RemoteCommand -match 'run_(probe|program|verify)\.cmd') {
        $step = $Matches[1]
        $script:ImpactSteps.Add($step)
        $results = Join-Path $script:Remote 'results'
        New-Item -ItemType Directory -Force -Path $results | Out-Null
        if ($step -eq 'program') {
            if ($script:ProgProgram -eq 'timeout') { throw 'TIMEOUT: simulated impact timeout' }
            if ($script:ProgProgram -eq 'interrupted') { throw 'SSH exit 255: simulated connection drop during program' }
        }
        switch ($step) {
            'probe' { Write-Utf8 "$results/probe.log" (New-FakeProbeLog) }
            'program' {
                if ($script:ProgProgram -eq 'fail') {
                    Write-Utf8 "$results/program.log" "ERROR:iMPACT:1234 - simulated programming failure`n"
                } else {
                    Write-Utf8 "$results/program.log" "INFO:iMPACT - programming device '1'`nProgramming operation completed successfully`n"
                }
            }
            'verify' {
                switch ($script:ProgVerify) {
                    'fail' { Write-Utf8 "$results/verify.log" "ERROR:iMPACT:4321 - simulated verify mismatch`n" }
                    'notapplicable' { Write-Utf8 "$results/verify.log" "ERROR:iMPACT:9 - verify is not applicable for this configuration mode`n" }
                    'noreport' { Write-Utf8 "$results/verify.log" "INFO:iMPACT - finished`n" }
                    default { Write-Utf8 "$results/verify.log" "Verify operation completed successfully`n" }
                }
            }
        }
        Write-Utf8 "$results/$step.status" 'COMPLETE'
        Write-Utf8 "$results/$step.exitcode" '0'
        return ''
    }
    return Invoke-Ssh $RemoteCommand
}
function Invoke-Sftp([string[]]$Lines) {
    foreach ($line in $Lines) {
        if ($line -match '^put -r "([^"]+)" "([^"]+)"$') {
            $tail = Get-RemoteRun $Matches[2]
            $dest = Join-Path $script:Remote $tail.Rest
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            $children = @(Get-ChildItem -LiteralPath $Matches[1] -Force)
            foreach ($child in $children) { Copy-Item -LiteralPath $child.FullName -Destination $dest -Recurse -Force }
        } elseif ($line -match '^put "([^"]+)" "([^"]+)"$') {
            $tail = Get-RemoteRun $Matches[2]
            $dest = Join-Path $script:Remote $tail.Rest
            New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
            Copy-Item -LiteralPath $Matches[1] -Destination $dest -Force
        } elseif ($line -match '^get -r "([^"]+)" "([^"]+)"$') {
            $tail = Get-RemoteRun $Matches[1]
            $src = Join-Path $script:Remote $tail.Rest
            Assert (Test-Path -LiteralPath $src) "Mock remote path missing: $src"
            New-Item -ItemType Directory -Force -Path $Matches[2] | Out-Null
            foreach ($child in @(Get-ChildItem -LiteralPath $src -Force)) {
                Copy-Item -LiteralPath $child.FullName -Destination $Matches[2] -Recurse -Force
            }
        } elseif ($line -match '^get "([^"]+)" "([^"]+)"$') {
            if ($Matches[1] -notmatch '\.bsd$') { throw "Unexpected SFTP get: $line" }
            New-Item -ItemType Directory -Force -Path (Split-Path $Matches[2]) | Out-Null
            Write-Utf8 $Matches[2] (Get-FakeBsdl)
        } else { throw "Unexpected SFTP request: $line" }
    }
}

#=============================================================================
# 1. Existing behaviour: template protection, config validation, build flow
#=============================================================================
New-IseProject 'fixture'
Expect-Failure { New-IseProject 'fixture' } 'Already exists'
Expect-Failure { Read-Project 'fixture' 'synth' } 'complete device'
New-Fixture 'fixture'
$null = Read-Project 'fixture' 'synth'
Expect-Failure { Read-Project 'fixture' 'implement' } 'UCF'
Expect-Failure { Resolve-Input "$root/projects/fixture" '../outside.v' } 'escapes'

Invoke-Build 'fixture' 'synth'
$first = Get-ChildItem "$root/projects/fixture/artifacts" -Directory | Where-Object { $_.Name -match '^\d{8}' } | Select-Object -First 1
Assert (Test-Path "$($first.FullName)/results/design.ngc") 'Results not fetched'
Write-Utf8 "$($first.FullName)/results/stale.txt" 'stale'
Receive-Build 'fixture' $first.Name
Assert (-not (Test-Path "$($first.FullName)/results/stale.txt")) 'Fetch mixed stale results'
$script:Mode = 'failure'
Expect-Failure { Invoke-Build 'fixture' 'synth' } 'Remote build failed'
$script:Mode = 'disconnect'
Expect-Failure { Invoke-Build 'fixture' 'synth' } 'interrupted'
$script:Mode = 'success'
Assert (@(Get-ChildItem "$root/projects/fixture/artifacts" -Directory | Where-Object { $_.Name -match '^\d{8}' }).Count -eq 3) 'Runs were not isolated'
Write-Host 'PASS: template protection, invalid config, missing input, path escape, UCF gate, results, fresh fetch, build failure, interruption and run isolation.'

#=============================================================================
# 2. Simulation configuration parser
#=============================================================================
$p = Read-Project 'fixture' 'synth'
$sims = @(Get-SimulationConfig $p)
Assert ($sims.Count -eq 2) 'Simulation config not parsed'
Assert ($sims[1].Generics.TB_MODE -eq '0') 'Generics not parsed'
Expect-Failure { Invoke-Simulation -ProjectName 'fixture' -Test 'does_not_exist' } 'Unknown simulation'
Write-FixtureConfig 'fixture' @{ simulations = @([ordered]@{ name = 'bad name'; top = 'tb'; sources = @('sim/tb_one.v'); passPattern = 'x' }) }
Expect-Failure { Invoke-Simulation -ProjectName 'fixture' -Test 'bad name' } 'Unsafe simulation name'
Write-FixtureConfig 'fixture' @{ simulations = @([ordered]@{ name = 'one'; top = 'tb_one'; sources = @('sim/tb_missing.v'); passPattern = 'MOCK_TB: PASS' }) }
Expect-Failure { Invoke-Simulation -ProjectName 'fixture' -Test 'one' } 'Missing input'
Write-FixtureConfig 'fixture' @{ simulations = @([ordered]@{ name = 'one'; top = 'tb_one'; sources = @('sim/tb_one.v'); generics = [ordered]@{ TB_BAD = '0; rm -rf /' }; passPattern = 'MOCK_TB: PASS' }) }
Expect-Failure { Invoke-Simulation -ProjectName 'fixture' -Test 'one' } 'Unsafe generic value'
Write-FixtureConfig 'fixture' @{}
Write-Host 'PASS: simulation config parsing rejects unknown names, unsafe tokens and missing testbench files.'

#=============================================================================
# 3. sim: PASS/FAIL judgement, generics, timeout, isolation
#=============================================================================
$script:Scenario = 'pass'
$results = @(Invoke-Simulation -ProjectName 'fixture' -Test 'two')
Assert ($results.Count -eq 1) 'sim did not return one result'
Assert ($results[0].Result -eq 'PASS') "sim expected PASS, got $($results[0].Result)"
$simRunDir = $results[0].RunDir
Assert (Test-Path "$simRunDir/sim.json") 'sim.json missing'
Assert (Test-Path "$simRunDir/summary.txt") 'summary.txt missing'
Assert (Test-Path "$simRunDir/results/simulation.log") 'simulation log not fetched'
$fuseCmd = Get-TextSafe "$script:Remote/inputs/sim_fuse.cmd"
Assert ($fuseCmd -match '--generic_top "TB_MODE=0"') 'generic did not reach the fuse command line'
Assert ($fuseCmd -match 'fuse -prj sim\.prj -top tb_two') 'fuse command malformed'
Assert (Test-Path "$script:Remote/inputs/sim_run.cmd") 'run wrapper not uploaded'
Assert (-not (Test-Path "$script:Remote/inputs/fuse.cmd")) 'a local fuse.cmd would shadow fuse.exe and recurse'
Assert (-not (Test-Path "$script:Remote/inputs/run.cmd")) 'a local run.cmd is avoided for the same reason'
$runCmd = Get-TextSafe "$script:Remote/inputs/sim_run.cmd"
Assert ($runCmd -match '-tclbatch run_all\.tcl') 'run step is missing -tclbatch'
Assert ($runCmd -notmatch 'generic_top') 'generic must not be passed to the run step'
Assert ((Get-TextSafe "$script:Remote/inputs/run_all.tcl") -match 'run all') 'run_all.tcl malformed'

Write-Utf8 "$simRunDir/results/stale-marker.txt" 'stale'
$results2 = @(Invoke-Simulation -ProjectName 'fixture' -Test 'two')
Assert ($results2[0].RunDir -ne $simRunDir) 'sim reused the previous run directory'
Assert (-not (Test-Path "$($results2[0].RunDir)/results/stale-marker.txt")) 'sim reused stale results'
Assert ((Get-TextSafe "$script:Remote/inputs/sim_fuse.cmd") -match 'if exist "tb_two\.exe" del /q') 'stale exe is not deleted before fuse'

$simDefs = @(Get-SimulationConfig $p)
$defOne = $simDefs | Where-Object { $_.Name -eq 'one' }
$defTwo = $simDefs | Where-Object { $_.Name -eq 'two' }

$script:Scenario = 'fusefail'
$r = Invoke-SingleSimulation -ProjectName 'fixture' -ProjectData $p -SimDef $defOne
Assert ($r.Result -eq 'FAIL') 'fuse failure must FAIL'
Assert ((@($r.Reasons) -join ' ') -match 'fuse exit code 1') 'fuse failure reason missing'
Expect-Failure { Invoke-Simulation -ProjectName 'fixture' -Test 'one' } 'Simulation FAILED'

$script:Scenario = 'no-pattern'
$r = Invoke-SingleSimulation -ProjectName 'fixture' -ProjectData $p -SimDef $defOne
Assert ($r.Result -eq 'FAIL') 'exit code 0 without passPattern must FAIL'
Assert ((@($r.Reasons) -join ' ') -match 'passPattern not found') 'missing passPattern reason absent'

$script:Scenario = 'fail-pattern'
$r = Invoke-SingleSimulation -ProjectName 'fixture' -ProjectData $p -SimDef $defOne
Assert ($r.Result -eq 'FAIL') 'failPattern must FAIL'
Assert ((@($r.Reasons) -join ' ') -match 'failPattern found') 'failPattern reason absent'

$script:Scenario = 'simfail'
$r = Invoke-SingleSimulation -ProjectName 'fixture' -ProjectData $p -SimDef $defOne
Assert ($r.Result -eq 'FAIL') 'simulation exit code != 0 must FAIL'
Assert ((@($r.Reasons) -join ' ') -match 'simulation exit code 1') 'simulation exit code reason absent'

$script:Scenario = 'timeout'
$r = Invoke-SingleSimulation -ProjectName 'fixture' -ProjectData $p -SimDef $defOne
Assert ($r.Result -eq 'FAIL') 'timeout must FAIL'
Assert ((@($r.Reasons) -join ' ') -match 'timed out') 'timeout reason absent'
Assert ((Get-TextSafe "$($r.RunDir)/results/run.status") -match 'TIMEOUT') 'TIMEOUT not written back'

$script:Scenario = 'pass'
Write-Host 'PASS: sim verdicts (PASS, fuse failure, missing pattern, failPattern, exit code, timeout), generics in fuse, no reuse of old files.'

#=============================================================================
# 4. report: parsers and missing artifacts
#=============================================================================
$buildId = @(Get-BuildRunIds 'fixture' | Where-Object { Test-Path "$root/projects/fixture/artifacts/$_/results/synthesis.srp" })[0]
Assert ($null -ne $buildId) 'no successful build run available for report tests'

# A synthetic but real-shaped build run (MOCK, unit test fixture only) so these
# assertions do not depend on what earlier sections happened to leave behind.
$synthRun = Join-Path "$root/projects/fixture/artifacts" '20260101-000000-abcdef00'
New-Item -ItemType Directory -Force -Path "$synthRun/results" | Out-Null
# keep the synthetic run older than the real ones so -Latest still means "newest real run"
(Get-Item -LiteralPath $synthRun).CreationTimeUtc = [datetime]'2026-01-01T00:00:00Z'
Write-Utf8 "$synthRun/run.json" (([ordered]@{ project = 'fixture'; runId = '20260101-000000-abcdef00'; stage = 'synth'; status = 'COMPLETE' } | ConvertTo-Json))
Write-Utf8 "$synthRun/results/run.status" 'COMPLETE'
Write-Utf8 "$synthRun/results/synth.exitcode" '0'
Write-Utf8 "$synthRun/results/design.ngc" 'MOCK OUTPUT, NOT A REAL NETLIST'
Write-Utf8 "$synthRun/results/synthesis.srp" @'
MOCK SYNTHESIS REPORT (unit test fixture, not a real XST run)
Number of errors   :    0 (   0 filtered)
Number of warnings :    0 (   0 filtered)
Final Register Report
# Registers                                            : 231
# IOs                              : 20
'@
Invoke-Report -ProjectName 'fixture' -RunId '20260101-000000-abcdef00' | Out-Null
$report = Get-Content "$synthRun/report.json" -Raw | ConvertFrom-Json
Assert ($report.synthesis.errors -eq 0) 'report did not parse the error count'
Assert ($report.synthesis.registers -eq 231) 'report did not parse the register count'
Assert ($report.synthesis.io -eq 20) 'report did not parse the IO count'
Assert ($report.synthesis.ngcExists -eq $true) 'report did not detect design.ngc'
Assert ($report.synthesis.result -eq 'PASS') 'report synthesis result should be PASS'
Assert ($report.timing.status -eq 'NOT_RUN') "timing without a report must be NOT_RUN, got $($report.timing.status)"

# the same run plus a synthetic timing.twr must never be reported as PASS
Write-Utf8 "$synthRun/results/timing.twr" "MOCK TIMING REPORT (unit test fixture)`nTiming constraint: TS_clk = PERIOD clk_group 20 ns HIGH 50%;`n"
Invoke-Report -ProjectName 'fixture' -RunId '20260101-000000-abcdef00' | Out-Null
$twrReport = Get-Content "$synthRun/report.json" -Raw | ConvertFrom-Json
Assert ($twrReport.timing.status -eq 'NEEDS_REVIEW') "a present timing report must be NEEDS_REVIEW, got $($twrReport.timing.status)"
Assert ($twrReport.timing.status -ne 'PASS') 'report must never claim Timing PASS by itself'

# missing results -> explicit NOT_AVAILABLE
$emptyRun = Join-Path "$root/projects/fixture/artifacts" '20260101-000000-abcdef02'
New-Item -ItemType Directory -Force -Path $emptyRun | Out-Null
(Get-Item -LiteralPath $emptyRun).CreationTimeUtc = [datetime]'2026-01-01T00:00:02Z'
Write-Utf8 "$emptyRun/run.json" (([ordered]@{ project = 'fixture'; runId = '20260101-000000-abcdef02'; stage = 'synth'; status = 'prepared' } | ConvertTo-Json))
Expect-Failure { Invoke-Report -ProjectName 'fixture' -RunId '20260101-000000-abcdef02' } 'NOT_AVAILABLE'
Expect-Failure { Invoke-Report -ProjectName 'fixture' -RunId '20260101-000000-abcdef03' } 'not found'

# results/ exists but synthesis.srp is missing -> NOT_AVAILABLE, listing the gap
$partialRun = Join-Path "$root/projects/fixture/artifacts" '20260101-000000-abcdef04'
New-Item -ItemType Directory -Force -Path "$partialRun/results" | Out-Null
(Get-Item -LiteralPath $partialRun).CreationTimeUtc = [datetime]'2026-01-01T00:00:04Z'
Write-Utf8 "$partialRun/run.json" (([ordered]@{ project = 'fixture'; runId = '20260101-000000-abcdef04'; stage = 'synth'; status = 'COMPLETE' } | ConvertTo-Json))
Write-Utf8 "$partialRun/results/run.status" 'COMPLETE'
Write-Utf8 "$partialRun/results/synth.exitcode" '0'
Write-Utf8 "$partialRun/results/design.ngc" 'MOCK OUTPUT, NOT A REAL NETLIST'
Expect-Failure { Invoke-Report -ProjectName 'fixture' -RunId '20260101-000000-abcdef04' } 'NOT_AVAILABLE'
$partialReport = Get-Content "$partialRun/report.json" -Raw | ConvertFrom-Json
Assert ($partialReport.dataStatus -eq 'NOT_AVAILABLE') 'missing synthesis.srp must make dataStatus NOT_AVAILABLE'
Assert ($partialReport.artifacts.synthesisSrp -eq $false) 'synthesis.srp presence not distinguished'
Assert ($partialReport.artifacts.synthExitcode -eq $true) 'synth.exitcode presence not distinguished'
Assert ($partialReport.artifacts.runStatus -eq $true) 'run.status presence not distinguished'
Assert ($partialReport.artifacts.designNgc -eq $true) 'design.ngc presence not distinguished'
Assert (@($partialReport.artifacts.missingFiles) -contains 'synthesis.srp') 'the missing file is not listed'

# a run whose tool flow actually FAILED stays AVAILABLE and reports FAIL (its
# missing artifacts are failure evidence, not missing evidence)
$failedRun = Join-Path "$root/projects/fixture/artifacts" '20260101-000000-abcdef05'
New-Item -ItemType Directory -Force -Path "$failedRun/results" | Out-Null
(Get-Item -LiteralPath $failedRun).CreationTimeUtc = [datetime]'2026-01-01T00:00:05Z'
Write-Utf8 "$failedRun/run.json" (([ordered]@{ project = 'fixture'; runId = '20260101-000000-abcdef05'; stage = 'synth'; status = 'FAILED' } | ConvertTo-Json))
Write-Utf8 "$failedRun/results/run.status" "RUNNING:synth`nFAILED"
Invoke-Report -ProjectName 'fixture' -RunId '20260101-000000-abcdef05' | Out-Null
$failedReport = Get-Content "$failedRun/report.json" -Raw | ConvertFrom-Json
Assert ($failedReport.dataStatus -eq 'AVAILABLE') 'a failed tool flow must stay AVAILABLE'
Assert ($failedReport.synthesis.result -eq 'FAIL') 'a failed tool flow must report synthesis FAIL'
Assert (@($failedReport.artifacts.missingFiles).Count -gt 0) 'missing artifacts of a failed flow should be listed'
$newestId = (Get-BuildRunIds 'fixture')[0]
Invoke-Report -ProjectName 'fixture' -Latest | Out-Null
Assert (Test-Path "$root/projects/fixture/artifacts/$newestId/report.json") '-Latest did not report the newest build run'

# pure parser behaviour
$latchFacts = Get-SynthesisFacts -ReportText "MOCK`nNumber of errors   :    0`nWARNING:Xst:737 - Latch inferred for signal <x>" -NgcExists $true -ExitCode 0 -ToolFlow 'COMPLETE'
Assert ($latchFacts.Result -eq 'FAIL') 'a latch must fail the synthesis facts'
Assert ($latchFacts.Latches -ge 1) 'latch count not detected'
$noReport = Get-TimingFacts -TwrExists $false
Assert ($noReport.Status -eq 'NOT_RUN') 'missing timing report must be NOT_RUN'
Write-Host 'PASS: report parses real-shaped XST output, never claims timing PASS, and reports NOT_AVAILABLE for missing artifacts.'

#=============================================================================
# 5. verify: orchestration, implementation gate, failure propagation
#=============================================================================
function Get-LatestVerification([string]$ProjectName) {
    # newest by creation time: run ids in the same second differ only by suffix
    $dir = Get-ChildItem "$root/projects/$ProjectName/artifacts" -Directory |
        Where-Object { $_.Name -match '^verify-\d{8}-\d{6}-[a-f0-9]{8}$' } |
        Sort-Object -Property @{ Expression = 'CreationTimeUtc'; Descending = $true }, @{ Expression = 'Name'; Descending = $true } |
        Select-Object -First 1
    Assert ($null -ne $dir) 'no verification run directory found'
    return (Get-Content "$($dir.FullName)/verification.json" -Raw | ConvertFrom-Json)
}

$script:Scenario = 'pass'
$v = Invoke-Verification -ProjectName 'fixture'
Assert ($v.result -eq 'PASS') "verify expected PASS, got $($v.result)"
Assert ($v.stage -eq 'PRE_BOARD') "verify stage expected PRE_BOARD, got $($v.stage)"
Assert ($v.implementationGate.expectedBlocked -eq $true) 'gate expectation not read from project.json'
Assert ($v.implementationGate.actualBlocked -eq $true) 'gate did not detect the block'
Assert (@($v.simulations).Count -eq 2) 'verify did not run every enabled simulation'
Assert (-not (@($v.simulations | Where-Object { $_.result -ne 'PASS' }).Count)) 'verify reported a failing simulation'
Assert (Test-Path "$root/projects/fixture/artifacts/$($v.verifyId)/verification.json") 'verification.json missing'

$script:Scenario = 'fail-pattern'
Expect-Failure { Invoke-Verification -ProjectName 'fixture' } 'Verification FAILED'
$vFail = Get-LatestVerification 'fixture'
Assert ($vFail.result -eq 'FAIL') 'a failing testbench must fail the whole verification'
Assert ($vFail.simulationResult -eq 'FAIL') 'simulationResult not FAIL'
$script:Scenario = 'pass'

Write-FixtureConfig 'fixture' @{ verification = [ordered]@{ expectImplementationBlocked = $false; clockName = 'clk'; resetNames = @('rst_n', 'rst_n_sync'); forbiddenEdgeSignals = @('clk_2m', 'audio_out') } }
Expect-Failure { Invoke-Verification -ProjectName 'fixture' } 'Verification FAILED'
$vExpectOpen = Get-LatestVerification 'fixture'
Assert ($vExpectOpen.result -eq 'FAIL') 'blocked-but-not-expected must fail verification'
Assert ($vExpectOpen.implementationGate.result -eq 'FAIL') 'gate result not FAIL for blocked-but-not-expected'

Write-FixtureConfig 'fixture' @{ constraintsReviewed = $true; verification = [ordered]@{ expectImplementationBlocked = $true; clockName = 'clk'; resetNames = @('rst_n', 'rst_n_sync'); forbiddenEdgeSignals = @('clk_2m', 'audio_out') } }
Expect-Failure { Invoke-Verification -ProjectName 'fixture' } 'Verification FAILED'
$vUnexpectedOpen = Get-LatestVerification 'fixture'
Assert ($vUnexpectedOpen.result -eq 'FAIL') 'open-but-expected-blocked must fail verification'
Assert ($vUnexpectedOpen.implementationGate.actualBlocked -eq $false) 'gate did not detect an open implement stage'

Write-FixtureConfig 'fixture' @{ constraintsReviewed = $true; verification = [ordered]@{ expectImplementationBlocked = $false; clockName = 'clk'; resetNames = @('rst_n', 'rst_n_sync'); forbiddenEdgeSignals = @('clk_2m', 'audio_out') } }
$vOpen = Invoke-Verification -ProjectName 'fixture'
Assert ($vOpen.result -eq 'PASS') "expected PASS once implement is allowed, got $($vOpen.result)"
Assert ($vOpen.stage -eq 'IMPLEMENT_ALLOWED') "stage expected IMPLEMENT_ALLOWED, got $($vOpen.stage)"

# verification.failOnSynthesisWarnings = true -> warnings block the result
$script:SynthWarnings = 3
Write-FixtureConfig 'fixture' @{ constraintsReviewed = $false; verification = [ordered]@{ expectImplementationBlocked = $true; failOnSynthesisWarnings = $true; clockName = 'clk'; resetNames = @('rst_n', 'rst_n_sync'); forbiddenEdgeSignals = @('clk_2m', 'audio_out') } }
Expect-Failure { Invoke-Verification -ProjectName 'fixture' } 'Verification FAILED'
$vWarnBlocking = Get-LatestVerification 'fixture'
Assert ($vWarnBlocking.result -eq 'FAIL') 'warnings must fail verification when failOnSynthesisWarnings=true'
Assert ($vWarnBlocking.synthesis.warnings -eq 3) "warning count not parsed, got $($vWarnBlocking.synthesis.warnings)"
Assert ($vWarnBlocking.synthesis.warningsBlocking -eq $true) 'warningsBlocking not flagged'
Assert ($vWarnBlocking.synthesis.result -eq 'FAIL') 'synthesis result not FAIL under the warning policy'

# the flag is optional: without it the historical behaviour is kept
Write-FixtureConfig 'fixture' @{ constraintsReviewed = $false; verification = [ordered]@{ expectImplementationBlocked = $true; clockName = 'clk'; resetNames = @('rst_n', 'rst_n_sync'); forbiddenEdgeSignals = @('clk_2m', 'audio_out') } }
$vWarnIgnored = Invoke-Verification -ProjectName 'fixture'
Assert ($vWarnIgnored.result -eq 'PASS') 'warnings must not fail verification when the flag is absent'
Assert ($vWarnIgnored.synthesis.warnings -eq 3) 'warning count should still be reported'
Assert ($vWarnIgnored.synthesis.failOnWarnings -eq $false) 'failOnWarnings default should be false'
Assert ($vWarnIgnored.synthesis.warningsBlocking -eq $false) 'warningsBlocking should be false without the flag'
$script:SynthWarnings = 0
Write-FixtureConfig 'fixture' @{}
Write-Host 'PASS: verify aggregates synthesis, static checks and simulations, and honours expectImplementationBlocked in both directions.'

#=============================================================================
# 6. static checker detection power
#=============================================================================
Write-Utf8 "$root/projects/fixture/src/top.v" @'
module top(input wire clk, input wire clk_2m, input wire audio_out, output reg b);
    logic x;
    always @(posedge clk_2m) b <= 1'b0;
    always @(posedge audio_out) b <= 1'b1;
endmodule
'@
Write-Utf8 "$root/projects/fixture/constraints/top.ucf" "# comment`nNET `"clk`" LOC = P1;`n"
$badStatic = Invoke-StaticChecks -ProjectName 'fixture'
Assert ($badStatic.Result -eq 'FAIL') 'unsafe RTL/constraints must fail the static checks'
$all = @($badStatic.Errors) -join "`n"
Assert ($all -match 'FORBIDDEN_CLOCK') 'forbidden edge signal not detected'
Assert ($all -match 'SV_KEYWORD') 'SystemVerilog keyword not detected'
Assert ($all -match 'UCF_LOC') 'unreviewed LOC not detected'
Assert ($all -match 'posedge clk_2m') 'the offending edge is not named in the message'

Write-Utf8 "$root/projects/fixture/src/top.v" "module top(input wire clk, input wire rst_n, output reg b);`n  // audio_out is mentioned here only in a comment`n  always @(posedge clk or negedge rst_n) begin`n    if (!rst_n) b <= 1'b0; else b <= ~b;`n  end`nendmodule`n"
Write-Utf8 "$root/projects/fixture/constraints/top.ucf" "# All constraints are TODO comments in this fixture.`n"
$goodStatic = Invoke-StaticChecks -ProjectName 'fixture'
Assert ($goodStatic.Result -eq 'PASS') "clean RTL must pass static checks, got $(@($goodStatic.Errors) -join '; ')"
Assert ((@($goodStatic.Infos) -join ' ') -match 'COMMENT_ONLY') 'comment-only mention should be INFO, not an error'

Write-Utf8 "$root/projects/fixture/src/top.v" "module top(input wire clk, output reg b);`n  genvar i;`n  generate for (i = 0; i < 1; i = i + 1) begin : G`n    always @(posedge clk) b <= 1'b0;`n  end endgenerate`nendmodule`n"
$inlineGenvar = Invoke-StaticChecks -ProjectName 'fixture'
Assert ($inlineGenvar.Result -eq 'PASS') 'separate genvar declaration must pass'
Write-Utf8 "$root/projects/fixture/src/top.v" "module top(input wire clk, output reg b);`n  generate for (genvar i = 0; i < 1; i = i + 1) begin : G`n    always @(posedge clk) b <= 1'b0;`n  end endgenerate`nendmodule`n"
$inlineBad = Invoke-StaticChecks -ProjectName 'fixture'
Assert ($inlineBad.Result -eq 'FAIL') 'for (genvar ...) must fail'
Assert ((@($inlineBad.Errors) -join ' ') -match 'GENVAR') 'GENVAR code missing'
Write-Utf8 "$root/projects/fixture/src/top.v" "module top(input wire clk, input wire rst_n, output reg b);`n  always @(posedge clk or negedge rst_n) begin`n    if (!rst_n) b <= 1'b0; else b <= ~b;`n  end`nendmodule`n"
Write-Host 'PASS: static checks detect second clocks, SystemVerilog keywords, unreviewed LOC and inline genvar, without flagging comments.'

#=============================================================================
# 7. Backward compatibility: projects without the new sections
#=============================================================================
New-IseProject 'legacy' | Out-Null
New-Item -ItemType Directory -Force -Path "$root/projects/legacy/src" | Out-Null
Write-Utf8 "$root/projects/legacy/src/top.v" "module top(input wire clk, output reg b); always @(posedge clk) b <= ~b; endmodule"
$legacy = Get-Content "$root/projects/legacy/project.json" -Raw | ConvertFrom-Json
$legacy.device = 'xc3s50an-4-tqg144'
$legacy.top = 'top'
$legacy.sources = @(@{ path = 'src/top.v'; language = 'verilog'; library = 'work' })
Write-Json "$root/projects/legacy/project.json" $legacy
$null = Read-Project 'legacy' 'synth'
Expect-Failure { Invoke-Simulation -ProjectName 'legacy' -Test 'one' } 'no "simulations" section'
$legacyVerify = Invoke-Verification -ProjectName 'legacy'
Assert ($legacyVerify.simulationResult -eq 'NOT_CONFIGURED') 'legacy project should report NOT_CONFIGURED simulations'
Assert ($legacyVerify.result -eq 'PASS') "legacy project verify expected PASS, got $($legacyVerify.result)"
Invoke-BoardCheck -ProjectName 'legacy' | Out-Null
Write-Host 'PASS: projects without simulations/verification keep working for check/build, and sim/verify say so explicitly.'

#=============================================================================
# 8. probe / program (JTAG configuration and Spartan-3AN internal ISF)
#=============================================================================
function Get-LatestProgrammerRun([string]$ProjectName, [string]$Prefix) {
    $d = Get-ChildItem "$root/projects/$ProjectName/artifacts" -Directory | Where-Object { $_.Name -match ('^' + $Prefix) } |
        Sort-Object -Property @{ Expression = 'CreationTimeUtc'; Descending = $true }, @{ Expression = 'Name'; Descending = $true } |
        Select-Object -First 1
    Assert ($null -ne $d) "no $Prefix run directory found"
    return $d.FullName
}

$script:ProgProbe = 'ok'; $script:ProgProgram = 'ok'; $script:ProgVerify = 'ok'
$bitPath = Join-Path $root 'fixture-design.bit'
$bitHeader = "Bitstream generation date/time: 2026/09/14 16:00:00`r`nTarget Device: xc3s50an`r`nTarget Package: tq144`r`nTarget Speed: -4`r`n"
[IO.File]::WriteAllBytes($bitPath, ([Text.Encoding]::ASCII.GetBytes($bitHeader) + [byte[]](0..255)))

# --- pure parsers -----------------------------------------------------------
$devFacts = Get-ExpectedDeviceFacts 'xc3s50an-4-tqg144'
Assert ($devFacts.Part -eq 'xc3s50an') 'device part not parsed'
Assert ($devFacts.BsdlPackage -eq 'tq144') 'Pb-free package not normalised for BSDL lookup'
$bsdlId = Get-BsdlIdcode (Get-FakeBsdl)
Assert ($bsdlId.IdcodeHex -eq '0x02610093') "BSDL IDCODE parse failed: $($bsdlId.IdcodeHex)"
Assert ($bsdlId.InstructionLength -eq 6) 'BSDL instruction length not parsed'
$bitFacts = Get-BitFileFacts $bitPath
Assert ($bitFacts.Exists -and $bitFacts.Part -eq 'xc3s50an' -and $bitFacts.Package -eq 'tq144') 'bitstream header not parsed'
$noHeaderBit = Join-Path $root 'noheader.bit'
[IO.File]::WriteAllBytes($noHeaderBit, [byte[]](1..64))
Assert ((Get-BitFileFacts $noHeaderBit).HeaderParsed -eq $false) 'an absent bitstream header must be reported as not parsed'

# --- real ISE 14.7 bitgen header shape --------------------------------------
# Byte-for-byte prefix copied from a real `design.bit` produced by bitgen
# P.20131013: <letter><len_hi><len_lo><data..0x00>, a=design b=part c=date d=time e=bitcount
function New-BitgenHeader {
    param([string]$Design, [string]$Part, [string]$Date = '2026/09/14', [string]$Time = '20:46:12')
    $ms = New-Object System.IO.MemoryStream
    $ms.Write([byte[]](0x00, 0x09, 0x0f, 0xf0, 0x0f, 0xf0, 0x0f, 0xf0, 0x0f, 0xf0, 0x00, 0x00, 0x01), 0, 13)
    foreach ($pair in @(@('a', $Design), @('b', $Part), @('c', $Date), @('d', $Time))) {
        $data = [Text.Encoding]::ASCII.GetBytes($pair[1] + [char]0)
        $ms.WriteByte([byte][char]$pair[0])
        $ms.WriteByte([byte]([int]($data.Length / 256)))
        $ms.WriteByte([byte]([int]($data.Length % 256)))
        $ms.Write($data, 0, $data.Length)
    }
    $ms.Write([byte[]](0x65, 0x00, 0x00, 0xd5, 0x88), 0, 5)
    $ms.Write([byte[]](0xff) * 32, 0, 32)
    return $ms.ToArray()
}
$bitgenPath = Join-Path $root 'bitgen-shape.bit'
[IO.File]::WriteAllBytes($bitgenPath, (New-BitgenHeader -Design 'routed.ncd' -Part '3s50antqg144'))
$bgFacts = Get-BitFileFacts $bitgenPath
Assert ($bgFacts.HeaderParsed -eq $true) 'real bitgen header was not parsed'
Assert ($bgFacts.HeaderFormat -eq 'BITGEN') "bitgen header format mis-detected: $($bgFacts.HeaderFormat)"
Assert ($bgFacts.DesignName -eq 'routed.ncd') "bitgen design name not parsed: $($bgFacts.DesignName)"
Assert ($bgFacts.PartRaw -eq '3s50antqg144') "bitgen part field not parsed: $($bgFacts.PartRaw)"
Assert ($bgFacts.Part -eq 'xc3s50antqg144') "bitgen part not normalised: $($bgFacts.Part)"
Assert ($null -eq $bgFacts.Speed) 'the bitgen header has no speed grade; it must not be invented'
Assert ((Test-BitPartMatchesDevice -BitPartRaw $bgFacts.PartRaw -ExpectedPart 'xc3s50an' -ExpectedPackage 'tqg144') -eq $true) 'bitgen part must match the project device'
Assert ((Test-BitPartMatchesDevice -BitPartRaw '3s200avq100' -ExpectedPart 'xc3s50an' -ExpectedPackage 'tqg144') -eq $false) 'a bitstream for another device must not match'
Assert ((Test-BitPartMatchesDevice -BitPartRaw $null -ExpectedPart 'xc3s50an' -ExpectedPackage 'tqg144') -eq $null) 'an absent part field must be UNDETERMINED, not a match'
Assert ((Test-BitPartMatchesDevice -BitPartRaw '3s50antq144' -ExpectedPart 'xc3s50an' -ExpectedPackage 'tqg144') -eq $false) 'a different package string must not be treated as a match (no invented package-equivalence rule)'

# --- generated batch scripts (commands verified against the real install) ---
$jtagScript = New-ImpactProgramScript -Mode Jtag -Position 1 -RemoteBitFile 'C:\r\work\d.bit' -CablePort 'auto'
Assert ($jtagScript -match '(?m)^setMode -bs\r?$') 'JTAG script must start with setMode'
Assert ($jtagScript -match 'assignFile -p 1 -file') 'JTAG script missing assignFile'
Assert ($jtagScript -match 'program -p 1 -v') 'JTAG script must request verification'
Assert ($jtagScript -notmatch 'spi') 'JTAG script must not use SPI options'
$isfScript = New-ImpactProgramScript -Mode Isf -Position 2 -RemoteBitFile 'C:\r\work\d.bit' -CablePort 'auto'
Assert ($isfScript -match 'assignFileToAttachedFlash -p 2 -file') 'ISF script must assign to the attached flash'
Assert ($isfScript -match 'program -p 2 -spi') 'ISF script must use -spi'
Assert ((New-ImpactVerifyScript -Mode Isf -Position 2 -CablePort 'auto') -match 'verify -p 2 -spi') 'ISF verify script malformed'
Write-Host 'PASS: probe/program parsers and the generated iMPACT batch commands.'

# --- probe: cable + chain + device match ------------------------------------
$probe = Invoke-Probe -ProjectName 'fixture'
Assert ($probe.Facts.CableStatus -eq 'PASS') 'probe did not detect the mock cable'
Assert ($probe.Facts.ChainStatus -eq 'PASS') 'probe did not detect the mock chain'
Assert ($probe.Facts.DeviceCount -eq 1) 'probe did not parse exactly one device'
Assert ($probe.Facts.Devices[0].Idcode -eq '0x02610093') "IDCODE not parsed from the real transcript shape, got $($probe.Facts.Devices[0].Idcode)"
Assert ($probe.Matched -eq $true) 'probe did not match xc3s50an'
Assert ((Get-TextSafe "$($probe.RunDir)/generated/probe.cmd") -match 'readIdcode -p 1') 'probe script must read the IDCODE'
Assert ((Get-TextSafe "$($probe.RunDir)/summary.txt") -match 'Match\s+YES') 'probe summary missing the YES match'
Write-Host 'PASS: probe reports cable, chain and a matching XC3S50AN without writing anything.'

# --- probe: no cable --------------------------------------------------------
$script:ProgProbe = 'nocable'
Expect-Failure { Invoke-Probe -ProjectName 'fixture' } 'probe: result FAIL'
$noCableSummary = Get-TextSafe ((Get-LatestProgrammerRun 'fixture' 'probe-') + '/summary.txt')
Assert ($noCableSummary -match 'CABLE_NOT_FOUND') 'missing cable not reported'
Assert ($noCableSummary -match 'not visible inside fpga-vm') 'the USB/VM hint is missing'

# --- probe: identified device is not the project device ---------------------
$script:ProgProbe = 'mismatch'
Expect-Failure { Invoke-Probe -ProjectName 'fixture' } 'probe: result FAIL'
$mismatchSummary = Get-TextSafe ((Get-LatestProgrammerRun 'fixture' 'probe-') + '/summary.txt')
Assert ($mismatchSummary -match 'Match\s+NO') 'device mismatch not reported as NO'
Assert ($mismatchSummary -notmatch 'Match\s+YES') 'a mismatch must never report a match'
$script:ProgProbe = 'ok'

# --- program: preview only, no hardware write -------------------------------
$script:ImpactSteps.Clear()
Expect-Failure { Invoke-Program -ProjectName 'fixture' -Mode Jtag -BitFile $bitPath } 'PREVIEW ONLY'
Assert (-not ($script:ImpactSteps -contains 'program')) 'preview mode ran the program step'
Assert (-not ($script:ImpactSteps -contains 'verify')) 'preview mode ran the verify step'
$previewDir = Get-LatestProgrammerRun 'fixture' 'program-'
Assert (-not (Test-Path "$previewDir/results/program.log")) 'preview mode produced a program log'
Assert (-not (Test-Path "$previewDir/generated/program.cmd")) 'preview mode generated a write script'
$previewJson = Get-Content "$previewDir/run.json" -Raw | ConvertFrom-Json
Assert ($previewJson.result -eq 'PREVIEW_ONLY') 'PREVIEW_ONLY not recorded in run.json'
Assert ($previewJson.mode -eq 'Jtag') 'mode not recorded in run.json'
Assert ($previewJson.position -eq 1) 'resolved position not recorded in run.json'
Assert ($previewJson.bitFileSha256) 'bitstream hash not recorded in run.json'
Write-Host 'PASS: program without -ConfirmHardwareWrite only previews and uploads no write script.'

# --- program Jtag with confirmation ----------------------------------------
$script:ImpactSteps.Clear()
$jtagRun = Invoke-Program -ProjectName 'fixture' -Mode Jtag -BitFile $bitPath -ConfirmHardwareWrite
Assert ($jtagRun.Statuses.cableDetected -eq 'PASS') 'cable status missing'
Assert ($jtagRun.Statuses.jtagChainDetected -eq 'PASS') 'chain status missing'
Assert ($jtagRun.Statuses.deviceMatched -eq 'PASS') 'device match status missing'
Assert ($jtagRun.Statuses.programmingCompleted -eq 'PASS') 'JTAG programming should pass'
Assert ($jtagRun.Statuses.programmingVerified -eq 'VERIFIED') 'verify should report VERIFIED'
Assert ($jtagRun.Statuses.userDesignFunctional -eq 'NOT_TESTED') 'user design must stay NOT_TESTED'
$jtagSummary = Get-TextSafe "$($jtagRun.RunDir)/summary.txt"
Assert ($jtagSummary -notmatch 'BOARD PASS') 'programming success must never print BOARD PASS'
Assert ($jtagSummary -match 'does not need the user 2 MHz') 'the TCK vs user clock note is missing'
$jtagJson = Get-Content "$($jtagRun.RunDir)/run.json" -Raw | ConvertFrom-Json
Assert ($jtagJson.operation -eq 'program' -and $jtagJson.result -eq 'PASS') 'run.json program result wrong'
Assert ($jtagJson.bitFileSha256 -eq (Get-FileHash -LiteralPath $bitPath -Algorithm SHA256).Hash) 'bitFileSha256 wrong'
Assert ($jtagJson.confirmHardwareWrite -eq $true) 'confirmation not recorded'
Assert ((Get-TextSafe "$($jtagRun.RunDir)/generated/program.cmd") -match 'assignFile -p 1 -file') 'Jtag program.cmd wrong'

# --- program Isf (persistent) ----------------------------------------------
$script:ImpactSteps.Clear()
$isfRun = Invoke-Program -ProjectName 'fixture' -Mode Isf -BitFile $bitPath -ConfirmHardwareWrite
Assert ($isfRun.Statuses.programmingCompleted -eq 'PASS') 'ISF programming should pass'
$isfSummary = Get-TextSafe "$($isfRun.RunDir)/summary.txt"
Assert ($isfSummary -match 'M\[2:0\] = 011') 'ISF boot requirement M[2:0] missing'
Assert ($isfSummary -match 'VCCAUX = 3.3 V') 'ISF boot requirement VCCAUX missing'
Assert ($isfSummary -match 'NON-VOLATILE') 'ISF persistence not stated'
$isfCmd = Get-TextSafe "$($isfRun.RunDir)/generated/program.cmd"
Assert ($isfCmd -match 'assignFileToAttachedFlash') 'ISF program.cmd missing the attach command'
Assert ($isfCmd -match 'program -p 1 -spi') 'ISF program.cmd missing -spi'
Assert ((Get-Content "$($isfRun.RunDir)/run.json" -Raw | ConvertFrom-Json).mode -eq 'Isf') 'ISF mode not recorded'
Write-Host 'PASS: Jtag program is marked volatile, Isf program is marked persistent with its boot requirements.'

# --- multiple devices need an explicit position ----------------------------
$script:ProgProbe = 'twoDevices'
Expect-Failure { Invoke-Program -ProjectName 'fixture' -Mode Jtag -BitFile $bitPath -ConfirmHardwareWrite } 'Multiple JTAG devices detected; specify -Position'
$script:ProgProbe = 'ok'

# --- verify outcomes --------------------------------------------------------
$script:ProgVerify = 'notapplicable'
$notApplicable = Invoke-Program -ProjectName 'fixture' -Mode Jtag -BitFile $bitPath -ConfirmHardwareWrite
Assert ($notApplicable.Statuses.programmingVerified -eq 'NOT_APPLICABLE') 'not-applicable verify not reported'
Assert ($notApplicable.Statuses.programmingCompleted -eq 'PASS') 'programming itself should still be PASS'
$script:ProgVerify = 'noreport'
Assert ((Invoke-Program -ProjectName 'fixture' -Mode Jtag -BitFile $bitPath -ConfirmHardwareWrite).Statuses.programmingVerified -eq 'NOT_REPORTED') 'unreported verify not flagged'
$script:ProgVerify = 'fail'
Expect-Failure { Invoke-Program -ProjectName 'fixture' -Mode Isf -BitFile $bitPath -ConfirmHardwareWrite } 'result FAIL'
$script:ProgVerify = 'ok'
Write-Host 'PASS: verify is always attempted and its outcome is reported honestly (VERIFIED/NOT_APPLICABLE/NOT_REPORTED/FAIL).'

# --- timeout and connection loss -------------------------------------------
$script:ProgProgram = 'timeout'
Expect-Failure { Invoke-Program -ProjectName 'fixture' -Mode Jtag -BitFile $bitPath -ConfirmHardwareWrite } 'TIMEOUT'
$timeoutSummary = Get-TextSafe ((Get-LatestProgrammerRun 'fixture' 'program-') + '/summary.txt')
Assert ($timeoutSummary -match 'TIMEOUT') 'timeout not documented in the summary'
$script:ProgProgram = 'interrupted'
$script:ImpactSteps.Clear()
Expect-Failure { Invoke-Program -ProjectName 'fixture' -Mode Jtag -BitFile $bitPath -ConfirmHardwareWrite } 'PROGRAM_STATE_UNKNOWN'
Assert (@($script:ImpactSteps | Where-Object { $_ -eq 'program' }).Count -eq 1) 'program must not be retried automatically'
$interruptSummary = Get-TextSafe ((Get-LatestProgrammerRun 'fixture' 'program-') + '/summary.txt')
Assert ($interruptSummary -match 'Do NOT re-run program blindly') 'recovery instructions missing'
$script:ProgProgram = 'ok'

# --- failed preflight writes nothing ---------------------------------------
$script:ImpactSteps.Clear()
$script:ProgProbe = 'nocable'
Expect-Failure { Invoke-Program -ProjectName 'fixture' -Mode Isf -BitFile $bitPath -ConfirmHardwareWrite } 'preflight failed'
Assert (-not ($script:ImpactSteps -contains 'program')) 'a failed preflight still tried to write'
$script:ProgProbe = 'ok'

# --- bitstream file checks --------------------------------------------------
Expect-Failure { Invoke-Program -ProjectName 'fixture' -Mode Jtag -BitFile (Join-Path $root 'missing.bit') -ConfirmHardwareWrite } 'bitstream not found'
$emptyBit = Join-Path $root 'empty.bit'
[IO.File]::WriteAllBytes($emptyBit, [byte[]]@())
Expect-Failure { Invoke-Program -ProjectName 'fixture' -Mode Isf -BitFile $emptyBit -ConfirmHardwareWrite } 'bitstream is empty'
Write-Host 'PASS: probe/program reject missing/empty bitstreams and never write on a failed preflight.'

Write-Host ''
Write-Host 'PASS: all toolchain tests finished (sim, verify, report, static checks, compatibility, probe/program).'
Write-Host "Test evidence retained: $root"
