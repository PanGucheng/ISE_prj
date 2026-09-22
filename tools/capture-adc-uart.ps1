#Requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = 'Capture')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Capture')]
    [ValidatePattern('^COM[0-9]+$')][string]$Port,
    [Parameter(Mandatory, ParameterSetName = 'Capture')][string]$BitFile,
    [Parameter(Mandatory, ParameterSetName = 'Replay')][string]$InputFile,
    [Parameter(Mandatory, ParameterSetName = 'List')][switch]$ListPorts,
    [ValidateRange(1, 3600)][int]$Seconds = 30,
    [ValidateRange(1200, 1000000)][int]$BaudRate = 115200,
    [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Label = 'adc',
    [string]$OutputDirectory
)

# Auxiliary receive-only tool, not an ise.ps1 command. Never programs hardware,
# writes UART bytes, or enables RTS/DTR. Close VOFA+/other serial readers first.
$ErrorActionPreference = 'Stop'
if ($ListPorts) {
    [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object
    return
}
$workspace = Split-Path $PSScriptRoot
$sourcePath = $null
$bitHash = $null
if ($PSCmdlet.ParameterSetName -eq 'Capture') {
    $sourcePath = (Resolve-Path -LiteralPath $BitFile).Path
    $bitHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
} else {
    $sourcePath = (Resolve-Path -LiteralPath $InputFile).Path
}
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $workspace ('projects/finger_piano_oled_integration/artifacts/uart-' +
        (Get-Date -Format yyyyMMdd-HHmmss) + '-' + $Label + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
}
if (Test-Path -LiteralPath $OutputDirectory) { throw 'OutputDirectory already exists; choose a new evidence directory.' }
$null = New-Item -ItemType Directory -Path $OutputDirectory
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$utf8 = [Text.UTF8Encoding]::new($false)
$raw = [IO.StreamWriter]::new((Join-Path $OutputDirectory 'raw.txt'), $false, $utf8)
$records = [IO.StreamWriter]::new((Join-Path $OutputDirectory 'lines.jsonl'), $false, $utf8)
$counts = [ordered]@{ csvFrames=0; legacyAdcOk=0; adcErrors=0; ready=0; oledOk=0; oledNack=0; note=0; unknown=0; partial=0 }
$errorCounts = @{}
$csvMin = @( $null, $null, $null )
$csvMax = @( $null, $null, $null )
$watch = [Diagnostics.Stopwatch]::new()
$started = [DateTime]::UtcNow.ToString('o')
$ioError = $null
$serial = $null
$buffer = ''
$characters = 0

function Save-Line([string]$Line, [bool]$Complete) {
    $kind = 'unknown'
    $code = $null
    $values = $null
    if (-not $Complete) { $kind = 'partial' }
    elseif ($Line -match '^ADC (?:ERR=|ERROR CODE=)([0-9]+)(?:.*)$') {
        $kind = 'adcErrors'
        $code = [int]$Matches[1]
        $key = [string]$code
        if (-not $errorCounts.ContainsKey($key)) { $errorCounts[$key] = 0 }
        $errorCounts[$key]++
    } elseif ($Line -match '^[+-]?[0-9]+\.[0-9]+,[+-]?[0-9]+\.[0-9]+,[+-]?[0-9]+\.[0-9]+$') {
        $kind = 'csvFrames'
        $values = @($Line.Split(',') | ForEach-Object { [double]::Parse($_, [Globalization.CultureInfo]::InvariantCulture) })
        for ($i=0; $i -lt 3; $i++) {
            if ($null -eq $csvMin[$i] -or $values[$i] -lt $csvMin[$i]) { $csvMin[$i]=$values[$i] }
            if ($null -eq $csvMax[$i] -or $values[$i] -gt $csvMax[$i]) { $csvMax[$i]=$values[$i] }
        }
    } elseif ($Line -match '^ADC OK CH0=0x[0-9A-Fa-f]{4} CH1=0x[0-9A-Fa-f]{4} CH2=0x[0-9A-Fa-f]{4}$') { $kind='legacyAdcOk' }
    elseif ($Line -eq 'READY') { $kind='ready' }
    elseif ($Line -eq 'OLED OK') { $kind='oledOk' }
    elseif ($Line -eq 'OLED NACK') { $kind='oledNack' }
    elseif ($Line -match '^NOTE=') { $kind='note' }
    $counts[$kind]++
    $record = [ordered]@{ utc=[DateTime]::UtcNow.ToString('o'); elapsedMs=$watch.Elapsed.TotalMilliseconds;
        complete=$Complete; kind=$kind; errorCode=$code; values=$values; text=$Line }
    $records.WriteLine(($record | ConvertTo-Json -Depth 4 -Compress))
}

try {
    if ($PSCmdlet.ParameterSetName -eq 'Capture') {
        $serial = [IO.Ports.SerialPort]::new($Port, $BaudRate, [IO.Ports.Parity]::None, 8, [IO.Ports.StopBits]::One)
        $serial.Handshake = [IO.Ports.Handshake]::None
        $serial.DtrEnable = $false
        $serial.RtsEnable = $false
        $serial.Encoding = [Text.Encoding]::ASCII
        $serial.ReadTimeout = 200
        $serial.Open()
        Write-Host "Receiving $Port at $BaudRate 8N1 for $Seconds seconds; no UART writes."
    }
    $watch.Start()
    do {
        if ($PSCmdlet.ParameterSetName -eq 'Replay') { $chunk = [IO.File]::ReadAllText($sourcePath) }
        else { $chunk = $serial.ReadExisting() }
        if ($chunk.Length -gt 0) {
            $raw.Write($chunk)
            $characters += $chunk.Length
            $buffer += $chunk
            while (($newline = $buffer.IndexOf("`n")) -ge 0) {
                Save-Line ($buffer.Substring(0, $newline).TrimEnd("`r")) $true
                $buffer = $buffer.Substring($newline + 1)
            }
            if ($buffer.Length -gt 8192) { Save-Line $buffer $false; $buffer='' }
        }
        if ($PSCmdlet.ParameterSetName -eq 'Replay') { break }
        Start-Sleep -Milliseconds 10
    } while ($watch.Elapsed.TotalSeconds -lt $Seconds)
} catch {
    $ioError = $_.Exception.Message
} finally {
    $watch.Stop()
    if ($buffer.Length -gt 0) { Save-Line $buffer $false }
    if ($null -ne $serial) { $serial.Dispose() }
    $raw.Dispose()
    $records.Dispose()
}
$observation = if ($ioError) { 'IO_ERROR' } elseif ($counts.adcErrors -gt 0) { 'ADC_ERRORS_OBSERVED' }
    elseif (($counts.csvFrames + $counts.legacyAdcOk) -gt 0) { 'ADC_DATA_OBSERVED' } else { 'NO_ADC_DATA_OBSERVED' }
$summary = [ordered]@{
    label=$Label; mode=$PSCmdlet.ParameterSetName; port=$Port; baudRate=$BaudRate; format='8N1';
    dtr=$false; rts=$false; source=$sourcePath; bitSha256=$bitHash;
    bitIdentityNote='Operator-supplied file identity; UART does not prove which image is running.';
    startedUtc=$started; durationSeconds=$watch.Elapsed.TotalSeconds; characters=$characters;
    counts=$counts; adcErrorCounts=$errorCounts; csvMin=$csvMin; csvMax=$csvMax;
    adcErrorLinesPerSecond=$(if ($PSCmdlet.ParameterSetName -eq 'Capture' -and $watch.Elapsed.TotalSeconds -gt 0) { $counts.adcErrors / $watch.Elapsed.TotalSeconds } else { $null });
    observation=$observation; ioError=$ioError;
    interpretation='Absence of errors is not proof of ADC operation. Existing integration firmware reports errors but no successful ADC frames. Replay timestamps are processing times, not original arrival times.'
}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'summary.json'), ($summary | ConvertTo-Json -Depth 6), $utf8)
Write-Host "Observation: $observation"
Write-Host "Evidence: $OutputDirectory"
if ($ioError) { throw $ioError }
