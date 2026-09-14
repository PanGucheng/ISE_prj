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
    # When iMPACT cannot enumerate/open the cable it wrote nothing, so the preflight
    # and the program step may both be re-invoked. Nothing is ever retried after a
    # write could have started (TIMEOUT / PROGRAM_STATE_UNKNOWN).
    CableRetryAttempts = 3
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

    # Cable status is layered on purpose. iMPACT's Digilent plugin enumerates the
    # cable itself (Adept/DMGR) and can fail even while Windows still reports the
    # FTDI device as present and healthy - measured: `wmic Win32_PnPEntity` showed
    # USB\VID_0403&PID_6014\... Status=OK immediately before AND after a run whose
    # transcript said "no JTAG device was found". So this layer must never be
    # reported as "the cable is not visible to the VM".
    $digilentEnumFailed = [bool]($text -match '(?i)Digilent Plugin: no JTAG device was found')
    $digilentFound = [bool]($text -match "(?i)Digilent Plugin: found\s+[1-9]\d*\s+device")
    $digilentOpened = [bool]($text -match '(?i)Digilent Plugin: opening device')
    # The Adept open can fail even when the device was enumerated, with a concrete
    # error code; measured on this board: erc = 3072 (ercConnectionFailed).
    $adeptOpenFailed = [bool]($text -match '(?i)failed to open device \(DmgrOpenEx')
    $fallbackFailed = [bool]($text -match '(?i)(Cable autodetection failed|Cable connection failed|Cable is not detected)')

    if ($cableName -and -not $digilentEnumFailed -and -not $adeptOpenFailed) { $cableStatus = 'PASS' }
    elseif ($adeptOpenFailed) { $cableStatus = 'DIGILENT_OPEN_FAILED' }
    elseif ($digilentFound -and -not $digilentOpened) { $cableStatus = 'DIGILENT_OPEN_FAILED' }
    elseif ($digilentEnumFailed) { $cableStatus = 'DIGILENT_ENUM_FAILED' }
    elseif ($cableMissing) { $cableStatus = 'CABLE_UNAVAILABLE' }
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

# iMPACT does not mark a cable that could not be opened with ERROR: - it prints
# plain lines and the runner still reports COMPLETE. Used to decide whether an
# invocation did anything at all: no cable means no write, so a retry is safe.
# iMPACT does not mark an unusable cable with ERROR: - it prints plain lines and
# the runner still reports COMPLETE. This says "the JTAG cable could not be
# enumerated/opened by iMPACT", which is NOT the same thing as "the USB device is
# missing from Windows": the FTDI device can be present and healthy (verified with
# wmic Win32_PnPEntity) while the Digilent/Adept layer still fails to enumerate it.
function Test-TranscriptCableUnavailable {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return [bool]($Text -match '(?im)(no JTAG device was found|Cable autodetection failed|Cable connection failed|Cable is not detected|Cable Setup operation|failed to open device \(DmgrOpenEx)')
}

function Get-ProgrammingConfig {
    param([Parameter(Mandatory)]$ProjectData)
    $probe = $script:ProgrammerTimeoutDefaults.ProbeSeconds
    $jtag = $script:ProgrammerTimeoutDefaults.JtagSeconds
    $isf = $script:ProgrammerTimeoutDefaults.IsfSeconds
    $verify = $script:ProgrammerTimeoutDefaults.VerifySeconds
    $cableRetry = $script:ProgrammerTimeoutDefaults.CableRetryAttempts
    $cableType = 'auto'; $serial = $null; $freq = $null; $position = 0
    $block = $ProjectData.Config.PSObject.Properties['programming']
    if ($block -and $block.Value) {
        $b = $block.Value
        if ($b.PSObject.Properties['position'] -and $b.position) { $position = [int]$b.position }
        if ($b.PSObject.Properties['probeTimeoutSeconds'] -and $b.probeTimeoutSeconds) { $probe = [int]$b.probeTimeoutSeconds }
        if ($b.PSObject.Properties['jtagTimeoutSeconds'] -and $b.jtagTimeoutSeconds) { $jtag = [int]$b.jtagTimeoutSeconds }
        if ($b.PSObject.Properties['isfTimeoutSeconds'] -and $b.isfTimeoutSeconds) { $isf = [int]$b.isfTimeoutSeconds }
        if ($b.PSObject.Properties['verifyTimeoutSeconds'] -and $b.verifyTimeoutSeconds) { $verify = [int]$b.verifyTimeoutSeconds }
        if ($b.PSObject.Properties['cableRetryAttempts'] -and $b.cableRetryAttempts) { $cableRetry = [int]$b.cableRetryAttempts }
        if ($b.PSObject.Properties['cableType'] -and $b.cableType) { $cableType = ([string]$b.cableType).ToLowerInvariant() }
        if ($b.PSObject.Properties['cableSerial'] -and $b.cableSerial) { $serial = ([string]$b.cableSerial).Trim() }
        if ($b.PSObject.Properties['cableFrequencyHz'] -and $b.cableFrequencyHz) { $freq = [int]$b.cableFrequencyHz }
    }
    foreach ($t in @($probe, $jtag, $isf, $verify)) {
        if ($t -lt 10 -or $t -gt 7200) { throw "programming timeouts must be 10..7200 seconds (got $t)" }
    }
    if ($cableRetry -lt 1 -or $cableRetry -gt 10) { throw "programming.cableRetryAttempts must be 1..10 (got $cableRetry)" }
    if ($cableType -notin @('auto', 'digilent')) { throw "programming.cableType must be 'digilent' or 'auto' (got $cableType)" }
    if ($cableType -eq 'digilent') {
        if (-not $serial) { throw "programming.cableType is 'digilent' but programming.cableSerial is missing." }
        if ($serial -notmatch '^\d{6,32}$') { throw "Unsafe cable serial: $serial" }
        # A frequency must come from a real transcript. Never default it.
        if (-not $freq) { throw "programming.cableFrequencyHz is required for a pinned cable (measured value only, never guessed)." }
        if ($freq -lt 1 -or $freq -gt 200000000) { throw "programming.cableFrequencyHz out of range: $freq" }
    }
    $argument = $(if ($cableType -eq 'digilent') {
            '-target "digilent_plugin DEVICE=SN:' + $serial + ' FREQUENCY=' + $freq + '"'
        } else { '-p auto' })
    if ($position -lt 0 -or $position -gt 32) { throw "programming.position must be 0..32 (got $position)" }
    return [pscustomobject]@{
        ProbeTimeoutSeconds = $probe; JtagTimeoutSeconds = $jtag; IsfTimeoutSeconds = $isf
        VerifyTimeoutSeconds = $verify; CableRetryAttempts = $cableRetry
        CableType = $cableType; CableSerial = $serial; CableFrequencyHz = $freq
        CableArgument = $argument; Position = $position
    }
}

