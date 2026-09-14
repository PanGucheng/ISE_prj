#Requires -Version 7.0
# Isolated orchestration tests. SSH/ISE are simulated; no remote build occurs.
$ErrorActionPreference = 'Stop'
$workspace = Split-Path $PSScriptRoot
$root = Join-Path $PSScriptRoot ('.work/test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path "$root/templates" | Out-Null
Copy-Item "$workspace/templates/project.json" "$root/templates/project.json"
. "$PSScriptRoot/ise-tools.ps1"
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Expect-Failure([scriptblock]$Action, [string]$Pattern) {
    try { & $Action } catch { if ($_.Exception.Message -match $Pattern) { return }; throw }
    throw "Expected failure: $Pattern"
}
New-IseProject 'fixture'
Expect-Failure { New-IseProject 'fixture' } 'Already exists'
Expect-Failure { Read-Project 'fixture' 'synth' } 'complete device'
$cfg = Get-Content "$root/projects/fixture/project.json" -Raw | ConvertFrom-Json
$cfg.device = 'xc6slx9-2-tqg144' # Test fixture only, never sent to ISE.
$cfg.top = 'top'
$cfg.sources = @(@{path='src/top.v';language='verilog';library='work'})
Write-Json "$root/projects/fixture/project.json" $cfg
Expect-Failure { Read-Project 'fixture' 'synth' } 'Missing input'
Write-Utf8 "$root/projects/fixture/src/top.v" 'module top(input a, output b); assign b=a; endmodule'
$null = Read-Project 'fixture' 'synth'
Expect-Failure { Read-Project 'fixture' 'implement' } 'UCF'
Expect-Failure { Resolve-Input "$root/projects/fixture" '../outside.v' } 'escapes'

$script:Mode = 'success'
$script:FakeOut = $null
function Invoke-Ssh([string]$RemoteCommand) {
    if ($RemoteCommand.StartsWith('mkdir ')) {
        $script:FakeOut = Join-Path $root ('remote-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:FakeOut | Out-Null
    } elseif ($RemoteCommand.StartsWith('cmd ')) {
        switch ($script:Mode) {
            'success' {
                Write-Utf8 "$script:FakeOut/run.status" 'COMPLETE'
                Write-Utf8 "$script:FakeOut/design.ngc" 'MOCK OUTPUT, NOT A REAL NETLIST'
            }
            'failure' { Write-Utf8 "$script:FakeOut/run.status" "RUNNING:synth`nFAILED"; throw 'SSH exit 1: simulated tool failure' }
            'disconnect' { Write-Utf8 "$script:FakeOut/run.status" 'RUNNING:synth'; throw 'SSH exit 255: simulated interruption' }
        }
    }
}
function Invoke-Sftp([string[]]$Lines) {
    foreach ($line in $Lines) {
        if ($line -match '^get -r "[^"]+" "([^"]+)"$') {
            Copy-Item -LiteralPath $script:FakeOut -Destination $Matches[1] -Recurse
        } elseif ($line -match '^put -r "([^"]+)"') {
            Assert (Test-Path "$($Matches[1])/_tool/run.cmd") 'Generated build script missing'
        } else { throw "Unexpected SFTP request: $line" }
    }
}
Invoke-Build 'fixture' 'synth'
$first = Get-ChildItem "$root/projects/fixture/artifacts" -Directory | Select-Object -First 1
Assert (Test-Path "$($first.FullName)/results/design.ngc") 'Results not fetched'
Write-Utf8 "$($first.FullName)/results/stale.txt" 'stale'
Receive-Build 'fixture' $first.Name
Assert (-not (Test-Path "$($first.FullName)/results/stale.txt")) 'Fetch mixed stale results'
$script:Mode = 'failure'
Expect-Failure { Invoke-Build 'fixture' 'synth' } 'Remote build failed'
$script:Mode = 'disconnect'
Expect-Failure { Invoke-Build 'fixture' 'synth' } 'interrupted'
Assert (@(Get-ChildItem "$root/projects/fixture/artifacts" -Directory).Count -eq 3) 'Runs were not isolated'
Write-Host 'PASS: template protection, invalid config, missing input, path escape, UCF gate, results, fresh fetch, build failure, interruption and run isolation.'
Write-Host "Test evidence retained: $root"
