#Requires -Version 7.0
#=============================================================================
# convert-encoding.ps1 - move sources between the repository encoding and the
# encoding the ISE 14.7 editor uses on a Chinese Windows.
#
# The repository keeps UTF-8. The VM viewer copy made by tools/make-gui-project.ps1
# is ANSI/GBK(936) so the ISE HDL editor shows Chinese comments correctly. If you
# edit files in that copy, convert them back before putting them into the repo (and
# vice versa).
#
# Examples
#   pwsh -File .\tools\convert-encoding.ps1 -Path src\key_filter.v -From Gbk -To Utf8
#   pwsh -File .\tools\convert-encoding.ps1 -Path C:\tmp\gui\src -From Gbk -To Utf8 -Output C:\tmp\back
#   pwsh -File .\tools\convert-encoding.ps1 -Path src -From Utf8 -To Gbk -DryRun
#=============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][ValidateSet('Utf8', 'Gbk')][string]$From,
    [Parameter(Mandatory)][ValidateSet('Utf8', 'Gbk')][string]$To,
    [string]$Output,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $PSScriptRoot 'ise-gui-project.ps1')
    if ($From -eq $To) { throw "-From and -To are both $From; nothing to do." }
    $files = @()
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $files = @(Get-ChildItem -LiteralPath $Path -File -Recurse | Where-Object { Test-GuiTextFile $_.FullName })
        $base = (Get-Item -LiteralPath $Path).FullName.TrimEnd('\', '/')
    } elseif (Test-Path -LiteralPath $Path -PathType Leaf) {
        $files = @(Get-Item -LiteralPath $Path)
        $base = Split-Path -Parent $files[0].FullName
    } else {
        throw "Not found: $Path"
    }
    if ($files.Count -eq 0) { throw "No text files found under $Path" }
    $done = 0
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($base.Length).TrimStart('\', '/')
        $dest = $(if ($Output) { Join-Path $Output $rel } else { $f.FullName })
        if ($DryRun) { Write-Host ("would convert [{0}] {1} -> {2}" -f $From, $f.FullName, $dest); continue }
        if ($From -eq 'Utf8' -and $To -eq 'Gbk') { $null = ConvertTo-AnsiFile -Path $f.FullName -Destination $dest }
        else { $null = ConvertFrom-AnsiFile -Path $f.FullName -Destination $dest }
        Write-Host ("converted [{0} -> {1}] {2}" -f $From, $To, $dest)
        $done++
    }
    Write-Host ("done: {0} file(s) {1}" -f $done, $(if ($DryRun) { '(dry run)' } else { '' }))
    exit 0
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
