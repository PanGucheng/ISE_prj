#Requires -Version 7.0
# Local PowerShell 7 entrypoint; remote ISE uses CMD.
[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet('doctor','new','check','build','fetch','sim','verify','report','probe','probe-diag','program','board-check')]
    [string]$Command = 'doctor',
    [string]$Project,
    [ValidateSet('synth','implement','bitstream')][string]$Stage = 'bitstream',
    [string]$RunId,
    [switch]$TransferTest,
    # sim: name of one simulation from project.json (omit to run every enabled one)
    [string]$Test,
    # report: newest build run instead of an explicit -RunId
    [switch]$Latest,
    # report: also print the machine-readable JSON to stdout
    [switch]$Json,
    # program: Jtag = volatile FPGA configuration, Isf = Spartan-3AN internal flash
    [ValidateSet('Jtag','Isf')][string]$Mode,
    # program: bitstream to download
    [string]$BitFile,
    # program: JTAG chain position (required when the chain has more than one device)
    [int]$Position = 0,
    # program: without this switch the command only previews what it would do
    [switch]$ConfirmHardwareWrite,
    # probe-diag: how many measurement iterations, and in which Windows session
    [int]$Iterations = 10,
    [ValidateSet('Ssh','Interactive')][string]$DiagSession = 'Ssh'
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
try {
    . "$root\tools\ise-tools.ps1"
    switch ($Command) {
        'doctor' { Invoke-Doctor -TransferTest:$TransferTest }
        'new' { New-IseProject $Project }
        'check' { $null = Read-Project $Project $Stage; Write-Host "PASS: $Project configuration ($Stage)" }
        'build' { Invoke-Build $Project $Stage }
        'fetch' { Receive-Build $Project $RunId }
        'sim' { $null = Invoke-Simulation -ProjectName $Project -Test $Test }
        'verify' { $null = Invoke-Verification -ProjectName $Project }
        'report' { Invoke-Report -ProjectName $Project -RunId $RunId -Latest:$Latest -Json:$Json }
        'probe' { $null = Invoke-Probe -ProjectName $Project }
        'probe-diag' { $null = Invoke-ProbeDiag -ProjectName $Project -Iterations $Iterations -Session $DiagSession }
        'program' {
            if (-not $Mode) { throw 'program needs -Mode Jtag|Isf (JTAG configuration is volatile, Isf programs the internal flash).' }
            if (-not $BitFile) { throw 'program needs -BitFile <path>.' }
            $null = Invoke-Program -ProjectName $Project -Mode $Mode -BitFile $BitFile -Position $Position -ConfirmHardwareWrite:$ConfirmHardwareWrite
        }
        'board-check' { Invoke-BoardCheck -ProjectName $Project }
    }
    exit 0
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
