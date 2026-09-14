#Requires -Version 7.0
#=============================================================================
# tools/ise-program.ps1 -- read-only JTAG probe and JTAG / ISF programming.
#
#   probe   = read only: cable + JTAG chain + IDCODE, never writes the FPGA/flash
#   program = hardware write, requires -ConfirmHardwareWrite, two distinct modes
#       Mode Jtag : configure the FPGA over JTAG   -> VOLATILE, a power cycle
#                   loses the configuration
#       Mode Isf  : program the Spartan-3AN internal In-System Flash over JTAG
#                   -> non-volatile, the device reconfigures itself at power-up
#
# Everything below was measured against the real ISE 14.7 installation on the
# Win7 host fpga-vm; nothing here is copied from an internet example:
#
#   * iMPACT runs headless as `impact -batch <file>`; the batch command set of
#     this installation is what `help` prints (see README.md for the list).
#   * `setMode` must come first - every other command answers
#     "ERROR:iMPACT:351 - setMode is required before this operation."
#   * `setMode -bs` and `setMode -bscan` are accepted (exit code 0).
#   * `assignFile -p N -file X` and `assignFileToAttachedFlash -p N -file X` are
#     accepted (they only fail with "ERROR:iMPACT:589 - No devices on chain").
#   * program/verify/erase syntax (including -spi and -position) is the text this
#     installation's own `help -m program|verify|erase` prints.
#   * `listUsbCables` only knows the Xilinx Platform Cable USB, so cable
#     detection uses `setMode -bs` + `setCable -p auto` (Digilent plugin lines).
#   * iMPACT's process exit code is NOT reliable: the same failing identify
#     returned 0 in one run and 1 in another, so verdicts are parsed from the
#     transcript and the exit code is only recorded.
#   * `blankCheck` before `setMode` crashes iMPACT (0xC0000005) - never call it
#     out of order.
#   * XC3S50AN IDCODE 0x02610093 comes from the installation's own
#     spartan3a/data/xc3s50an_tq144_1532.bsd, not from memory.
#
# Loaded by tools/ise-tools.ps1.
#=============================================================================

if (-not $script:RemoteHost) { throw 'tools/ise-program.ps1 must be loaded through tools/ise-tools.ps1 (remote settings not initialised).' }

# JTAG programming does not use the user clock: iMPACT drives everything from the
# TCK the download cable generates, so a missing 2 MHz oscillator does not stop
# chain detection or programming.
$script:ProgrammerTimeoutDefaults = @{
    ProbeSeconds = 120
    JtagSeconds  = 300
    IsfSeconds   = 600
    VerifySeconds = 300
}

function Get-IseProgrammerPaths {
    $iseRoot = Join-Path (Split-Path $script:Settings -Parent) 'ISE'
    return [pscustomobject]@{
        IseRoot  = $iseRoot
        Impact   = Join-Path $iseRoot 'bin\nt\impact.exe'
        Settings = $script:Settings
    }
}

#-----------------------------------------------------------------------------
# Device expectations (from project.json "device", e.g. xc3s50an-4-tqg144)
#-----------------------------------------------------------------------------
function Get-ExpectedDeviceFacts {
    param([Parameter(Mandatory)][string]$DeviceString)
    if ($DeviceString -notmatch '^(?<part>xc[a-z0-9]+)-(?<speed>[1-9][0-9]*[a-z]?)-(?<package>[a-z]+[0-9]+)$') {
        throw "Cannot parse device string: $DeviceString"
    }
    $part = $Matches['part']
    $speed = $Matches['speed']
    $package = $Matches['package']
    # BSDL files use the non Pb-free package name: tqg144 -> tq144, vqg100 -> vq100 ...
    $bsdlPackage = $package
    if ($package -match '^(tq|vq|ft|fg|pq|cp|cs|bg|fb|pc|hc|rc)g(\d+)$') { $bsdlPackage = $Matches[1] + $Matches[2] }
    return [pscustomobject]@{
        DeviceString = $DeviceString
        Part         = $part
        Speed        = $speed
        Package      = $package
        BsdlPackage  = $bsdlPackage
        FamilyDir    = 'spartan3a'
    }
}

