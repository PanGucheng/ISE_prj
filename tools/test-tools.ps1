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
$script:Remote = $null

function Get-RemoteRun([string]$RemotePath) {
    $m = [regex]::Match($RemotePath, '(?<id>(?:sim-|verify-)?\d{8}-\d{6}-[a-f0-9]{8})/(?<rest>[^"]+)$')
    if (-not $m.Success) { throw "Unexpected remote path in test mock: $RemotePath" }
    return @{ Id = $m.Groups['id'].Value; Rest = $m.Groups['rest'].Value.Replace('/', '\') }
}
function Initialize-FakeRemote([string]$RunId) {
    $dir = Join-Path $root ('remote-' + $RunId)
    foreach ($sub in @('inputs', 'results', 'out')) { New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null }
    $script:Remote = $dir
    return $dir
}
function Invoke-Ssh([string]$RemoteCommand) {
    if ($RemoteCommand -match 'mkdir') {
        $id = [regex]::Match($RemoteCommand, '(?<id>(?:sim-|verify-)?\d{8}-\d{6}-[a-f0-9]{8})')
        if ($id.Success) { $null = Initialize-FakeRemote $id.Groups['id'].Value }
        return ''
    }
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
                Write-Utf8 "$script:Remote/out/synthesis.srp" @'
MOCK SYNTHESIS REPORT (unit test fixture, not a real XST run)
Number of errors   :    0 (   0 filtered)
Number of warnings :    0 (   0 filtered)
# Registers                                            : 231
# IOs                              : 20
'@
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
    if ($script:Scenario -eq 'timeout' -and $RemoteCommand -match 'run\.cmd' -and $RemoteCommand -notmatch '_tool') {
        throw 'TIMEOUT: simulated simulation timeout'
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

Write-Host ''
Write-Host 'PASS: all toolchain tests finished (sim, verify, report, static checks, compatibility).'
Write-Host "Test evidence retained: $root"