#-----------------------------------------------------------------------------
# iMPACT batch scripts (text generation only)
#-----------------------------------------------------------------------------
function New-ImpactProbeScript {
    param([Parameter(Mandatory)][string]$CableArgument)
    return @(
        'setMode -bs'
        ('setCable ' + $CableArgument)
        'identify'
        # In this ISE 14.7 build `identify` prints the device name but not the
        # 32 bit IDCODE; `readIdcode -p 1` adds
        #   '1': IDCODE is '02610093' (in hex).
        'readIdcode -p 1'
        'closeCable'
        'quit'
    ) -join "`r`n"
}

function New-ImpactProgramScript {
    param(
        [Parameter(Mandatory)][ValidateSet('Jtag', 'Isf')][string]$Mode,
        [Parameter(Mandatory)][int]$Position,
        [Parameter(Mandatory)][string]$RemoteBitFile,
        [Parameter(Mandatory)][string]$CableArgument,
        [switch]$DeviceHasInternalConfigFlash
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('setMode -bs')
    $lines.Add('setCable ' + $CableArgument)
    $lines.Add('identify')
    $lines.Add(('assignFile -p {0} -file "{1}"' -f $Position, $RemoteBitFile))
    if ($Mode -eq 'Isf') {
        # Spartan-3AN internal In-System Flash. Measured on ISE 14.7: assigning the
        # bitstream to the device and using `program -v` downloads the SPI access
        # core (spartan3a/data/xc3s50an_spi.cor), prints "Programming Flash" plus
        # sector/page addresses, and then verifies the flash in the same step
        # ("Verification completed successfully"). `assignFileToAttachedFlash`
        # is a DIFFERENT model - it is for an external SPI/BPI PROM and fails here
        # with "No attached device found at position '1'".
        $lines.Add(('program -p {0} -v' -f $Position))
    } elseif ($DeviceHasInternalConfigFlash) {
        # Volatile FPGA configuration on a device whose flash would otherwise be
        # chosen: `-onlyFpga` is what selects "Program FPGA only". Measured: with
        # it the transcript contains no SPI access core and no "Programming Flash",
        # just "Programming device" -> "Completed downloading bit file to device"
        # -> DONE pin check. `-v` is deliberately NOT added: an FPGA readback
        # verify needs a BitGen mask file and otherwise fails with
        #   ERROR:Bitstream:2 - The input file ".../design.msk" does not exist.
        $lines.Add(('program -p {0} -onlyFpga' -f $Position))
    } else {
        # Device without internal configuration flash: a plain program IS the
        # volatile SRAM configuration and its verify needs no mask file.
        $lines.Add(('program -p {0} -v' -f $Position))
    }
    $lines.Add('closeCable')
    $lines.Add('quit')
    return ($lines.ToArray() -join "`r`n")
}

# Kept for reference/tests only: a standalone `verify` is NOT used by the program
# flow. Measured on ISE 14.7 with an XC3S50AN, `verify -p 1` and `verify -p 1
# -sram` both answer "'1': Verifying device...Verify failed on page 0." even
# directly after a flash write that iMPACT itself verified successfully, so its
# verdict is not trustworthy for either the internal ISF or the configuration
# SRAM. FPGA readback verify needs a BitGen mask file (.msk), which this build
# does not produce.
function New-ImpactVerifyScript {
    param(
        [Parameter(Mandatory)][ValidateSet('Jtag', 'Isf')][string]$Mode,
        [Parameter(Mandatory)][int]$Position,
        [Parameter(Mandatory)][string]$CableArgument,
        [AllowNull()][string]$RemoteBitFile = $null
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('setMode -bs')
    $lines.Add('setCable ' + $CableArgument)
    $lines.Add('identify')
    if ($RemoteBitFile) { $lines.Add(('assignFile -p {0} -file "{1}"' -f $Position, $RemoteBitFile)) }
    if ($Mode -eq 'Isf') { $lines.Add(('verify -p {0} -spi' -f $Position)) } else { $lines.Add(('verify -p {0} -sram' -f $Position)) }
    $lines.Add('closeCable')
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
# One hardware transaction: the read-only preflight and the write run as two
# iMPACT invocations inside ONE remote script, back to back, with no SSH round
# trip, no SFTP, no local parsing and no sleep in between. Measured on this setup,
# a cable that was just opened can be reopened reliably, while a few seconds of
# idle in between makes the next Adept open fail (ercConnectionFailed = 3072).
# The safety boundary is unchanged: if the preflight markers are not all present,
# program.cmd is never executed.
function New-HardwareTransactionScript {
    param(
        [Parameter(Mandatory)][string]$ExpectedPart,
        [AllowNull()][string]$ExpectedIdcodeHex = $null,
        [Parameter(Mandatory)][int]$Position,
        [int]$PreflightAttempts = 4
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('@echo off')
    $lines.Add('setlocal')
    $lines.Add('cd /d "%~dp0"')
    $lines.Add('if not exist "..\results" mkdir "..\results"')
    foreach ($f in @('probe.log', 'program.log', 'run.status', 'program.exitcode', 'probe.exitcode')) {
        $lines.Add('if exist ..\results\' + $f + ' del /q ..\results\' + $f)
    }
    $lines.Add('call "' + $script:Settings + '" > ..\results\transaction.environment.log 2>&1')
    $lines.Add('if errorlevel 1 goto env_failed')
    $lines.Add('echo RUNNING>..\results\run.status')
    $lines.Add('set PF=0')
    $lines.Add('')
    # The preflight is retried INSIDE this transaction. Each attempt is a fresh
    # iMPACT process, but there is no SSH round trip, no SFTP, no local parsing and
    # no multi-second sleep between attempts, and program.cmd starts in the same
    # instant the preflight markers are all present. Measured: an immediate reopen
    # of the cable behaves much better than one after several seconds of idle.
    $lines.Add(':preflight')
    $lines.Add('set /a PF+=1')
    $lines.Add('impact -batch probe.cmd < nul > ..\results\probe.log 2>&1')
    $lines.Add('echo %ERRORLEVEL% > ..\results\probe.exitcode')
    # These are the same success markers the local parser looks for. ERRORLEVEL is
    # not trusted (measured: the same failing identify returned 0 and 1).
    $lines.Add('findstr /i /c:"Digilent Plugin: opening device" ..\results\probe.log >nul')
    $lines.Add('if errorlevel 1 goto preflight_retry')
    $lines.Add('findstr /i /c:"Added Device ' + $ExpectedPart + '" ..\results\probe.log >nul')
    $lines.Add('if errorlevel 1 goto preflight_retry')
    if ($ExpectedIdcodeHex) {
        $token = $ExpectedIdcodeHex -replace '^0[xX]', ''
        $lines.Add('findstr /i /c:"' + $token + '" ..\results\probe.log >nul')
        $lines.Add('if errorlevel 1 goto preflight_retry')
    }
    $lines.Add('echo PREFLIGHT_OK>..\results\preflight.status')
    $lines.Add('')
    $lines.Add('rem ---- preflight verified: write IMMEDIATELY, no sleep, no round trip ----')
    $lines.Add('impact -batch program.cmd < nul > ..\results\program.log 2>&1')
    $lines.Add('echo %ERRORLEVEL% > ..\results\program.exitcode')
    $lines.Add('echo COMPLETE>..\results\run.status')
    $lines.Add('exit /b 0')
    $lines.Add('')
    $lines.Add(':preflight_retry')
    $lines.Add('copy /y ..\results\probe.log ..\results\probe_attempt%PF%.log >nul')
    $lines.Add('if %PF% GEQ ' + $PreflightAttempts + ' goto preflight_failed')
    $lines.Add('goto preflight')
    $lines.Add('')
    $lines.Add(':preflight_failed')
    $lines.Add('echo PREFLIGHT_FAILED>..\results\run.status')
    $lines.Add('exit /b 2')
    $lines.Add('')
    $lines.Add(':env_failed')
    $lines.Add('echo ENV_FAILED>..\results\run.status')
    $lines.Add('exit /b 3')
    return ($lines -join "`r`n")
}

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

    Write-Utf8 (Join-Path $run.RunDir 'generated/probe.cmd') ((New-ImpactProbeScript -CableArgument $cfg.CableArgument) + "`r`n")
    Write-Utf8 (Join-Path $run.RunDir 'generated/probe.expected.txt') (@(
        "device      = $($expected.DeviceString)"
        "part        = $($expected.Part)"
        "package     = $($expected.Package)"
        "bsdl        = $(if ($bsdlRemote) { $bsdlRemote } else { 'NOT_FOUND' })"
        "expected idcode = $(if ($bsdlIdcode) { $bsdlIdcode.IdcodeHex } else { 'NOT_AVAILABLE' })"
        "cable target = $($cfg.CableArgument)"
        "cable serial = $(if ($cfg.CableSerial) { $cfg.CableSerial } else { 'NOT_CONFIGURED (auto is diagnostic only)' })"
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
        cableTarget = $cfg.CableArgument
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
    if ($facts.CableStatus -eq 'DIGILENT_ENUM_FAILED') {
        $summary.Add('DIGILENT_ENUM_FAILED: iMPACT''s Digilent plugin reported "no JTAG device')
        $summary.Add('  was found", so it could not enumerate or open the cable.')
        $summary.Add('  This is NOT proof that the USB device is missing from Windows: the FTDI')
        $summary.Add('  device can be present and healthy while the Digilent/Adept layer still')
        $summary.Add('  fails. Run `probe-diag` to compare the Windows PnP state with what')
        $summary.Add('  iMPACT sees. No VM configuration change and no automatic USB attach.')
    }
    elseif ($facts.CableStatus -eq 'DIGILENT_OPEN_FAILED') {
        $summary.Add('DIGILENT_OPEN_FAILED: iMPACT enumerated the cable but Adept could not open it.')
        $summary.Add('  Measured on this board the plugin answers:')
        $summary.Add('    failed to open device (DmgrOpenEx, erc = 3072)   = ercConnectionFailed')
        $summary.Add('  A cable that was just used opens reliably, while several seconds of idle')
        $summary.Add('  in between makes this failure much more likely, so the formal path runs the')
        $summary.Add('  preflight and the write inside one remote transaction.')
    }
    elseif ($facts.CableStatus -ne 'PASS' -and $facts.CableStatus -ne 'UNKNOWN') {
        $summary.Add(('Cable could not be used: ' + $facts.CableStatus))
        $summary.Add('  No VM configuration change and no automatic USB attach is performed.')
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
# The report body is built twice: once for the PREVIEW / preflight-failure paths and
# once after the transaction, when the chain facts come from the transaction's own
# probe.log instead of a local probe.
function New-ProgrammerReportLines {
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)]$Expected,
        [AllowNull()]$BsdlIdcode,
        [Parameter(Mandatory)]$Bit,
        [AllowNull()]$BitMatch,
        [Parameter(Mandatory)][string]$BitFile,
        [Parameter(Mandatory)][string]$VolatileText,
        [Parameter(Mandatory)][int]$Position,
        [Parameter(Mandatory)][string]$CableArgument,
        [AllowNull()][string]$CableSerial,
        [bool]$LocalProbe,
        [AllowNull()]$ProbeFacts,
        [AllowNull()][string]$ChainStatus,
        [int]$ChainCount,
        [AllowNull()][string]$DeviceMatchedText,
        [AllowNull()][string]$PreflightState = $null
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('==================================================')
    $lines.Add(('ISE PROGRAMMER - ' + $Mode.ToUpperInvariant() + ' MODE'))
    $lines.Add(('Project : ' + $ProjectName))
    $lines.Add(('Run     : ' + $RunId))
    $lines.Add('==================================================')
    $lines.Add(('cable target     : ' + $CableArgument + $(if ($CableSerial) { '   (pinned)' } else { '   (auto: diagnostic only)' })))
    if ($LocalProbe -and $ProbeFacts) {
        $lines.Add(('cable            : ' + $(if ($ProbeFacts.CableName) { $ProbeFacts.CableName } else { 'UNKNOWN' }) + $(if ($ProbeFacts.CableSerial) { ' (SN ' + $ProbeFacts.CableSerial + ')' } else { '' })))
        $lines.Add(('cable status     : ' + $ProbeFacts.CableStatus))
        $lines.Add(('JTAG chain       : ' + $ChainStatus + ' (' + $ChainCount + ' device(s))'))
        foreach ($d in @($ProbeFacts.Devices)) {
            $lines.Add(('  position ' + $d.Position + '    : ' + $(if ($d.Name) { $d.Name } else { 'UNKNOWN' }) + ' ' + $(if ($d.Idcode) { $d.Idcode } else { 'IDCODE NOT_PARSED' })))
        }
    } elseif ($PreflightState) {
        $lines.Add('cable            : (chain facts below come from the transaction preflight)')
        $lines.Add(('cable status     : ' + $(if ($ProbeFacts) { $ProbeFacts.CableStatus } else { 'UNKNOWN' })))
        $lines.Add(('JTAG chain       : ' + $ChainStatus + ' (' + $ChainCount + ' device(s))'))
        foreach ($d in @($ProbeFacts.Devices)) {
            $lines.Add(('  position ' + $d.Position + '    : ' + $(if ($d.Name) { $d.Name } else { 'UNKNOWN' }) + ' ' + $(if ($d.Idcode) { $d.Idcode } else { 'IDCODE NOT_PARSED' })))
        }
        $lines.Add(('preflight        : ' + $PreflightState))
    } else {
        $lines.Add('cable            : (not probed locally on purpose)')
        $lines.Add('cable status     : PENDING - the preflight inside the hardware transaction opens')
        $lines.Add('                   the cable and verifies the chain immediately before the write')
        $lines.Add('JTAG chain       : PENDING (checked inside the hardware transaction)')
    }
    $lines.Add(('expected device  : ' + $Expected.DeviceString + '  (IDCODE ' + $(if ($BsdlIdcode) { $BsdlIdcode.IdcodeHex } else { 'NOT_AVAILABLE' }) + ')'))
    $lines.Add(('device match     : ' + $DeviceMatchedText))
    if ($Bit.HeaderParsed) {
        $targetText = $(if ($Bit.Part) { $Bit.Part } else { '?' }) +
                      ' (header: ' + $Bit.HeaderFormat + '; package ' + $(if ($Bit.Package) { $Bit.Package } else { 'not in header' }) +
                      '; speed ' + $(if ($Bit.Speed) { $Bit.Speed } else { 'not in header' }) + ')' +
                      '   match: ' + $(if ($BitMatch -eq $true) { 'YES' } elseif ($BitMatch -eq $false) { 'NO - bitstream targets another device' } else { 'UNDETERMINED' })
        $lines.Add('bitstream target : ' + $targetText)
    } else { $lines.Add('bitstream target : NOT_PARSED (relying on iMPACT compatibility checking)') }
    $lines.Add(('bitstream        : ' + $BitFile + '  (' + $Bit.Size + ' bytes, SHA-256 ' + $Bit.Sha256.Substring(0, 16) + '...)'))
    $lines.Add(('mode             : ' + $Mode + ' - ' + $VolatileText))
    $lines.Add(('position         : ' + $(if ($Position -gt 0) { $Position } else { 'UNRESOLVED' })))
    $lines.Add('')
    if ($Mode -eq 'Isf') {
        $lines.Add('Persistent boot requirements:')
        $lines.Add('  Internal Master SPI mode M[2:0] = 011')
        $lines.Add('  VCCAUX = 3.3 V')
        $lines.Add('  (JTAG cannot prove the board straps; verify these on the hardware.)')
        $lines.Add('')
    }
    # The comma keeps PowerShell from unrolling the list into a fixed-size array.
    return , $lines
}

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

    # Spartan-3AN packs an internal In-System Flash (ISF) into the FPGA package, so
    # the same `assignFile` + `program` command means two different things:
    #   plain `program`           -> programs that NON-VOLATILE ISF (measured: the
    #                                transcript downloads xc3s50an_spi.cor and
    #                                prints "Programming Flash" with sector/pages)
    #   `program ... -onlyFpga`   -> volatile configuration of the FPGA itself
    #                                (measured: "Programming device" ->
    #                                "Completed downloading bit file to device",
    #                                no SPI core and no flash lines at all)
    # `-onlyFpga` with `-v` fails on this device because an FPGA readback verify
    # wants a BitGen mask file ("design.msk"), so the Jtag script never adds -v.
    $hasInternalConfigFlash = [bool]($expected.Part -match '^xc3s\d+an$')
    if ($Mode -eq 'Isf' -and -not $hasInternalConfigFlash) {
        throw "program: -Mode Isf requires a device with an internal In-System Flash (Spartan-3AN); $($expected.Part) has none. Use -Mode Jtag."
    }
    $volatileText = $(if ($Mode -eq 'Jtag') { 'VOLATILE - configures the FPGA fabric (program -onlyFpga); a power cycle loses it' }
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
    $remoteWin = "$script:RemoteRoot/$ProjectName/$($run.RunId)".Replace('/', '\')
    Write-Utf8 (Join-Path $run.RunDir 'generated/probe.cmd') ((New-ImpactProbeScript -CableArgument $cfg.CableArgument) + "`r`n")
    Write-Utf8 (Join-Path $run.RunDir 'generated/run_probe.cmd') ((New-ImpactRunner -StepName 'probe' -ScriptName 'probe.cmd') + "`r`n")
    # probe.cmd is uploaded up front so the local preflight (position resolution and
    # the preview) can run; program.cmd, hardware_transaction.cmd and the bitstream
    # are only generated and uploaded after -ConfirmHardwareWrite, so a preview run
    # never uploads a write script.
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
        cableTarget = $cfg.CableArgument
        expectedIdcode = $(if ($bsdlIdcode) { $bsdlIdcode.IdcodeHex } else { $null })
        confirmHardwareWrite = [bool]$ConfirmHardwareWrite
        result      = 'RUNNING'
    }
    Write-Json (Join-Path $run.RunDir 'run.json') $meta

    $sendError = $null
    try { $null = Start-ProgrammerRemote -ProjectName $ProjectName -RunId $run.RunId -RunDir $run.RunDir -GeneratedNames $probeGenerated }
    catch { $sendError = $_.Exception.Message }
    if ($sendError) { throw "program: upload failed, nothing was written: $sendError" }

    # ---- chain facts --------------------------------------------------------
    # For a preview (or when no position is configured) a local read-only probe
    # supplies the facts. For a real write the chain is NOT probed locally: the
    # preflight inside hardware_transaction.cmd owns that, because a cable that was
    # just opened is reliably reusable while a local probe followed by an upload
    # leaves exactly the idle gap that makes the next Adept open fail
    # (ercConnectionFailed = 3072). The write path's facts are read back from the
    # transaction's own probe.log afterwards.
    $positionKnown = [bool](($Position -gt 0) -or ($cfg.Position -gt 0))
    $localProbeNeeded = (-not $ConfirmHardwareWrite) -or (-not $positionKnown)
    $probeStep = $null; $probeText = ''; $probeAttempts = 0
    if ($localProbeNeeded) {
        Write-Host "Local read-only probe ($($run.RunId)) ..."
        for ($attempt = 1; $attempt -le $cfg.CableRetryAttempts; $attempt++) {
            $probeAttempts = $attempt
            $probeStep = Invoke-ImpactStep -RemoteRoot ("$script:RemoteRoot/$ProjectName/$($run.RunId)") -StepName 'probe' -TimeoutSeconds $cfg.ProbeTimeoutSeconds
            try { Receive-ProgramResults $ProjectName $run.RunId } catch { }
            $probeText = Get-TextSafe (Join-Path $run.RunDir 'results/probe.log')
            if (-not (Test-TranscriptCableUnavailable $probeText) -or $probeStep.TimedOut -or $attempt -ge $cfg.CableRetryAttempts) { break }
            Write-Host ("  iMPACT could not open the cable (local probe attempt $attempt/$($cfg.CableRetryAttempts)); nothing was written - retrying ...")
            Start-Sleep -Milliseconds 150
        }
    }
    $probeFacts = Get-ProbeLogFacts $probeText
    $meta.probeAttempts = $probeAttempts
    $meta.localProbe = $localProbeNeeded

    $deviceMatched = $null
    if ($probeFacts.DeviceCount -gt 0) {
        if (@($probeFacts.Devices | Where-Object { $_.Name -eq $expected.Part }).Count -gt 0) { $deviceMatched = $true }
        elseif ($bsdlIdcode -and @($probeFacts.Devices | Where-Object { $_.Idcode -eq $bsdlIdcode.IdcodeHex }).Count -gt 0) { $deviceMatched = $true }
        else { $deviceMatched = $false }
    }

    $chainStatus = $probeFacts.ChainStatus
    $chainCount = $probeFacts.DeviceCount
    if ($Position -le 0 -and $cfg.Position -gt 0) { $Position = $cfg.Position }
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

    # With no local probe there is nothing to gate on yet: the transaction enforces
    # the chain check and refuses to run program.cmd when it does not pass.
    $preflightOk = $true
    if ($localProbeNeeded) {
        $preflightOk = ($probeFacts.CableStatus -eq 'PASS') -and ($chainStatus -eq 'PASS') -and ($deviceMatched -eq $true)
    }
    $statuses = [ordered]@{
        cableDetected        = $(if ($localProbeNeeded) { $probeFacts.CableStatus } else { 'PENDING (checked inside the transaction)' })
        jtagChainDetected    = $(if ($localProbeNeeded) { $chainStatus } else { 'PENDING (checked inside the transaction)' })
        deviceMatched        = $(if (-not $localProbeNeeded) { 'PENDING (checked inside the transaction)' } elseif ($deviceMatched -eq $true) { 'PASS' } elseif ($deviceMatched -eq $false) { 'FAIL' } else { 'UNDETERMINED' })
        programmingCompleted = 'NOT_RUN'
        programmingVerified  = 'NOT_RUN'
        userDesignFunctional = 'NOT_TESTED'
    }

    $preview = New-ProgrammerReportLines -ProjectName $ProjectName -RunId $run.RunId -Mode $Mode `
        -Expected $expected -BsdlIdcode $bsdlIdcode -Bit $bit -BitMatch $bitMatch -BitFile $BitFile `
        -VolatileText $volatileText -Position $Position -CableArgument $cfg.CableArgument -CableSerial $cfg.CableSerial `
        -LocalProbe $localProbeNeeded -ProbeFacts $probeFacts -ChainStatus $chainStatus -ChainCount $chainCount `
        -DeviceMatchedText $statuses.deviceMatched

    if (-not $preflightOk) {
        foreach ($line in $preview) { Write-Host $line }
        Write-Host ''
        Write-Host 'Status:'
        foreach ($k in $statuses.Keys) { Write-Host ('  ' + $k.PadRight(22) + $statuses[$k]) }
        Write-Host ''
        if ($probeFacts.CableStatus -eq 'DIGILENT_ENUM_FAILED') {
            Write-Host 'DIGILENT_ENUM_FAILED: iMPACT''s Digilent plugin could not enumerate the cable.'
            Write-Host 'It is NOT established that the USB device is missing from Windows (a present,'
            Write-Host 'healthy FTDI device can coexist with this failure). No VM configuration change'
            Write-Host 'and no automatic USB attach is performed; run probe-diag to compare layers.'
        }
        elseif ($probeFacts.CableStatus -eq 'DIGILENT_OPEN_FAILED') {
            Write-Host 'DIGILENT_OPEN_FAILED: the cable was enumerated but Adept could not open it'
            Write-Host '(measured: DmgrOpenEx, erc = 3072 = ercConnectionFailed). No VM configuration'
            Write-Host 'change and no automatic USB attach is performed.'
        }
        foreach ($e in @($probeFacts.Errors)) { Write-Host ('iMPACT: ' + $e) }
        $meta.result = 'PREFLIGHT_FAILED'
        Write-Json (Join-Path $run.RunDir 'run.json') $meta
        Write-Utf8 (Join-Path $run.RunDir 'summary.txt') (($preview.ToArray()) -join "`r`n")
        throw "program: preflight failed (cable=$($probeFacts.CableStatus), chain=$chainStatus, device=$($statuses.deviceMatched)); nothing was written."
    }

    if (-not $ConfirmHardwareWrite) {
        $preview.Add('Status:')
        foreach ($k in $statuses.Keys) { $preview.Add(('  ' + $k.PadRight(22) + $statuses[$k])) }
        $preview.Add('')
        $preview.Add('PREVIEW ONLY - no hardware write was performed.')
        $preview.Add('Pass -ConfirmHardwareWrite to actually program the device.')
        foreach ($line in $preview) { Write-Host $line }
        $meta.result = 'PREVIEW_ONLY'
        Write-Json (Join-Path $run.RunDir 'run.json') $meta
        Write-Utf8 (Join-Path $run.RunDir 'summary.txt') (($preview.ToArray()) -join "`r`n")
        throw 'program: PREVIEW ONLY (no hardware write). Re-run with -ConfirmHardwareWrite to program.'
    }

    # ---- one hardware transaction -------------------------------------------
    # Everything static was already checked locally (project config, bitstream
    # header, SHA-256, expected device, confirmed cable SN, -ConfirmHardwareWrite).
    # All scripts and the bitstream are uploaded once, then ONE remote script runs
    # the read-only preflight and the write back to back with no SSH round trip,
    # no SFTP, no local parsing and no sleep between the two iMPACT invocations.
    Write-Utf8 (Join-Path $run.RunDir 'generated/probe.cmd') ((New-ImpactProbeScript -CableArgument $cfg.CableArgument) + "`r`n")
    Write-Utf8 (Join-Path $run.RunDir 'generated/program.cmd') ((New-ImpactProgramScript -Mode $Mode -Position $Position -RemoteBitFile $remoteBit -CableArgument $cfg.CableArgument -DeviceHasInternalConfigFlash:$hasInternalConfigFlash) + "`r`n")
    Write-Utf8 (Join-Path $run.RunDir 'generated/hardware_transaction.cmd') ((New-HardwareTransactionScript -ExpectedPart $expected.Part -ExpectedIdcodeHex $(if ($bsdlIdcode) { $bsdlIdcode.IdcodeHex } else { $null }) -Position $Position) + "`r`n")
    # No standalone verify step: measured on ISE 14.7 an XC3S50AN answers
    # "'1': Verifying device...Verify failed on page 0." to `verify -p 1` and to
    # `verify -p 1 -sram` even right after a write that iMPACT itself verified, so
    # its verdict is not usable. Verification comes from the program step itself.
    $null = Send-ProgrammerGenerated -ProjectName $ProjectName -RunId $run.RunId -RunDir $run.RunDir `
        -GeneratedNames @('probe.cmd', 'program.cmd', 'hardware_transaction.cmd')
    # the bitstream must be on the remote side before the transaction starts
    $null = Invoke-Sftp @("put `"$((Join-Path $run.RunDir ('inputs/' + [IO.Path]::GetFileName($BitFile))).Replace('\','/'))`" `"$remoteBit`"")

    $timeout = $(if ($Mode -eq 'Isf') { $cfg.IsfTimeoutSeconds } else { $cfg.JtagTimeoutSeconds })
    $transactionTimeout = $timeout + $cfg.ProbeTimeoutSeconds
    Write-Host ("Programming ($Mode, position $Position, transaction timeout ${transactionTimeout}s) ...")
    $preflightState = 'UNKNOWN'
    $programStep = $null; $programText = ''; $probeText = ''; $programAttempts = 0
    for ($attempt = 1; $attempt -le $cfg.CableRetryAttempts; $attempt++) {
        $programAttempts = $attempt
        if ($attempt -gt 1) {
            # keep every attempt's evidence
            $prev = Join-Path $run.RunDir ('attempt-' + ($attempt - 1))
            if (Test-Path -LiteralPath $prev) { Remove-Item -LiteralPath $prev -Recurse -Force }
            if (Test-Path -LiteralPath (Join-Path $run.RunDir 'results')) { Move-Item -LiteralPath (Join-Path $run.RunDir 'results') -Destination $prev }
        }
        $step = [pscustomobject]@{ Step = 'hardware_transaction'; TimedOut = $false; Error = $null }
        try {
            $null = Invoke-SshTimed ('cmd /d /c "' + $remoteWin + '\work\hardware_transaction.cmd"') $transactionTimeout
        } catch {
            $step.Error = $_.Exception.Message
            if ($step.Error -match '^TIMEOUT:') { $step.TimedOut = $true }
        }
        try { Receive-ProgramResults $ProjectName $run.RunId } catch { if (-not $step.Error) { $step.Error = $_.Exception.Message } }
        $programStep = $step
        $probeText = Get-TextSafe (Join-Path $run.RunDir 'results/probe.log')
        $programText = Get-TextSafe (Join-Path $run.RunDir 'results/program.log')
        $runStatusRaw = Get-TextSafe (Join-Path $run.RunDir 'results/run.status')
        $runStatus = $(if ($runStatusRaw) { $runStatusRaw.Trim() } else { '' })
        $preflightState = $(if ($runStatus -match 'PREFLIGHT_FAILED') { 'PREFLIGHT_FAILED' } elseif ($runStatus -match 'ENV_FAILED') { 'ENV_FAILED' } elseif ($runStatus -match 'COMPLETE') { 'COMPLETE' } else { 'UNKNOWN' })
        # The transaction reports its outcome through run.status and uses exit codes
        # 2 (preflight failed) and 3 (environment failed) on purpose. Those are
        # expected results, not a dropped session, so they must not turn into
        # PROGRAM_STATE_UNKNOWN. Only a missing verdict with a transport error is
        # treated as an interrupted write.
        if ($preflightState -in @('COMPLETE', 'PREFLIGHT_FAILED', 'ENV_FAILED')) { $step.Error = $null }
        # A preflight that could not open the cable wrote nothing, so the whole
        # transaction may be retried - immediately, not after a multi-second sleep
        # (measured: idling makes the next Adept open more likely to fail).
        # Everything else (any write evidence, timeout, dropped session) stops here.
        $anyWriteEvidence = [bool]($programText -match '(?i)(Programming Flash|Programming device|Programmed successfully|Programming completed successfully|Completed downloading bit file|Verifying device)')
        $cableUnavailable = ((Test-TranscriptCableUnavailable $probeText) -or (Test-TranscriptCableUnavailable $programText))
        $retryable = ($cableUnavailable -and -not $anyWriteEvidence -and -not $step.TimedOut -and -not $step.Error -and $attempt -lt $cfg.CableRetryAttempts)
        if ($retryable -and $preflightState -eq 'PREFLIGHT_FAILED') {
            Write-Host ("  preflight could not open the cable (attempt $attempt/$($cfg.CableRetryAttempts)); nothing was written - retrying immediately ...")
            Start-Sleep -Milliseconds 150
            continue
        }
        if ($retryable -and $preflightState -eq 'COMPLETE') {
            Write-Host ("  iMPACT could not open the cable for the write (attempt $attempt/$($cfg.CableRetryAttempts)); nothing was written - retrying immediately ...")
            Start-Sleep -Milliseconds 150
            continue
        }
        break
    }
    $interrupted = ($programStep.Error -and -not $programStep.TimedOut)
    $programStatus = Get-TextSafe (Join-Path $run.RunDir 'results/program.status')
    $meta.programAttempts = $programAttempts
    $meta.preflightState = $preflightState

    # The chain facts now come from the transaction's own preflight transcript, which
    # is the one that actually protected the write.
    $probeFacts = Get-ProbeLogFacts $probeText
    $deviceMatched = $null
    if ($probeFacts.DeviceCount -gt 0) {
        if (@($probeFacts.Devices | Where-Object { $_.Name -eq $expected.Part }).Count -gt 0) { $deviceMatched = $true }
        elseif ($bsdlIdcode -and @($probeFacts.Devices | Where-Object { $_.Idcode -eq $bsdlIdcode.IdcodeHex }).Count -gt 0) { $deviceMatched = $true }
        else { $deviceMatched = $false }
    }
    $chainStatus = $probeFacts.ChainStatus
    $chainCount = $probeFacts.DeviceCount
    $statuses.cableDetected = $probeFacts.CableStatus
    $statuses.jtagChainDetected = $chainStatus
    $statuses.deviceMatched = $(if ($deviceMatched -eq $true) { 'PASS' } elseif ($deviceMatched -eq $false) { 'FAIL' } else { 'UNDETERMINED' })
    $programErrors = @([regex]::Matches($programText, '(?m)^\s*(ERROR|FATAL)[^\r\n]*') | ForEach-Object { $_.Value.Trim() } | Select-Object -Unique)
    # iMPACT does NOT prefix every hard failure with ERROR:. A cable that cannot be
    # opened prints plain lines such as "Cable autodetection failed." and the runner
    # still exits with a COMPLETE status, so without this check a transcript where
    # the cable never opened would be reported as PASS_UNCONFIRMED - a false PASS.
    $cableFailures = @([regex]::Matches($programText, '(?im)^.*(no JTAG device was found|Cable autodetection failed|Cable connection failed|Cable Setup operation|Cable is not detected).*$') | ForEach-Object { $_.Value.Trim() } | Select-Object -Unique)
    # Jtag mode promises a VOLATILE configuration of the FPGA fabric, and the
    # script selects it with `-onlyFpga`. Any internal-flash programming evidence
    # in a Jtag run therefore means the requested semantics were violated: the
    # non-volatile flash was modified. Measured: with `-onlyFpga` the transcript
    # has no SPI access core and no "Programming Flash" at all.
    $flashWriteEvidence = @([regex]::Matches($programText, '(?im)^.*(SPI access core|Programming Flash|is in sector \d|is in page \d).*$') | ForEach-Object { $_.Value.Trim() } | Select-Object -Unique)
    $nonVolatileWrite = ($Mode -eq 'Jtag' -and $flashWriteEvidence.Count -gt 0)
    $programSuccessMarker = [bool]($programText -match '(?i)(program(ming)?\s+(operation\s+)?(completed|successful|succeeded)|Programmed successfully|Completed downloading bit file to device)')
    # The transcripts must name the cable we pinned. ANY other serial - in the
    # preflight or in the write - means the transaction talked to a different cable,
    # which is a hard failure.
    $seenSerials = @()
    foreach ($t in @($probeText, $programText)) {
        foreach ($m in [regex]::Matches($t, 'Serial Number:\s*(\d+)')) { $seenSerials += $m.Groups[1].Value }
    }
    $seenSerials = @($seenSerials | Select-Object -Unique)
    $actualSerial = $(if ($seenSerials.Count -gt 0) { $seenSerials -join '+' } else { $null })
    $foreignSerials = @($seenSerials | Where-Object { $_ -ne $cfg.CableSerial })
    $serialMismatch = [bool]($cfg.CableSerial -and $foreignSerials.Count -gt 0)
    if ($programStep.TimedOut) { $statuses.programmingCompleted = 'TIMEOUT' }
    elseif ($interrupted) { $statuses.programmingCompleted = 'PROGRAM_STATE_UNKNOWN' }
    elseif ($programErrors.Count -gt 0) { $statuses.programmingCompleted = 'FAIL' }
    elseif ($serialMismatch) { $statuses.programmingCompleted = 'FAIL' }
    elseif ($cableFailures.Count -gt 0 -and -not $programSuccessMarker) { $statuses.programmingCompleted = 'FAIL' }
    elseif ($nonVolatileWrite) { $statuses.programmingCompleted = 'FAIL' }
    elseif ($programSuccessMarker) { $statuses.programmingCompleted = 'PASS' }
    elseif ($programText -and ($programStatus -match 'COMPLETE')) { $statuses.programmingCompleted = 'PASS_UNCONFIRMED' }
    else { $statuses.programmingCompleted = 'FAIL' }
    foreach ($c in $cableFailures) { $programErrors += ('cable: ' + $c) }
    if ($nonVolatileWrite) { $programErrors += 'MODE VIOLATION: -Mode Jtag asked for a volatile FPGA configuration (-onlyFpga) but the transcript shows internal flash programming; the device non-volatile flash was modified.' }
    if ($serialMismatch) { $programErrors += ('CABLE MISMATCH: the transcript names cable SN ' + $actualSerial + ' but programming.cableSerial is ' + $cfg.CableSerial + '.') }
    if ($preflightState -eq 'PREFLIGHT_FAILED') { $programErrors += 'PREFLIGHT_FAILED: the remote preflight did not verify the chain, so program.cmd was never executed.' }

    # ---- verification evidence, taken from the program transcript ----------
    # The device status register that iMPACT prints at the end of a successful
    # FPGA configuration is real evidence: CRC error, DONE pin, SYNC word and the
    # MODE pin strap values. Measured on the real board (M[2:0] = 011, DONE = 1,
    # CRC error = 0, VSEL[2:0] = 111).
    $statusBits = @{}
    foreach ($m in [regex]::Matches($programText, '(?im)^(?<name>(?:CRC error|SYNC word not found|DONEIN input from Done Pin|value of MODE pin M[0-2]|value of VSEL pin [0-2]|DCM Locked|status of GWE|status of GHIGH|value of CFG_RDY \(INIT_B\)))\s*:\s*(?<val>[01])\s*$')) {
        $statusBits[$m.Groups['name'].Value.Trim()] = [int]$m.Groups['val'].Value
    }
    $modePins = $null
    if ($statusBits.ContainsKey('value of MODE pin M0') -and $statusBits.ContainsKey('value of MODE pin M1') -and $statusBits.ContainsKey('value of MODE pin M2')) {
        $modePins = ('{0}{1}{2}' -f $statusBits['value of MODE pin M2'], $statusBits['value of MODE pin M1'], $statusBits['value of MODE pin M0'])
    }
    $donePin = $(if ($statusBits.ContainsKey('DONEIN input from Done Pin')) { $statusBits['DONEIN input from Done Pin'] } else { $null })
    $crcError = $(if ($statusBits.ContainsKey('CRC error')) { $statusBits['CRC error'] } else { $null })

    $inStepVerifyPass = [bool]($programText -match '(?i)verif(y|ication)\s+completed\s+successfully')
    $inStepVerifyFail = [bool]($programText -match '(?i)(verify failed|verification failed|verification terminated)')
    if ($inStepVerifyFail) { $statuses.programmingVerified = 'FAIL' }
    elseif ($inStepVerifyPass) { $statuses.programmingVerified = 'VERIFIED' }
    elseif ($statuses.programmingCompleted -eq 'PASS' -and $donePin -eq 1 -and $crcError -eq 0) { $statuses.programmingVerified = 'CONFIG_STATUS_OK' }
    elseif ($statuses.programmingCompleted -eq 'PASS') { $statuses.programmingVerified = 'NOT_APPLICABLE' }
    else { $statuses.programmingVerified = 'NOT_RUN' }

    $programResult = 'FAIL'
    if ($statuses.programmingCompleted -like 'PASS*' -and $statuses.programmingVerified -ne 'FAIL') { $programResult = 'PASS' }

    $meta.result = $programResult
    $meta.programmingCompleted = $statuses.programmingCompleted
    $meta.programmingVerified = $statuses.programmingVerified
    $meta.bitFileTargetMatch = $bitMatch
    $meta.nonVolatileWriteDetected = $nonVolatileWrite
    $meta.cableType = $cfg.CableType
    $meta.cableSerial = $cfg.CableSerial
    $meta.cableFrequencyHz = $cfg.CableFrequencyHz
    $meta.cableTarget = $cfg.CableArgument
    $meta.cableSerialSeen = $actualSerial
    $meta.cableSerialMismatch = $serialMismatch
    $meta.modeIsNonVolatile = [bool]($Mode -eq 'Isf')
    $meta.hasInternalConfigFlash = $hasInternalConfigFlash
    $meta.configurationStatus = [ordered]@{
        modePins   = $modePins
        donePin    = $donePin
        crcError   = $crcError
        statusBits = $statusBits
    }
    Write-Json (Join-Path $run.RunDir 'run.json') $meta

    $summary = New-ProgrammerReportLines -ProjectName $ProjectName -RunId $run.RunId -Mode $Mode `
        -Expected $expected -BsdlIdcode $bsdlIdcode -Bit $bit -BitMatch $bitMatch -BitFile $BitFile `
        -VolatileText $volatileText -Position $Position -CableArgument $cfg.CableArgument -CableSerial $cfg.CableSerial `
        -LocalProbe $false -ProbeFacts $probeFacts -ChainStatus $chainStatus -ChainCount $chainCount `
        -DeviceMatchedText $statuses.deviceMatched -PreflightState $preflightState
    $summary.Add('')
    $summary.Add('Cable identity:')
    $summary.Add(('  Cable provider : ' + $(if ($cfg.CableType -eq 'digilent') { 'Digilent' } else { 'auto-detect (diagnostic only)' })))
    $summary.Add(('  Cable serial   : ' + $(if ($cfg.CableSerial) { $cfg.CableSerial } else { 'NOT_CONFIGURED' })))
    $summary.Add(('  Cable target   : ' + $(if ($cfg.CableSerial) { 'explicit' } else { 'auto' }) + '  (' + $cfg.CableArgument + ')'))
    $summary.Add(('  Cable frequency: ' + $(if ($cfg.CableFrequencyHz) { $cfg.CableFrequencyHz.ToString() + ' Hz (measured)' } else { 'NOT_CONFIGURED' })))
    $summary.Add(('  Cable in log   : ' + $(if ($actualSerial) { $actualSerial } else { 'NOT_REPORTED' }) + $(if ($serialMismatch) { '   MISMATCH -> FAIL' } else { '' })))
    $summary.Add(('  Preflight      : ' + $preflightState + $(if ($preflightState -eq 'PREFLIGHT_FAILED') { ' (program.cmd was never executed)' } else { '' })))
    $summary.Add('')
    $summary.Add('Status:')
    foreach ($k in $statuses.Keys) { $summary.Add(('  ' + $k.PadRight(22) + $statuses[$k])) }
    if ($statusBits.Count -gt 0) {
        $summary.Add('')
        $summary.Add('Device status register (read by iMPACT during programming):')
        if ($null -ne $modePins) {
            $summary.Add(('  MODE pins M[2:0]       = ' + $modePins + $(if ($modePins -eq '011') { '  (011 = Internal Master SPI: boots from the internal ISF)' } else { '  (011 = Internal Master SPI, the Spartan-3AN boot mode)' })))
        }
        foreach ($k in @('DONEIN input from Done Pin', 'CRC error', 'SYNC word not found', 'DCM Locked', 'status of GWE', 'value of VSEL pin 0', 'value of VSEL pin 1', 'value of VSEL pin 2', 'value of CFG_RDY (INIT_B)')) {
            if ($statusBits.ContainsKey($k)) { $summary.Add(('  ' + $k.PadRight(22) + '= ' + $statusBits[$k])) }
        }
    }
    $summary.Add('')
    $summary.Add('Note: User design functional is NOT_TESTED. JTAG/ISF programming uses the TCK')
    $summary.Add('      generated by the download cable, so it does not need the design clock')
    $summary.Add('      oscillator; the programmed design itself does need it to run.')
    $summary.Add('      Programming success is not a board functional test.')
    if ($Mode -eq 'Jtag') {
        $summary.Add('')
        $summary.Add('This was a VOLATILE configuration: iMPACT was told to program only the FPGA')
        $summary.Add('  fabric (`program -onlyFpga`), so the internal ISF was not written. No separate')
        $summary.Add('  verify step is run because an FPGA readback verify needs a BitGen mask file')
        $summary.Add('  (.msk) and a standalone `verify` on this device reports "Verify failed on')
        $summary.Add('  page 0" even after a write iMPACT itself verified. The DONE pin and CRC')
        $summary.Add('  status above are the evidence that the configuration was accepted.')
    } else {
        $summary.Add('')
        $summary.Add('This was a NON-VOLATILE write to the Spartan-3AN internal In-System Flash.')
        $summary.Add('  Verification comes from the program step itself (`program -v`); the ISF boot')
        $summary.Add('  requirement is MODE pins M[2:0] = 011 with VCCAUX = 3.3 V.')
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
        $extra = ''
        if ($nonVolatileWrite) { $extra += ' MODE VIOLATION: -Mode Jtag asked for a volatile FPGA configuration but the transcript shows internal flash programming; the device non-volatile flash was modified.' }
        if ($serialMismatch) { $extra += ' CABLE MISMATCH: the transcript names cable SN ' + $actualSerial + ' but programming.cableSerial is ' + $cfg.CableSerial + '.' }
        throw "program: result $programResult - programmingCompleted=$($statuses.programmingCompleted), programmingVerified=$($statuses.programmingVerified).$extra (see $($run.RunDir))."
    }
    return [pscustomobject]@{ RunId = $run.RunId; RunDir = $run.RunDir; Statuses = $statuses; Mode = $Mode }
}