function Find-RemoteBsdl {
    param([Parameter(Mandatory)]$ExpectedDevice)
    $paths = Get-IseProgrammerPaths
    $direct = ($paths.IseRoot + '\' + $ExpectedDevice.FamilyDir + '\data\' + $ExpectedDevice.Part + '_' + $ExpectedDevice.BsdlPackage + '.bsd')
    $found = (Invoke-Ssh ('cmd /d /c "if exist "' + $direct + '" (echo FOUND) else (echo MISSING)"')).Trim()
    if ($found -eq 'FOUND') { return $direct }
    # fall back to a recursive search, e.g. when the family directory differs
    $search = Invoke-Ssh ('cmd /d /c "dir /b /s "' + $paths.IseRoot + '\*' + $ExpectedDevice.Part + '_' + $ExpectedDevice.BsdlPackage + '*.bsd" 2>nul')
    $candidates = @($search -split "`r?`n" | Where-Object { $_ -match '\.bsd$' })
    if ($candidates.Count -eq 0) { return $null }
    $plain = @($candidates | Where-Object { $_ -notmatch '_1532' })
    if ($plain.Count -gt 0) { return $plain[0].Trim() }
    return $candidates[0].Trim()
}

# IDCODE_REGISTER fields are printed MSB first (version, part fields, manufacturer,
# trailing 1), so the concatenated bits are the binary value directly.
function Get-BsdlIdcode {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $m = [regex]::Match($Text, '(?s)attribute\s+IDCODE_REGISTER\s+of\s+\S+\s*:\s*entity\s+is\s*(.*?);')
    if (-not $m.Success) { return $null }
    $fields = @([regex]::Matches($m.Groups[1].Value, '"([01Xx]+)"') | ForEach-Object { $_.Groups[1].Value })
    if ($fields.Count -eq 0) { return $null }
    $bits = (-join $fields) -replace '[Xx]', '0'
    if ($bits.Length -ne 32 -or $bits -notmatch '^[01]{32}$') { return $null }
    $value = [Convert]::ToUInt32($bits, 2)
    return [pscustomobject]@{
        Idcode          = $value
        IdcodeHex       = ('0x{0:X8}' -f $value)
        IdcodeNoVersion = ('0x{0:X8}' -f ($value -band 0x0FFFFFFF))
        Bits            = $bits
        VersionField    = $fields[0]
        InstructionLength = $(if ($Text -match 'INSTRUCTION_LENGTH\s+of\s+\S+\s*:\s*entity\s+is\s+(\d+)') { [int]$Matches[1] } else { $null })
    }
}

#-----------------------------------------------------------------------------
# Transcript parsing (iMPACT exit codes are not trustworthy)
#-----------------------------------------------------------------------------
function Get-ProbeLogFacts {
    param([AllowNull()][string]$LogText)
    $text = ''
    if ($null -ne $LogText) { $text = $LogText }

    $cableName = $null
    $cableSerial = $null
    $cableDetail = $null
    foreach ($p in @(
        @{ Pattern = 'opening device:\s*"(?<name>[^"]+)"'; Name = 'name' },
        @{ Pattern = 'Product Name:\s*(?<name>.+)'; Name = 'name' },
        @{ Pattern = 'Serial Number:\s*(?<name>[0-9A-Za-z]+)'; Name = 'serial' },
        @{ Pattern = 'JTAG Clock Frequency:\s*(?<name>[0-9]+ Hz)'; Name = 'detail' },
        @{ Pattern = 'Cable Type:\s*(?<name>.+)'; Name = 'name' },
        @{ Pattern = 'Cable Port:\s*(?<name>.+)'; Name = 'detail' }
    )) {
        $m = [regex]::Match($text, $p.Pattern)
        if ($m.Success) {
            $value = $m.Groups['name'].Value.Trim()
            if ($p.Name -eq 'name' -and -not $cableName) { $cableName = $value }
            elseif ($p.Name -eq 'serial' -and -not $cableSerial) { $cableSerial = $value }
            elseif ($p.Name -eq 'detail' -and -not $cableDetail) { $cableDetail = $value }
        }
    }

    $noCablePatterns = @(
        'found 0 device\(s\)',
        'Cable is not detected',
        'cable is not detected',
        'The Platform Cable USB is not detected',
        'Cable auto-detection failed',
        'No cable',
        'no cable'
    )
    $cableMissing = $false
    foreach ($p in $noCablePatterns) { if ($text -match $p) { $cableMissing = $true; break } }

    if ($cableName -and -not $cableMissing) { $cableStatus = 'PASS' }
    elseif ($cableMissing) { $cableStatus = 'CABLE_NOT_FOUND' }
    elseif ($cableName) { $cableStatus = 'PASS' }
    else { $cableStatus = 'UNKNOWN' }

    # devices: collect IDCODEs and part names, in transcript order. Names are only
    # taken from lines that actually describe a device, so paths and headers do not
    # invent phantom chain entries.
    $devices = New-Object System.Collections.Generic.List[object]

    # IDCODE shapes produced by this installation:
    #   '1': IDCODE is '02610093' (in hex).                    <- readIdcode
    #   '1': IDCODE is '00000010011000010000000010010011'      <- readIdcode (binary)
    #   '1': IDCODE = 0x02610093
    $idcodeByPos = @{}
    foreach ($m in [regex]::Matches($text, "(?im)^\s*'?(?<pos>\d+)'?\s*:.*?IDCODE\s*(?:is|=|:)\s*'?(?<val>[01]{32}|[0-9A-Fa-f]{8})(?='|\b)")) {
        $pos = [int]$m.Groups['pos'].Value
        $val = $m.Groups['val'].Value
        if ($val.Length -eq 32) { $val = ([Convert]::ToUInt32($val, 2)).ToString('X8') }
        $idcodeByPos[$pos] = '0x' + $val.ToUpperInvariant()
    }
    if ($idcodeByPos.ContainsKey(0) -and -not $idcodeByPos.ContainsKey(1)) {
        # iMPACT sometimes tags the first device as '0'; normalise to 1-based.
        $shifted = @{}
        foreach ($k in $idcodeByPos.Keys) { $shifted[$k + 1] = $idcodeByPos[$k] }
        $idcodeByPos = $shifted
    }
    $idcodes = @($idcodeByPos.Keys | Sort-Object | ForEach-Object { $idcodeByPos[$_] })
    if ($idcodes.Count -eq 0) {
        $idcodes = @([regex]::Matches($text, '(?i)IDCODE\s*[=:]\s*(0x[0-9A-Fa-f]{8})') | ForEach-Object { '0x' + $_.Groups[1].Value.Substring(2).ToUpperInvariant() })
    }
    $deviceLines = @([regex]::Matches($text, '(?im)^.*(IDCODE|Manufacturer|Device\s*(ID|#)|^\s*''?\d+''?\s*:).*$') | ForEach-Object { $_.Value })
    $names = @($deviceLines | ForEach-Object {
        $m = [regex]::Match($_, '(?i)\b(xc[0-9][a-z0-9]*[a-z])\b')
        if ($m.Success) { $m.Groups[1].Value.ToLowerInvariant() }
    } | Where-Object { $_ } | Select-Object -Unique)
    $count = [Math]::Max($idcodes.Count, $names.Count)
    for ($i = 0; $i -lt $count; $i++) {
        $devices.Add([pscustomobject]@{
            Position = $i + 1
            Idcode   = $(if ($i -lt $idcodes.Count) { $idcodes[$i] } else { $null })
            Name     = $(if ($i -lt $names.Count) { $names[$i] } else { $null })
            Raw      = $null
        })
    }
    # position-tagged lines are preferred when present
    foreach ($m in [regex]::Matches($text, "(?m)^\s*'?(?<pos>\d+)'?\s*:\s*(?<rest>.+)$")) {
        $pos = [int]$m.Groups['pos'].Value
        $rest = $m.Groups['rest'].Value.Trim()
        if ($pos -lt 1) { continue }
        $existing = $devices | Where-Object { $_.Position -eq $pos } | Select-Object -First 1
        $idcode = $null
        if ($rest -match '(?i)(0x[0-9A-Fa-f]{8})') { $idcode = '0x' + $Matches[1].Substring(2).ToUpperInvariant() }
        elseif ($idcodeByPos.ContainsKey($pos)) { $idcode = $idcodeByPos[$pos] }
        $name = $null
        if ($rest -match '(?i)\b(xc[0-9][a-z0-9]*[a-z])\b') { $name = $Matches[1].ToLowerInvariant() }
        if ($existing) {
            if ($idcode) { $existing.Idcode = $idcode }
            if ($name) { $existing.Name = $name }
            $existing.Raw = $rest
        } elseif ($idcode -or $name) {
            $devices.Add([pscustomobject]@{ Position = $pos; Idcode = $idcode; Name = $name; Raw = $rest })
        }
    }
    $deviceList = @($devices | Sort-Object Position)

    $chainError = $false
    foreach ($p in @('ERROR:iMPACT - A problem may exist in the hardware configuration', 'No devices on chain', 'ERROR:iMPACT:58\d')) {
        if ($text -match $p) { $chainError = $true; break }
    }
    $identifyRan = $text -match 'Identifying chain contents'
    if ($deviceList.Count -gt 0 -and -not $chainError) { $chainStatus = 'PASS' }
    elseif ($chainError) { $chainStatus = 'FAIL' }
    elseif ($identifyRan) { $chainStatus = 'INCONCLUSIVE' }
    else { $chainStatus = 'NOT_RUN' }

    $errors = @([regex]::Matches($text, '(?m)^\s*(ERROR|FATAL)[^\r\n]*') | ForEach-Object { $_.Value.Trim() } | Select-Object -Unique)
    return [pscustomobject]@{
        CableStatus    = $cableStatus
        CableName      = $cableName
        CableSerial    = $cableSerial
        CableDetail    = $cableDetail
        ChainStatus    = $chainStatus
        Devices        = $deviceList
        DeviceCount    = $deviceList.Count
        Errors         = $errors
        IdentifyRan    = $identifyRan
        HardwareError  = $chainError
    }
}

# iSE bitgen writes a compact binary header before the payload:
#   <letter><len_hi><len_lo><data bytes ...>0x00
# with a=design name, b=part, c=date, d=time, e=bit count (the 'e' length field
# is 4 bytes, so parsing stops after 'd'). Example from a real ISE 14.7 run:
#   'a' 00 0b "routed.ncd\0" 'b' 00 0d "3s50antqg144\0" 'c' ... 'd' ...
# Returns a hashtable keyed by the field letter; missing fields are simply absent.
function Get-BitgenHeaderFields {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $fields = @{}
    $expected = @([byte][char]'a', [byte][char]'b', [byte][char]'c', [byte][char]'d')
    $idx = 0
    $limit = [Math]::Min(512, $Bytes.Length)
    $i = 0
    while ($i -lt ($limit - 3) -and $idx -lt $expected.Count) {
        if ($Bytes[$i] -eq $expected[$idx]) {
            $len = ([int]$Bytes[$i + 1] * 256) + [int]$Bytes[$i + 2]
            if ($len -ge 1 -and $len -le 128 -and ($i + 3 + $len) -le $Bytes.Length) {
                $text = [Text.Encoding]::ASCII.GetString($Bytes, $i + 3, $len)
                $text = $text.TrimEnd([char]0).Trim()
                if ($text) { $fields[[string][char]$expected[$idx]] = $text }
                $i = $i + 3 + $len
                $idx++
                continue
            }
        }
        $i++
    }
    return $fields
}

# The bitgen 'b' field is e.g. "3s50antqg144" for xc3s50an-4-tqg144: no 'xc'
# prefix, no speed grade. Compare on the part+package text rather than guessing
# where the package starts.
function Test-BitPartMatchesDevice {
    param(
        [AllowNull()][string]$BitPartRaw,
        [Parameter(Mandatory)][string]$ExpectedPart,
        [Parameter(Mandatory)][string]$ExpectedPackage
    )
    if ([string]::IsNullOrWhiteSpace($BitPartRaw)) { return $null }
    $raw = ($BitPartRaw.ToLowerInvariant() -replace '[^a-z0-9]', '')
    $want = (($ExpectedPart + $ExpectedPackage).ToLowerInvariant() -replace '[^a-z0-9]', '')
    if ($raw -eq $want) { return $true }
    if (('xc' + $raw) -eq $want) { return $true }
    if (($raw -replace '^xc', '') -eq ($want -replace '^xc', '')) { return $true }
    return $false
}

function Get-BitFileFacts {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Path = $Path; Exists = $false; Size = 0; Sha256 = $null; Part = $null; Package = $null; Speed = $null; DesignName = $null; PartRaw = $null; HeaderFormat = 'NONE'; HeaderParsed = $false }
    }
    $item = Get-Item -LiteralPath $Path
    $sha = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    # Two header shapes exist in the wild; both are parsed tolerantly. When a
    # field is absent we say so instead of inventing a device name.
    #   1. text header  : "Target Device : xc3s50an" (iMPACT/promgen style)
    #   2. bitgen header: see Get-BitgenHeaderFields
    $part = $null; $package = $null; $speed = $null
    $designName = $null; $partRaw = $null; $format = 'NONE'
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $headLen = [Math]::Min(4096, $bytes.Length)
        $head = [Text.Encoding]::ASCII.GetString($bytes, 0, $headLen)
        if ($head -match '(?im)^\s*Target Device\s*:\s*(\S+)') { $part = $Matches[1].Trim() }
        if ($head -match '(?im)^\s*Target Package\s*:\s*(\S+)') { $package = $Matches[1].Trim() }
        if ($head -match '(?im)^\s*Target Speed\s*:\s*(\S+)') { $speed = $Matches[1].Trim() }
        if ($part -or $package -or $speed) { $format = 'TEXT' }
        if ($format -eq 'NONE') {
            $fields = Get-BitgenHeaderFields -Bytes $bytes
            if ($fields.ContainsKey('b') -or $fields.ContainsKey('a')) {
                $format = 'BITGEN'
                if ($fields.ContainsKey('a')) { $designName = $fields['a'] }
                if ($fields.ContainsKey('b')) {
                    $partRaw = $fields['b']
                    # no 'xc' prefix in the bitgen header; the speed grade is not
                    # recorded there at all, so Part stays "xc<field>" and Speed
                    # stays null rather than being guessed.
                    $part = $(if ($partRaw -match '^\d') { 'xc' + $partRaw } else { $partRaw })
                }
            }
        }
    } catch { }
    return [pscustomobject]@{
        Path = $Path; Exists = $true; Size = $item.Length; Sha256 = $sha
        Part = $part; Package = $package; Speed = $speed
        DesignName = $designName; PartRaw = $partRaw; HeaderFormat = $format
        HeaderParsed = [bool]($part -or $package -or $speed)
    }
}

