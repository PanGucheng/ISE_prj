#Requires -Version 7.0
$ErrorActionPreference='Stop'
$root=Join-Path $PSScriptRoot ('.work/uart-test-' + [guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
$inputPath=Join-Path $root 'input.txt'
$sample="READY`r`nOLED OK`r`n0.1000,1.2000,2.3000`r`n0.2000,1.1000,2.5000`r`nADC ERR=4`r`nADC ERR=5`r`nADC ERROR CODE=1`r`nADC OK CH0=0x1234 CH1=0x3456 CH2=0x5678`r`nnoise`r`nADC ERR=4"
[IO.File]::WriteAllText($inputPath,$sample)
& "$PSScriptRoot/capture-adc-uart.ps1" -InputFile $inputPath -OutputDirectory "$root/mixed" -Label fixture
$s=Get-Content "$root/mixed/summary.json" -Raw|ConvertFrom-Json
if ($s.counts.csvFrames -ne 2 -or $s.counts.legacyAdcOk -ne 1 -or $s.counts.adcErrors -ne 3 -or $s.counts.partial -ne 1) { throw 'Frame classification or partial-line handling failed' }
if ($s.adcErrorCounts.'4' -ne 1 -or $s.adcErrorCounts.'5' -ne 1 -or $s.csvMin[1] -ne 1.1 -or $s.csvMax[2] -ne 2.5) { throw 'Error histogram or CSV extrema failed' }
if ($s.observation -ne 'ADC_ERRORS_OBSERVED' -or $null -ne $s.adcErrorLinesPerSecond) { throw 'Replay verdict/rate failed' }
if ([IO.File]::ReadAllText("$root/mixed/raw.txt") -cne $sample) { throw 'Raw evidence altered' }
foreach ($case in @(@('silent','','NO_ADC_DATA_OBSERVED'), @('ready',"READY`r`n",'NO_ADC_DATA_OBSERVED'), @('data',"0.1000,1.2000,2.3000`r`n",'ADC_DATA_OBSERVED'))) {
    [IO.File]::WriteAllText($inputPath,$case[1])
    & "$PSScriptRoot/capture-adc-uart.ps1" -InputFile $inputPath -OutputDirectory (Join-Path $root $case[0]) -Label fixture
    $r=Get-Content (Join-Path $root ($case[0]+'/summary.json')) -Raw|ConvertFrom-Json
    if ($r.observation -ne $case[2]) { throw "Unexpected observation for $($case[0])" }
}
Write-Host "PASS: ADC UART capture parser (offline; no serial port opened). Evidence: $root"
