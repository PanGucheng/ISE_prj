#Requires -Version 7.0
# Local PowerShell 7 entrypoint; remote ISE uses CMD.
[CmdletBinding()]
param(
    [Parameter(Position=0)][ValidateSet('doctor','new','check','build','fetch')][string]$Command = 'doctor',
    [string]$Project,
    [ValidateSet('synth','implement','bitstream')][string]$Stage = 'bitstream',
    [string]$RunId,
    [switch]$TransferTest
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
    }
    exit 0
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
