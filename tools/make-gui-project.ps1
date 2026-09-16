#Requires -Version 7.0
#=============================================================================
# make-gui-project.ps1 - stage an openable ISE Project Navigator project on the VM.
#
# NOT a command of the frozen toolchain (ise.ps1 keeps its twelve commands). This
# helper only READS the repository and writes a human-view copy on the VM, so a
# person can open the design in the ISE 14.7 GUI.
#
# Encoding: the repo stays UTF-8; the copy is written as ANSI/GBK because the ISE
# 14.7 HDL editor reads files as ANSI on a Chinese Windows (otherwise Chinese
# comments show as mojibake). Use -Encoding Utf8 to keep UTF-8 instead.
#
# Examples
#   pwsh -File .\tools\make-gui-project.ps1 -Project finger_piano
#   pwsh -File .\tools\make-gui-project.ps1 -Project finger_piano -Encoding Utf8
#   pwsh -File .\tools\make-gui-project.ps1 -Project finger_piano -RemotePath "C:/tmp/gui"
#=============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Project,
    [ValidateSet('Gbk', 'Utf8')][string]$Encoding = 'Gbk',
    [string]$RemotePath,
    [string]$Family,
    [switch]$KeepStaging
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
try {
    . (Join-Path $PSScriptRoot 'ise-tools.ps1')
    Assert-Name $Project
    $p = Read-Project $Project 'synth'
    $cfg = $p.Config

    $facts = Get-IseGuiDeviceFacts -DeviceString ([string]$cfg.device)
    if ($Family) { $facts.Family = $Family }
    if (-not $facts.Family) {
        throw "Unknown device family for $($facts.Part). Re-run with -Family '<ISE family name>' (this helper never guesses)."
    }

    # ---- what goes into the project ----------------------------------------
    $srcFiles = @($cfg.sources | ForEach-Object { [string]$_.path })
    $includeFiles = @()
    if ($cfg.PSObject.Properties['includeFiles']) { $includeFiles = @($cfg.includeFiles | ForEach-Object { [string]$_ }) }
    $synthesis = @($srcFiles + $includeFiles | Select-Object -Unique)
    if ($cfg.ucf) { $synthesis += [string]$cfg.ucf }
    $tbFiles = @()
    if ($cfg.PSObject.Properties['simulations'] -and $cfg.simulations) {
        foreach ($s in $cfg.simulations) { if ($s.sources) { $tbFiles += @($s.sources | ForEach-Object { [string]$_ }) } }
    }
    $tbFiles = @($tbFiles | Select-Object -Unique)
    $top = [string]$cfg.top
    $includeDir = ''
    if ($cfg.PSObject.Properties['includeDirs'] -and $cfg.includeDirs) { $includeDir = [string]@($cfg.includeDirs)[0] }

    # ---- stage locally ------------------------------------------------------
    $staging = Join-Path $root ('tools/.work/gui-project/' + $Project)
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    $converted = 0; $copied = 0
    foreach ($dir in @('src', 'constraints', 'sim')) {
        $src = Join-Path $p.Directory $dir
        if (-not (Test-Path -LiteralPath $src)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $src -File -Recurse)) {
            $rel = $f.FullName.Substring($p.Directory.Length).TrimStart('\', '/') -replace '\\', '/'
            $dest = Join-Path $staging $rel
            if (Test-GuiTextFile $f.FullName) {
                if ($Encoding -eq 'Gbk') { $null = ConvertTo-AnsiFile -Path $f.FullName -Destination $dest }
                else { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null; Copy-Item -LiteralPath $f.FullName -Destination $dest -Force }
                $converted++
            } else {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
                Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
                $copied++
            }
        }
    }
    $xiseName = $Project + '.xise'
    Write-Utf8 (Join-Path $staging 'make_project.tcl') (New-GuiProjectTcl -XiseFileName $xiseName `
        -Family $facts.Family -Part $facts.Part -Package $facts.Package -Speed $facts.Speed `
        -SynthesisFiles $synthesis -Testbenches $tbFiles -Top $top -IncludeDir $includeDir)
    Write-Utf8 (Join-Path $staging 'run_xtclsh.cmd') (New-GuiProjectRunner -TclName 'make_project.tcl')

    # ISE's own HDL hierarchy parser and the ISim/fuse flow do NOT read
    # "Verilog Include Directories" (that is a Synthesis Options / XST -vlgincdir
    # setting); they only search the PROJECT directory by default. Place a copy of
    # every include file at the project root so `include "name.vh" resolves in the
    # ISE GUI simulation view too (measured on ISE 14.7).
    $rootIncludes = New-Object System.Collections.Generic.List[string]
    foreach ($inc in $includeFiles) {
        if (-not $inc) { continue }
        $staged = Join-Path $staging $inc
        if (Test-Path -LiteralPath $staged) {
            $name = Split-Path -Leaf $inc
            Copy-Item -LiteralPath $staged -Destination (Join-Path $staging $name) -Force
            $rootIncludes.Add($name)
        }
    }

    # ---- upload and generate ------------------------------------------------
    $remote = $(if ($RemotePath) { $RemotePath.TrimEnd('/') } else { "$script:RemoteRoot/$Project/gui-project" })
    $win = $remote.Replace('/', '\')
    Write-Host "make-gui-project: staging $staging"
    Write-Host "make-gui-project: remote  $remote ($($facts.Family) / $($facts.Part) / $($facts.Package) / $($facts.Speed), $($Encoding))"
    $null = Invoke-Ssh ('if not exist "' + $win + '" mkdir "' + $win + '"')
    # Upload the staged CONTENTS of the remote directory. `put -r <staging> <remote>/`
    # would nest it as <remote>/<project>/ (measured), which leaves the previously
    # generated .tcl in place and silently runs the stale one.
    foreach ($dir in @('src', 'constraints', 'sim')) {
        $local = Join-Path $staging $dir
        if (Test-Path -LiteralPath $local) { Invoke-Sftp @("put -r `"$($local.Replace('\','/'))`" `"$remote/`"") }
    }
    foreach ($f in @('make_project.tcl', 'run_xtclsh.cmd')) {
        $local = Join-Path $staging $f
        if (Test-Path -LiteralPath $local) { Invoke-Sftp @("put `"$($local.Replace('\','/'))`" `"$remote/$f`"") }
    }
    foreach ($f in $rootIncludes) {
        Invoke-Sftp @("put `"$((Join-Path $staging $f).Replace('\','/'))`" `"$remote/$f`"")
    }
    $null = Invoke-SshTimed ('cmd /d /c "' + $win + '\run_xtclsh.cmd"') 300

    # ---- read back ----------------------------------------------------------
    $outLocal = Join-Path $staging 'make.out'
    $xiseLocal = Join-Path $staging $xiseName
    try { Invoke-Sftp @("get `"$remote/make.out`" `"$($outLocal.Replace('\','/'))`"") } catch { }
    $makeOut = Get-TextSafe $outLocal
    $ok = [bool]($makeOut -match 'PROJECT_EXISTS:\s*1')
    if ($ok) {
        try { Invoke-Sftp @("get `"$remote/$xiseName`" `"$($xiseLocal.Replace('\','/'))`"") } catch { }
    }

    Write-Host ''
    Write-Host '=================================================='
    Write-Host 'ISE GUI PROJECT (human-view copy)'
    Write-Host '=================================================='
    Write-Host ("project      : " + $Project)
    Write-Host ("xise         : " + $win + '\' + $xiseName)
    Write-Host ("device       : " + $facts.Family + ' / ' + $facts.Part + ' / ' + $facts.Package + ' / ' + $facts.Speed)
    Write-Host ("encoding     : " + $(if ($Encoding -eq 'Gbk') { 'ANSI/GBK 936 (ISE editor friendly)' } else { 'UTF-8' }))
    Write-Host ("synthesis    : " + ($synthesis -join ', '))
    Write-Host ("simulation   : " + $(if ($tbFiles.Count -gt 0) { $tbFiles -join ', ' } else { '(none)' }))
    Write-Host ("top module   : " + $(if ($top) { $top } else { '(not set)' }))
    Write-Host ("include dir  : " + $(if ($includeDir) { $includeDir } else { '(none)' }))
    Write-Host ("generated    : " + $(if ($ok) { 'YES (PROJECT_EXISTS: 1)' } else { 'NO - see make.out' }))
    Write-Host ''
    Write-Host 'Open it with ISE 14.7: File > Open Project > the .xise path above.'
    Write-Host 'This copy never replaces the repository: ise.ps1 stays the source of truth.'
    Write-Host 'NOTE: regenerating overwrites the viewer copy from the repo, so edits made'
    Write-Host '      in the ISE GUI copy are lost - convert them back first if you need them.'
    if ($Encoding -eq 'Gbk') {
        Write-Host 'Edits made in the ISE editor are GBK; convert them back with tools/convert-encoding.ps1.'
    }
    if ($ok) {
        $xise = Get-TextSafe $xiseLocal
        foreach ($prop in @('Device Family', 'Device', 'Package', 'Speed Grade', 'Top-Level Module Name in Output Netlist', 'Verilog Include Directories')) {
            $m = [regex]::Match($xise, ('<property xil_pn:name="' + [regex]::Escape($prop) + '"[^>]*xil_pn:value="(?<v>[^"]*)"'))
            if ($m.Success) { Write-Host ('  ' + $prop.PadRight(44) + ' = ' + $m.Groups['v'].Value) }
        }
    }
    if (-not $ok) { Write-Host ''; Write-Host '--- make.out ---'; Write-Host $makeOut }
    if (-not $KeepStaging) { }
    exit $(if ($ok) { 0 } else { 1 })
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
