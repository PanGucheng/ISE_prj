#Requires -Version 7.0
# Local PowerShell 7 entrypoint; remote ISE uses CMD.
[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet('doctor','new','check','build','fetch','sim','verify','report','board-check')]
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
    [switch]$Json
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
        'board-check' { Invoke-BoardCheck -ProjectName $Project }
    }
    exit 0
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
