[CmdletBinding()]
param(
    [string]$Target = '',
    [string]$OutputDirectory = '',
    [switch]$KeepExistingLog
)

$ErrorActionPreference = 'Stop'

function Resolve-HdcPath {
    $command = Get-Command hdc -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    $bundled = 'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
    if (Test-Path -LiteralPath $bundled) {
        return $bundled
    }
    throw 'hdc.exe was not found. Install DevEco Studio or add hdc to PATH.'
}

$hdc = Resolve-HdcPath
$targets = @(& $hdc list targets 2>$null | ForEach-Object {
    $value = $_.Trim()
    if ($value.Length -gt 0 -and $value -ne '[Empty]' -and $value -notmatch '^\[Fail\]') {
        $value
    }
})
if ($Target.Length -eq 0) {
    if ($targets.Count -ne 1) {
        throw "Expected exactly one HDC target, found $($targets.Count). Use -Target explicitly."
    }
    $Target = $targets[0].Trim()
}
if ($Target -eq '[Empty]' -or $Target -match '^\[Fail\]' -or $targets -notcontains $Target) {
    throw "HDC target is not online: $Target"
}

if ($OutputDirectory.Length -eq 0) {
    $root = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'performance-results'
    $OutputDirectory = Join-Path $root (Get-Date -Format 'yyyyMMdd-HHmmss')
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$rawPath = Join-Path $OutputDirectory 'hilog-evidence.log'
$eventPath = Join-Path $OutputDirectory 'performance-events.jsonl'
$metadataPath = Join-Path $OutputDirectory 'session.json'

$metadata = [ordered]@{
    target = $Target
    startedAt = (Get-Date).ToString('o')
    hdcVersion = ((& $hdc version 2>$null) -join ' ')
    collector = 'YuJia local performance collector v1'
}
$metadata | ConvertTo-Json | Set-Content -LiteralPath $metadataPath -Encoding UTF8
New-Item -ItemType File -Path $rawPath -Force | Out-Null
New-Item -ItemType File -Path $eventPath -Force | Out-Null

if (-not $KeepExistingLog) {
    & $hdc -t $Target shell hilog -r 2>$null | Out-Null
}

Write-Host ''
Write-Host 'YuJia Local Performance Capture' -ForegroundColor Cyan
Write-Host "Target : $Target"
Write-Host "Output : $OutputDirectory"
Write-Host 'Operate lighting, AC, door, curtain, water alarm, protocol/crypto, voice and face on DAYU.' -ForegroundColor Yellow
Write-Host 'Press Ctrl+C after the required samples are complete.' -ForegroundColor Yellow
Write-Host ('-' * 96) -ForegroundColor DarkGray

try {
    & $hdc -t $Target shell hilog 2>&1 | ForEach-Object {
        $line = "$_"
        if ($line -match '\[PERF\]|\[(LED|AC|DOOR|PROTO|Crypto|VoiceAssistant|FaceAccess)\]') {
            Add-Content -LiteralPath $rawPath -Value $line -Encoding UTF8
        }
        $marker = $line.IndexOf('[PERF] ')
        if ($marker -lt 0) {
            return
        }
        $json = $line.Substring($marker + 7).Trim()
        try {
            $event = $json | ConvertFrom-Json
            Add-Content -LiteralPath $eventPath -Value $json -Encoding UTF8
            $color = if ($event.success) { 'Green' } else { 'Red' }
            $time = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$event.timestampMs).ToLocalTime().ToString('HH:mm:ss.fff')
            Write-Host ("{0}  {1,-10} {2,-22} seq={3,-6} {4}" -f $time, $event.category, $event.stage, $event.seq, $event.traceId) -ForegroundColor $color
        } catch {
            Write-Host "Malformed PERF event: $json" -ForegroundColor Red
        }
    }
} finally {
    Write-Host ''
    Write-Host "Evidence saved in $OutputDirectory" -ForegroundColor Cyan
}