function Get-ProgrammingConfig {
    param([Parameter(Mandatory)]$ProjectData)
    $probe = $script:ProgrammerTimeoutDefaults.ProbeSeconds
    $jtag = $script:ProgrammerTimeoutDefaults.JtagSeconds
    $isf = $script:ProgrammerTimeoutDefaults.IsfSeconds
    $verify = $script:ProgrammerTimeoutDefaults.VerifySeconds
    $port = 'auto'
    $block = $ProjectData.Config.PSObject.Properties['programming']
    if ($block -and $block.Value) {
        $b = $block.Value
        if ($b.PSObject.Properties['probeTimeoutSeconds'] -and $b.probeTimeoutSeconds) { $probe = [int]$b.probeTimeoutSeconds }
        if ($b.PSObject.Properties['jtagTimeoutSeconds'] -and $b.jtagTimeoutSeconds) { $jtag = [int]$b.jtagTimeoutSeconds }
        if ($b.PSObject.Properties['isfTimeoutSeconds'] -and $b.isfTimeoutSeconds) { $isf = [int]$b.isfTimeoutSeconds }
        if ($b.PSObject.Properties['verifyTimeoutSeconds'] -and $b.verifyTimeoutSeconds) { $verify = [int]$b.verifyTimeoutSeconds }
        if ($b.PSObject.Properties['cablePort'] -and $b.cablePort) { $port = [string]$b.cablePort }
    }
    foreach ($t in @($probe, $jtag, $isf, $verify)) {
        if ($t -lt 10 -or $t -gt 7200) { throw "programming timeouts must be 10..7200 seconds (got $t)" }
    }
    if ($port -notmatch '^[A-Za-z0-9]+$') { throw "Unsafe cable port: $port" }
    return [pscustomobject]@{ ProbeTimeoutSeconds = $probe; JtagTimeoutSeconds = $jtag; IsfTimeoutSeconds = $isf; VerifyTimeoutSeconds = $verify; CablePort = $port }
}

#-----------------------------------------------------------------------------
# iMPACT batch scripts (text generation only)
#-----------------------------------------------------------------------------
function New-ImpactProbeScript {
    param([Parameter(Mandatory)][string]$CablePort = 'auto')
    return @(
        'setMode -bs'
        "setCable -p $CablePort"
        'identify'
        # In this ISE 14.7 build `identify` prints the device name but not the
        # 32 bit IDCODE; `readIdcode -p 1` adds
        #   '1': IDCODE is '02610093' (in hex).
        'readIdcode -p 1'
        'quit'
    ) -join "`r`n"
}

function New-ImpactProgramScript {
    param(
        [Parameter(Mandatory)][ValidateSet('Jtag', 'Isf')][string]$Mode,
        [Parameter(Mandatory)][int]$Position,
        [Parameter(Mandatory)][string]$RemoteBitFile,
        [Parameter(Mandatory)][string]$CablePort = 'auto',
        [bool]$VerifyAfterProgram = $true
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('setMode -bs')
    $lines.Add("setCable -p $CablePort")
    $lines.Add('identify')
    if ($Mode -eq 'Isf') {
        # Spartan-3AN: the internal In-System Flash is attached to the FPGA's own
        # SPI port, so the bitstream is assigned to the attached flash.
        $lines.Add(('assignFileToAttachedFlash -p {0} -file "{1}"' -f $Position, $RemoteBitFile))
        $lines.Add(('program -p {0} -spi' -f $Position))
    } else {
        # Plain JTAG configuration of the FPGA fabric: volatile, lost on power cycle.
        # `-onlyFpga` is REQUIRED on Spartan-3AN: without it iMPACT treats the
        # device's internal SPI flash as an attached flash and programs that
        # instead - a NON-VOLATILE write that silently contradicts this mode.
        # Measured on ISE 14.7: without the flag the transcript contains
        # "SPI access core", "Programming Flash" and sector/page addresses.
        $lines.Add(('assignFile -p {0} -file "{1}"' -f $Position, $RemoteBitFile))
        # `-onlyFpga` is deliberately NOT used: measured on ISE 14.7 it switches
        # iMPACT into an "update config file" flow that fails with
        #   ERROR:Bitstream:2 - The input file ".../design.msk" does not exist
        # so it cannot produce a plain FPGA configuration either.
        if ($VerifyAfterProgram) { $lines.Add(('program -p {0} -v' -f $Position)) } else { $lines.Add(('program -p {0}' -f $Position)) }
    }
    $lines.Add('quit')
    return ($lines.ToArray() -join "`r`n")
}

function New-ImpactVerifyScript {
    param(
        [Parameter(Mandatory)][ValidateSet('Jtag', 'Isf')][string]$Mode,
        [Parameter(Mandatory)][int]$Position,
        [Parameter(Mandatory)][string]$CablePort = 'auto',
        [AllowNull()][string]$RemoteBitFile = $null
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('setMode -bs')
    $lines.Add("setCable -p $CablePort")
    $lines.Add('identify')
    # A bare `verify -p N` has no reference image and reports
    # "'1': Verifying device...Verify failed on page 0." (measured), so the same
    # file must be assigned first, exactly like the program step does.
    if ($RemoteBitFile) {
        if ($Mode -eq 'Isf') { $lines.Add(('assignFileToAttachedFlash -p {0} -file "{1}"' -f $Position, $RemoteBitFile)) }
        else { $lines.Add(('assignFile -p {0} -file "{1}"' -f $Position, $RemoteBitFile)) }
    }
    if ($Mode -eq 'Isf') { $lines.Add(('verify -p {0} -spi' -f $Position)) } else { $lines.Add(('verify -p {0} -sram' -f $Position)) }
    $lines.Add('quit')
    return ($lines.ToArray() -join "`r`n")
}

function New-ImpactRunner {
    param([Parameter(Mandatory)][string]$StepName, [Parameter(Mandatory)][string]$ScriptName)
    $lines = @(
        '@echo off'
        'setlocal'
        'cd /d "%~dp0"'
        'if not exist "..\results" mkdir "..\results"'
        ('if exist ..\results\' + $StepName + '.log del /q ..\results\' + $StepName + '.log')
        ('if exist ..\results\' + $StepName + '.exitcode del /q ..\results\' + $StepName + '.exitcode')
        ('call "{0}" > ..\results\{1}.environment.log 2>&1' -f $script:Settings, $StepName)
        'if errorlevel 1 goto failed'
        ('echo RUNNING:' + $StepName + '>..\results\' + $StepName + '.status')
        ('impact -batch {0} > ..\results\{1}.log 2>&1' -f $ScriptName, $StepName)
        'set RC=%ERRORLEVEL%'
        ('echo %RC% > ..\results\' + $StepName + '.exitcode')
        ('echo COMPLETE>..\results\' + $StepName + '.status')
        'exit /b 0'
        ':failed'
        ('echo FAILED>..\results\' + $StepName + '.status')
        'exit /b 1'
    )
    return ($lines -join "`r`n")
}

#-----------------------------------------------------------------------------
# Remote step execution
#-----------------------------------------------------------------------------
function Invoke-ImpactStep {
    param(
        [Parameter(Mandatory)][string]$RemoteRoot,
        [Parameter(Mandatory)][string]$StepName,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )
    $winRoot = $RemoteRoot.Replace('/', '\')
    $timedOut = $false
    $errorText = $null
    try {
        $null = Invoke-SshTimed ('cmd /d /c "' + $winRoot + '\work\run_' + $StepName + '.cmd"') $TimeoutSeconds
    } catch {
        $errorText = $_.Exception.Message
        if ($errorText -match '^TIMEOUT:') { $timedOut = $true }
    }
    return [pscustomobject]@{ Step = $StepName; TimedOut = $timedOut; Error = $errorText }
}

function Receive-ProgramResults {
    param([Parameter(Mandatory)][string]$ProjectName, [Parameter(Mandatory)][string]$RunId)
    Assert-Name $ProjectName
    if ($RunId -notmatch '^(probe|program)-\d{8}-\d{6}-[a-f0-9]{8}$') { throw "Invalid programmer run id: $RunId" }
    $runDir = Join-Path "$root\projects\$ProjectName\artifacts" $RunId
    $incoming = Join-Path $runDir ('download-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $remote = "$script:RemoteRoot/$ProjectName/$RunId/results"
    Invoke-Sftp @("get -r `"/$remote`" `"$($incoming.Replace('\', '/'))`"")
    $results = Join-Path $runDir 'results'
    if (Test-Path -LiteralPath $results) {
        Move-Item -LiteralPath $results -Destination (Join-Path $runDir ('previous-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)))
    }
    Move-Item -LiteralPath $incoming -Destination $results
}

function New-ProgrammerRunDirectory {
    param([Parameter(Mandatory)][string]$ProjectDataDirectory, [Parameter(Mandatory)][string]$Prefix)
    $runId = $Prefix + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $runDir = Join-Path $ProjectDataDirectory ('artifacts/' + $runId)
    foreach ($sub in @('inputs', 'generated', 'results')) { New-Item -ItemType Directory -Force -Path (Join-Path $runDir $sub) | Out-Null }
    return [pscustomobject]@{ RunId = $runId; RunDir = $runDir }
}

function Start-ProgrammerRemote {
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$RunDir,
        [Parameter(Mandatory)][string[]]$GeneratedNames
    )
    $remote = "$script:RemoteRoot/$ProjectName/$RunId"
    $win = $remote.Replace('/', '\')
    # Only the run root and results are pre-created: `put -r inputs` must create
    # <remote>/work itself, otherwise SFTP nests the directory one level deeper.
    $null = Invoke-Ssh ('if not exist "' + $win + '" mkdir "' + $win + '"')
    $null = Invoke-Ssh ('if not exist "' + $win + '\results" mkdir "' + $win + '\results"')
    Invoke-Sftp @("put -r `"$((Join-Path $RunDir 'inputs').Replace('\', '/'))`" `"/$remote/work`"")
    Send-ProgrammerGenerated -ProjectName $ProjectName -RunId $RunId -RunDir $RunDir -GeneratedNames $GeneratedNames | Out-Null
    return $remote
}

# Later uploads are single files into the existing work directory (a second
# `put -r inputs` would create work/inputs/...).
function Send-ProgrammerGenerated {
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$RunDir,
        [Parameter(Mandatory)][string[]]$GeneratedNames
    )
    $remote = "$script:RemoteRoot/$ProjectName/$RunId"
    $puts = @(foreach ($name in $GeneratedNames) {
        "put `"$((Join-Path $RunDir ('generated/' + $name)).Replace('\', '/'))`" `"/$remote/work/$name`""
    })
    if ($puts.Count -gt 0) { Invoke-Sftp $puts }
    return $remote
}

#-----------------------------------------------------------------------------
# probe (read only)
#-----------------------------------------------------------------------------
function Invoke-Probe {
    param([Parameter(Mandatory)][string]$ProjectName)
    Assert-Name $ProjectName
    $p = Read-Project $ProjectName 'synth'
    $expected = Get-ExpectedDeviceFacts ([string]$p.Config.device)
    $paths = Get-IseProgrammerPaths
    $cfg = Get-ProgrammingConfig $p
    $run = New-ProgrammerRunDirectory -ProjectDataDirectory $p.Directory -Prefix 'probe'

    # evidence: the device BSDL this installation ships (also the IDCODE source)
    $bsdlRemote = Find-RemoteBsdl -ExpectedDevice $expected
    $bsdlPath = $null
    $bsdlIdcode = $null
    $bsdlError = $null
    if ($bsdlRemote) {
        $bsdlPath = Join-Path $run.RunDir 'inputs/fpga.bsd'
        try {
            Invoke-Sftp @("get `"/$($bsdlRemote.Replace('\', '/'))`" `"$((Join-Path $run.RunDir 'inputs').Replace('\', '/'))/fpga.bsd`"")
            $bsdlIdcode = Get-BsdlIdcode (Get-TextSafe $bsdlPath)
            if (-not $bsdlIdcode) { $bsdlError = "could not parse IDCODE_REGISTER from $bsdlRemote" }
        } catch { $bsdlError = $_.Exception.Message }
    } else {
        $bsdlError = "no BSDL file found for $($expected.Part)/$($expected.BsdlPackage) in the ISE installation"
    }

    Write-Utf8 (Join-Path $run.RunDir 'generated/probe.cmd') ((New-ImpactProbeScript -CablePort $cfg.CablePort) + "`r`n")
    Write-Utf8 (Join-Path $run.RunDir 'generated/probe.expected.txt') (@(
        "device      = $($expected.DeviceString)"
        "part        = $($expected.Part)"
        "package     = $($expected.Package)"
        "bsdl        = $(if ($bsdlRemote) { $bsdlRemote } else { 'NOT_FOUND' })"
        "expected idcode = $(if ($bsdlIdcode) { $bsdlIdcode.IdcodeHex } else { 'NOT_AVAILABLE' })"
    ) -join "`r`n")
    $generated = @('probe.cmd', 'probe.expected.txt', 'run_probe.cmd')
    Write-Utf8 (Join-Path $run.RunDir 'generated/run_probe.cmd') ((New-ImpactRunner -StepName 'probe' -ScriptName 'probe.cmd') + "`r`n")

    Write-Host "Probing JTAG chain for $ProjectName ($($run.RunId)) ..."
    $step = $null
    $sendError = $null
    try {
        $null = Start-ProgrammerRemote -ProjectName $ProjectName -RunId $run.RunId -RunDir $run.RunDir -GeneratedNames $generated
        $step = Invoke-ImpactStep -RemoteRoot ("$script:RemoteRoot/$ProjectName/$($run.RunId)") -StepName 'probe' -TimeoutSeconds $cfg.ProbeTimeoutSeconds
    } catch {
        $sendError = $_.Exception.Message
    }
    $probeText = $null
    if (-not $sendError) {
        try { Receive-ProgramResults $ProjectName $run.RunId } catch { $sendError = $_.Exception.Message }
        $probeText = Get-TextSafe (Join-Path $run.RunDir 'results/probe.log')
    }

    $facts = Get-ProbeLogFacts $probeText
    $matched = $null
    $matchDetail = ''
    if ($facts.DeviceCount -eq 0) {
        $matchDetail = 'no device parsed from the transcript'
    } else {
        $parsedNames = @($facts.Devices | ForEach-Object { $_.Name } | Where-Object { $_ })
        $parsedIdcodes = @($facts.Devices | ForEach-Object { $_.Idcode } | Where-Object { $_ })
        if ($parsedNames -contains $expected.Part) {
            $matched = $true
            $idcodeAgrees = ($bsdlIdcode -and ($parsedIdcodes -contains $bsdlIdcode.IdcodeHex))
            $idcodeText = ''
            if ($idcodeAgrees) { $idcodeText = "; IDCODE $($bsdlIdcode.IdcodeHex) matches the BSDL expectation" }
            elseif ($parsedIdcodes.Count -gt 0 -and $bsdlIdcode) { $idcodeText = "; IDCODE $(($parsedIdcodes -join ', ')) does not match the BSDL expectation $($bsdlIdcode.IdcodeHex)" }
            elseif ($parsedIdcodes.Count -gt 0) { $idcodeText = "; IDCODE $(($parsedIdcodes -join ', ')) (no BSDL expectation available)" }
            $matchDetail = "device name matched $($expected.Part)$idcodeText"
        } elseif ($bsdlIdcode -and ($parsedIdcodes -contains $bsdlIdcode.IdcodeHex)) {
            $matched = $true
            $matchDetail = "IDCODE matched $($bsdlIdcode.IdcodeHex)"
        } elseif ($parsedNames.Count -gt 0 -or $parsedIdcodes.Count -gt 0) {
            # something was identified and it is not the expected part
            $matched = $false
            $matchDetail = "identified: $(if ($parsedNames.Count -gt 0) { $parsedNames -join ', ' } else { $parsedIdcodes -join ', ' }) != expected $($expected.Part) $(if ($bsdlIdcode) { $bsdlIdcode.IdcodeHex } else { '' })"
        } else {
            $matchDetail = 'the transcript contains no comparable device name or IDCODE'
        }
    }

    $result = 'PASS'
    if ($facts.CableStatus -ne 'PASS') { $result = 'FAIL' }
    elseif ($facts.ChainStatus -ne 'PASS') { $result = 'FAIL' }
    elseif ($matched -ne $true) { $result = 'FAIL' }
    if ($sendError) { $result = 'FAIL' }

    $meta = [ordered]@{
        operation = 'probe'
        project   = $ProjectName
        device    = $expected.DeviceString
        startedAt = (Get-Date -Format 'o')
        host      = $script:RemoteHost
        remotePath = "$script:RemoteRoot/$ProjectName/$($run.RunId)"
        impact    = $paths.Impact
        cablePort = $cfg.CablePort
        bsdl      = $bsdlRemote
        expectedIdcode = $(if ($bsdlIdcode) { $bsdlIdcode.IdcodeHex } else { $null })
        result    = $result
        readOnly  = $true
    }
    Write-Json (Join-Path $run.RunDir 'run.json') $meta

    $summary = New-Object System.Collections.Generic.List[string]
    $summary.Add('ISE PROGRAMMER PROBE')
    $summary.Add('')
    $summary.Add(('iMPACT          ' + $(if ($probeText) { 'PASS' } else { 'NOT_AVAILABLE' })))
    $summary.Add(('Cable           ' + $facts.CableStatus))
    $summary.Add(('JTAG chain      ' + $facts.ChainStatus))
    $summary.Add('')
    foreach ($d in @($facts.Devices)) {
        $summary.Add(('Position ' + $d.Position + ':'))
        $summary.Add(('  Device        ' + $(if ($d.Name) { $d.Name } else { 'UNKNOWN' })))
        $summary.Add(('  IDCODE        ' + $(if ($d.Idcode) { $d.Idcode } else { 'NOT_PARSED' })))
        $summary.Add('')
    }
    $summary.Add(('Expected        ' + $expected.Part))
    $summary.Add(('Match           ' + $(if ($matched -eq $true) { 'YES' } elseif ($matched -eq $false) { 'NO' } else { 'UNDETERMINED' })))
    if ($matchDetail) { $summary.Add(('Match detail    ' + $matchDetail)) }
    if ($bsdlError) { $summary.Add(('BSDL            ' + $bsdlError)) }
    $summary.Add('')
    if ($facts.CableStatus -eq 'CABLE_NOT_FOUND') {
        $summary.Add('USB/JTAG cable is not visible inside fpga-vm')
        $summary.Add('(no VM configuration change and no automatic USB attach is performed)')
    }
    foreach ($e in @($facts.Errors)) { $summary.Add(('iMPACT: ' + $e)) }
    if ($sendError) { $summary.Add(('transport: ' + $sendError)) }
    $summary.Add('')
    $summary.Add(('Result          ' + $result))
    $summary.Add('Probe is read only: it never writes the FPGA or the flash.')
    Write-Utf8 (Join-Path $run.RunDir 'summary.txt') (($summary.ToArray()) -join "`r`n")
    foreach ($line in $summary) { Write-Host $line }
    Write-Host ("run directory: " + $run.RunDir)

    if ($result -ne 'PASS') { throw "probe: result $result (see $($run.RunDir))." }
    return [pscustomobject]@{ RunId = $run.RunId; RunDir = $run.RunDir; Facts = $facts; Matched = $matched; Expected = $expected }
}

#-----------------------------------------------------------------------------
# program (hardware write)
#-----------------------------------------------------------------------------
function Invoke-Program {
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][ValidateSet('Jtag', 'Isf')][string]$Mode,
        [Parameter(Mandatory)][string]$BitFile,
        [int]$Position = 0,
        [switch]$ConfirmHardwareWrite
    )
    Assert-Name $ProjectName
    $p = Read-Project $ProjectName 'synth'
    $expected = Get-ExpectedDeviceFacts ([string]$p.Config.device)
    $cfg = Get-ProgrammingConfig $p
    $bit = Get-BitFileFacts $BitFile
    if (-not $bit.Exists) { throw "program: bitstream not found: $BitFile" }
    if ($bit.Size -le 0) { throw "program: bitstream is empty: $BitFile" }

    # Spartan-3AN stores its configuration image in an internal In-System Flash
    # inside the FPGA package. Measured on ISE 14.7: in the Boundary Scan flow an
    # `assignFile -p N -file x.bit` + `program` writes that NON-VOLATILE flash
    # (the transcript downloads xc3s50an_spi.cor and prints "Programming Flash").
    # `program` has no -sram option ("Switch \"-sram\" is not allowed") and
    # `-onlyFpga` is a different flow that requires a .msk mask file, so a
    # transient SRAM-only configuration is not reachable through this batch flow.
    # The mode wording must therefore follow the device, not the switch name.
    $hasInternalConfigFlash = [bool]($expected.Part -match '^xc3s\d+an$')
    $jtagIsNonVolatile = ($Mode -eq 'Jtag' -and $hasInternalConfigFlash)
    $volatileText = $(if ($Mode -eq 'Jtag' -and -not $hasInternalConfigFlash) { 'VOLATILE - a power cycle loses the configuration' }
        elseif ($Mode -eq 'Jtag') { 'NON-VOLATILE on this device - the file-assigned program operation writes the internal ISF' }
        else { 'NON-VOLATILE - stored in the Spartan-3AN internal ISF, survives power cycling' })
    $run = New-ProgrammerRunDirectory -ProjectDataDirectory $p.Directory -Prefix 'program'
    Copy-Item -LiteralPath $BitFile -Destination (Join-Path $run.RunDir ('inputs/' + [IO.Path]::GetFileName($BitFile)))

    $bsdlRemote = Find-RemoteBsdl -ExpectedDevice $expected
    $bsdlIdcode = $null
    if ($bsdlRemote) {
        try {
            Invoke-Sftp @("get `"/$($bsdlRemote.Replace('\', '/'))`" `"$((Join-Path $run.RunDir 'inputs').Replace('\', '/'))/fpga.bsd`"")
            $bsdlIdcode = Get-BsdlIdcode (Get-TextSafe (Join-Path $run.RunDir 'inputs/fpga.bsd'))
        } catch { $bsdlIdcode = $null }
    }

    $remoteBit = ("$script:RemoteRoot/$ProjectName/$($run.RunId)" + '/work/' + [IO.Path]::GetFileName($BitFile))
    Write-Utf8 (Join-Path $run.RunDir 'generated/probe.cmd') ((New-ImpactProbeScript -CablePort $cfg.CablePort) + "`r`n")
    Write-Utf8 (Join-Path $run.RunDir 'generated/run_probe.cmd') ((New-ImpactRunner -StepName 'probe' -ScriptName 'probe.cmd') + "`r`n")
    # program.cmd / verify.cmd are generated only after the preflight has passed
    # and after the -ConfirmHardwareWrite gate, so a preview run never uploads a
    # write script at all.
    $probeGenerated = @('probe.cmd', 'run_probe.cmd')

    $meta = [ordered]@{
        operation   = 'program'
        project     = $ProjectName
        mode        = $Mode
        device      = $expected.DeviceString
        position    = $(if ($Position -gt 0) { $Position } else { $null })
        bitFile     = $BitFile
        bitFileSha256 = $bit.Sha256
        bitFileSize = $bit.Size
        bitFileTargetDevice = $bit.Part
        bitFileTargetPackage = $bit.Package
        bitFileTargetSpeed = $bit.Speed
        bitFileHeaderParsed = $bit.HeaderParsed
        startedAt   = (Get-Date -Format 'o')
        host        = $script:RemoteHost
        remotePath  = "$script:RemoteRoot/$ProjectName/$($run.RunId)"
        cablePort   = $cfg.CablePort
        expectedIdcode = $(if ($bsdlIdcode) { $bsdlIdcode.IdcodeHex } else { $null })
        confirmHardwareWrite = [bool]$ConfirmHardwareWrite
        result      = 'RUNNING'
    }
    Write-Json (Join-Path $run.RunDir 'run.json') $meta

    $sendError = $null
    try { $null = Start-ProgrammerRemote -ProjectName $ProjectName -RunId $run.RunId -RunDir $run.RunDir -GeneratedNames $probeGenerated }
    catch { $sendError = $_.Exception.Message }
    if ($sendError) { throw "program: upload failed, nothing was written: $sendError" }

    # ---- preflight: probe (read only, same as the probe command) ------------
    Write-Host "Preflight probe ($($run.RunId)) ..."
    $probeStep = Invoke-ImpactStep -RemoteRoot ("$script:RemoteRoot/$ProjectName/$($run.RunId)") -StepName 'probe' -TimeoutSeconds $cfg.ProbeTimeoutSeconds
    try { Receive-ProgramResults $ProjectName $run.RunId } catch { }
    $probeText = Get-TextSafe (Join-Path $run.RunDir 'results/probe.log')
    $probeFacts = Get-ProbeLogFacts $probeText

    $deviceMatched = $null
    if ($probeFacts.DeviceCount -gt 0) {
        if (@($probeFacts.Devices | Where-Object { $_.Name -eq $expected.Part }).Count -gt 0) { $deviceMatched = $true }
        elseif ($bsdlIdcode -and @($probeFacts.Devices | Where-Object { $_.Idcode -eq $bsdlIdcode.IdcodeHex }).Count -gt 0) { $deviceMatched = $true }
        else { $deviceMatched = $false }
    }

    $chainStatus = $probeFacts.ChainStatus
    $chainCount = $probeFacts.DeviceCount
    if ($Position -le 0) {
        if ($chainCount -eq 1) { $Position = 1 }
        elseif ($chainCount -gt 1) { throw 'ERROR: Multiple JTAG devices detected; specify -Position.' }
    }
    $meta.position = $(if ($Position -gt 0) { $Position } else { $null })
    Write-Json (Join-Path $run.RunDir 'run.json') $meta

    # bitstream header cross check (only when the header could be parsed)
    $bitMatch = $null
    if ($bit.HeaderParsed) {
        $bitMatch = Test-BitPartMatchesDevice -BitPartRaw $bit.PartRaw -ExpectedPart $expected.Part -ExpectedPackage $expected.Package
        if ($null -eq $bitMatch -and $bit.Part) { $bitMatch = Test-BitPartMatchesDevice -BitPartRaw $bit.Part -ExpectedPart $expected.Part -ExpectedPackage $expected.Package }
    }

    $preflightOk = ($probeFacts.CableStatus -eq 'PASS') -and ($chainStatus -eq 'PASS') -and ($deviceMatched -eq $true)
    $statuses = [ordered]@{
        cableDetected        = $probeFacts.CableStatus
        jtagChainDetected    = $chainStatus
        deviceMatched        = $(if ($deviceMatched -eq $true) { 'PASS' } elseif ($deviceMatched -eq $false) { 'FAIL' } else { 'UNDETERMINED' })
        programmingCompleted = 'NOT_RUN'
        programmingVerified  = 'NOT_RUN'
        userDesignFunctional = 'NOT_TESTED'
    }

    $preview = New-Object System.Collections.Generic.List[string]
    $preview.Add('==================================================')
    $preview.Add(('ISE PROGRAMMER - ' + $Mode.ToUpperInvariant() + ' MODE'))
    $preview.Add(('Project : ' + $ProjectName))
    $preview.Add(('Run     : ' + $run.RunId))
    $preview.Add('==================================================')
    $preview.Add(('cable            : ' + $(if ($probeFacts.CableName) { $probeFacts.CableName } else { 'UNKNOWN' }) + $(if ($probeFacts.CableSerial) { ' (SN ' + $probeFacts.CableSerial + ')' } else { '' })))
    $preview.Add(('cable status     : ' + $probeFacts.CableStatus))
    $preview.Add(('JTAG chain       : ' + $chainStatus + ' (' + $chainCount + ' device(s))'))
    foreach ($d in @($probeFacts.Devices)) {
        $preview.Add(('  position ' + $d.Position + '    : ' + $(if ($d.Name) { $d.Name } else { 'UNKNOWN' }) + ' ' + $(if ($d.Idcode) { $d.Idcode } else { 'IDCODE NOT_PARSED' })))
    }
    $preview.Add(('expected device  : ' + $expected.DeviceString + '  (IDCODE ' + $(if ($bsdlIdcode) { $bsdlIdcode.IdcodeHex } else { 'NOT_AVAILABLE' }) + ')'))
    $preview.Add(('device match     : ' + $statuses.deviceMatched))
    if ($bit.HeaderParsed) {
        $targetText = $(if ($bit.Part) { $bit.Part } else { '?' }) +
                      ' (header: ' + $bit.HeaderFormat + '; package ' + $(if ($bit.Package) { $bit.Package } else { 'not in header' }) +
                      '; speed ' + $(if ($bit.Speed) { $bit.Speed } else { 'not in header' }) + ')' +
                      '   match: ' + $(if ($bitMatch -eq $true) { 'YES' } elseif ($bitMatch -eq $false) { 'NO - bitstream targets another device' } else { 'UNDETERMINED' })
        $preview.Add('bitstream target : ' + $targetText)
    }
    else { $preview.Add('bitstream target : NOT_PARSED (relying on iMPACT compatibility checking)') }
    $preview.Add(('bitstream        : ' + $BitFile + '  (' + $bit.Size + ' bytes, SHA-256 ' + $bit.Sha256.Substring(0, 16) + '...)'))
    $preview.Add(('mode             : ' + $Mode + ' - ' + $volatileText))
    $preview.Add(('position         : ' + $(if ($Position -gt 0) { $Position } else { 'UNRESOLVED' })))
    $preview.Add('')
    if ($Mode -eq 'Isf') {
        $preview.Add('Persistent boot requirements:')
        $preview.Add('  Internal Master SPI mode M[2:0] = 011')
        $preview.Add('  VCCAUX = 3.3 V')
        $preview.Add('  (JTAG cannot prove the board straps; verify these on the hardware.)')
        $preview.Add('')
    }
    $preview.Add('Status:')
    foreach ($k in $statuses.Keys) { $preview.Add(('  ' + $k.PadRight(22) + $statuses[$k])) }

    if (-not $preflightOk) {
        foreach ($line in $preview) { Write-Host $line }
        Write-Host ''
        if ($probeFacts.CableStatus -eq 'CABLE_NOT_FOUND') { Write-Host 'USB/JTAG cable is not visible inside fpga-vm (no VM change, no automatic USB attach).' }
        foreach ($e in @($probeFacts.Errors)) { Write-Host ('iMPACT: ' + $e) }
        $meta.result = 'PREFLIGHT_FAILED'
        Write-Json (Join-Path $run.RunDir 'run.json') $meta
        Write-Utf8 (Join-Path $run.RunDir 'summary.txt') (($preview.ToArray()) -join "`r`n")
        throw "program: preflight failed (cable=$($probeFacts.CableStatus), chain=$chainStatus, device=$($statuses.deviceMatched)); nothing was written."
    }

    if (-not $ConfirmHardwareWrite) {
        $preview.Add('')
        $preview.Add('PREVIEW ONLY - no hardware write was performed.')
        $preview.Add('Pass -ConfirmHardwareWrite to actually program the device.')
        foreach ($line in $preview) { Write-Host $line }
        $meta.result = 'PREVIEW_ONLY'
        Write-Json (Join-Path $run.RunDir 'run.json') $meta
        Write-Utf8 (Join-Path $run.RunDir 'summary.txt') (($preview.ToArray()) -join "`r`n")
        throw 'program: PREVIEW ONLY (no hardware write). Re-run with -ConfirmHardwareWrite to program.'
    }

    # ---- program step ------------------------------------------------------
    # Write scripts are only created and uploaded now, with the resolved position.
    Write-Utf8 (Join-Path $run.RunDir 'generated/program.cmd') ((New-ImpactProgramScript -Mode $Mode -Position $Position -RemoteBitFile $remoteBit -CablePort $cfg.CablePort) + "`r`n")
    Write-Utf8 (Join-Path $run.RunDir 'generated/run_program.cmd') ((New-ImpactRunner -StepName 'program' -ScriptName 'program.cmd') + "`r`n")
    Write-Utf8 (Join-Path $run.RunDir 'generated/verify.cmd') ((New-ImpactVerifyScript -Mode $Mode -Position $Position -CablePort $cfg.CablePort -RemoteBitFile $remoteBit) + "`r`n")
    Write-Utf8 (Join-Path $run.RunDir 'generated/run_verify.cmd') ((New-ImpactRunner -StepName 'verify' -ScriptName 'verify.cmd') + "`r`n")
    $null = Send-ProgrammerGenerated -ProjectName $ProjectName -RunId $run.RunId -RunDir $run.RunDir `
        -GeneratedNames @('program.cmd', 'run_program.cmd', 'verify.cmd', 'run_verify.cmd')

    $timeout = $(if ($Mode -eq 'Isf') { $cfg.IsfTimeoutSeconds } else { $cfg.JtagTimeoutSeconds })
    Write-Host ("Programming ($Mode, position $Position, timeout ${timeout}s) ...")
    $programStep = Invoke-ImpactStep -RemoteRoot ("$script:RemoteRoot/$ProjectName/$($run.RunId)") -StepName 'program' -TimeoutSeconds $timeout
    $interrupted = ($programStep.Error -and -not $programStep.TimedOut)
    try { Receive-ProgramResults $ProjectName $run.RunId } catch { if (-not $programStep.Error) { $programStep.Error = $_.Exception.Message } }
    $programText = Get-TextSafe (Join-Path $run.RunDir 'results/program.log')
    $programStatus = Get-TextSafe (Join-Path $run.RunDir 'results/program.status')
    $programErrors = @([regex]::Matches($programText, '(?m)^\s*(ERROR|FATAL)[^\r\n]*') | ForEach-Object { $_.Value.Trim() } | Select-Object -Unique)
    # iMPACT does NOT prefix every hard failure with ERROR:. A cable that cannot be
    # opened prints plain lines such as "Cable autodetection failed." and the runner
    # still exits with a COMPLETE status, so without this check a transcript where
    # the cable never opened would be reported as PASS_UNCONFIRMED - a false PASS.
    $cableFailures = @([regex]::Matches($programText, '(?im)^.*(no JTAG device was found|Cable autodetection failed|Cable connection failed|Cable Setup operation|Cable is not detected).*$') | ForEach-Object { $_.Value.Trim() } | Select-Object -Unique)
    # Jtag mode promises a VOLATILE configuration of the FPGA fabric. On devices
    # WITHOUT internal configuration flash the same transcript turns into an
    # internal-flash write if something is wrong, so any flash-programming
    # evidence is a hard failure there. On a Spartan-3AN the flash write IS the
    # documented behaviour of this flow ($jtagIsNonVolatile), so it is reported
    # loudly instead of being flagged as a violation.
    $flashWriteEvidence = @([regex]::Matches($programText, '(?im)^.*(SPI access core|Programming Flash|assignFileToAttachedFlash|is in sector \d|is in page \d).*$') | ForEach-Object { $_.Value.Trim() } | Select-Object -Unique)
    $nonVolatileWrite = ($Mode -eq 'Jtag' -and $flashWriteEvidence.Count -gt 0 -and -not $hasInternalConfigFlash)
    $programSuccessMarker = [bool]($programText -match '(?i)(program(ming)?\s+(operation\s+)?(completed|successful|succeeded)|configuration\s+(completed|successful)|Programming\s+Successful)')
    if ($programStep.TimedOut) { $statuses.programmingCompleted = 'TIMEOUT' }
    elseif ($interrupted) { $statuses.programmingCompleted = 'PROGRAM_STATE_UNKNOWN' }
    elseif ($programErrors.Count -gt 0) { $statuses.programmingCompleted = 'FAIL' }
    elseif ($cableFailures.Count -gt 0 -and -not $programSuccessMarker) { $statuses.programmingCompleted = 'FAIL' }
    elseif ($nonVolatileWrite) { $statuses.programmingCompleted = 'FAIL' }
    elseif ($programSuccessMarker) { $statuses.programmingCompleted = 'PASS' }
    elseif ($programText -and ($programStatus -match 'COMPLETE')) { $statuses.programmingCompleted = 'PASS_UNCONFIRMED' }
    else { $statuses.programmingCompleted = 'FAIL' }
    foreach ($c in $cableFailures) { $programErrors += ('cable: ' + $c) }
    if ($nonVolatileWrite) { $programErrors += 'MODE VIOLATION: -Mode Jtag asked for a volatile FPGA configuration but the transcript shows internal flash programming (the device non-volatile flash was modified).' }

    # ---- verify step (default on) -----------------------------------------
    if ($statuses.programmingCompleted -like 'PASS*') {
        Write-Host ("Verifying (timeout $($cfg.VerifyTimeoutSeconds)s) ...")
        $verifyStep = Invoke-ImpactStep -RemoteRoot ("$script:RemoteRoot/$ProjectName/$($run.RunId)") -StepName 'verify' -TimeoutSeconds $cfg.VerifyTimeoutSeconds
        try { Receive-ProgramResults $ProjectName $run.RunId } catch { }
        $verifyText = Get-TextSafe (Join-Path $run.RunDir 'results/verify.log')
        $verifyErrors = @([regex]::Matches($verifyText, '(?m)^\s*(ERROR|FATAL)[^\r\n]*') | ForEach-Object { $_.Value.Trim() } | Select-Object -Unique)
        $verifyCableFailures = @([regex]::Matches($verifyText, '(?im)^.*(no JTAG device was found|Cable autodetection failed|Cable connection failed|Cable Setup operation|Cable is not detected).*$') | ForEach-Object { $_.Value.Trim() } | Select-Object -Unique)
        $verifyMismatch = [bool]($verifyText -match '(?i)(verify failed|verification failed|verification terminated|mismatch)')
        if ($verifyStep.TimedOut) { $statuses.programmingVerified = 'TIMEOUT' }
        elseif (-not $verifyText) { $statuses.programmingVerified = 'NOT_REPORTED' }
        elseif ($verifyCableFailures.Count -gt 0) { $statuses.programmingVerified = 'FAIL' }
        elseif ($verifyMismatch) { $statuses.programmingVerified = 'FAIL' }
        elseif ($verifyErrors.Count -gt 0) {
            if ($verifyText -match '(?i)(not\s+applicable|does\s+not\s+support|unsupported|cannot\s+verify)') { $statuses.programmingVerified = 'NOT_APPLICABLE' }
            else { $statuses.programmingVerified = 'FAIL' }
        }
        elseif ($verifyText -match '(?i)(verif(y|ication)\s+(operation\s+)?(completed|successful|succeeded|passed))') { $statuses.programmingVerified = 'VERIFIED' }
        else { $statuses.programmingVerified = 'NOT_REPORTED' }
    }

    $programResult = 'FAIL'
    if ($statuses.programmingCompleted -like 'PASS*' -and $statuses.programmingVerified -ne 'FAIL') { $programResult = 'PASS' }

    $meta.result = $programResult
    $meta.programmingCompleted = $statuses.programmingCompleted
    $meta.programmingVerified = $statuses.programmingVerified
    $meta.bitFileTargetMatch = $bitMatch
    $meta.nonVolatileWriteDetected = $nonVolatileWrite
    $meta.modeIsNonVolatile = [bool]($jtagIsNonVolatile -or $Mode -eq 'Isf')
    $meta.hasInternalConfigFlash = $hasInternalConfigFlash
    Write-Json (Join-Path $run.RunDir 'run.json') $meta

    $summary = New-Object System.Collections.Generic.List[string]
    foreach ($line in $preview) { if ($line -notmatch '^Status:') { $summary.Add($line) } }
    $summary.Add('')
    $summary.Add('Status:')
    foreach ($k in $statuses.Keys) { $summary.Add(('  ' + $k.PadRight(22) + $statuses[$k])) }
    $summary.Add('')
    $summary.Add('Note: User design functional is NOT_TESTED. JTAG/ISF programming uses the TCK')
    $summary.Add('      generated by the download cable, so it does not need the design clock')
    $summary.Add('      oscillator; the programmed design itself does need it to run.')
    $summary.Add('      Programming success is not a board functional test.')
    if ($jtagIsNonVolatile) {
        $summary.Add('')
        $summary.Add('NON-VOLATILE WRITE: ' + $expected.Part + ' keeps its configuration image in an internal')
        $summary.Add('  In-System Flash inside the FPGA package. In iMPACT 14.7''s Boundary Scan flow')
        $summary.Add('  `assignFile` + `program` writes that flash (the transcript loads the SPI access')
        $summary.Add('  core and prints "Programming Flash"); `program` has no -sram option and')
        $summary.Add('  `-onlyFpga` belongs to a different flow that needs a .msk mask file. So this')
        $summary.Add('  -Mode Jtag run is NOT a transient SRAM configuration: the device flash now holds')
        $summary.Add('  the bitstream and will configure the FPGA on power-up when M[2:0] = 011 and')
        $summary.Add('  VCCAUX = 3.3 V. Use -Mode Isf to say so explicitly.')
    }
    if ($programErrors.Count -gt 0) { foreach ($e in $programErrors) { $summary.Add(('iMPACT: ' + $e)) } }
    if ($statuses.programmingCompleted -eq 'PROGRAM_STATE_UNKNOWN') {
        $summary.Add('')
        $summary.Add('PROGRAM_STATE_UNKNOWN: the SSH session dropped while the write may have been in')
        $summary.Add('progress. Do NOT re-run program blindly. First: re-run probe, inspect the remote')
        $summary.Add('run.status and these logs, then decide.')
    }
    if ($statuses.programmingCompleted -eq 'TIMEOUT') {
        $summary.Add('')
        $summary.Add('TIMEOUT: the iMPACT step exceeded its timeout. The log is kept; nothing is retried')
        $summary.Add('automatically. Verify the JTAG state with probe before trying again.')
    }
    Write-Utf8 (Join-Path $run.RunDir 'summary.txt') (($summary.ToArray()) -join "`r`n")
    foreach ($line in $summary) { Write-Host $line }
    Write-Host ("run directory: " + $run.RunDir)

    if ($programResult -ne 'PASS') {
        $extra = $(if ($nonVolatileWrite) { ' MODE VIOLATION: -Mode Jtag asked for a volatile FPGA configuration but the transcript shows internal flash programming; the device non-volatile flash was modified.' } else { '' })
        throw "program: result $programResult - programmingCompleted=$($statuses.programmingCompleted), programmingVerified=$($statuses.programmingVerified).$extra (see $($run.RunDir))."
    }
    return [pscustomobject]@{ RunId = $run.RunId; RunDir = $run.RunDir; Statuses = $statuses; Mode = $Mode }
}
