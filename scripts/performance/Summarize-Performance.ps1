[CmdletBinding()]
param(
    [string]$SessionDirectory = ''
)

$ErrorActionPreference = 'Stop'

if ($SessionDirectory.Length -eq 0) {
    $root = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'performance-results'
    $latest = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) {
        throw 'No performance session was found.'
    }
    $SessionDirectory = $latest.FullName
}
$SessionDirectory = (Resolve-Path -LiteralPath $SessionDirectory).Path
$eventPath = Join-Path $SessionDirectory 'performance-events.jsonl'
if (-not (Test-Path -LiteralPath $eventPath)) {
    throw "Missing event file: $eventPath"
}

$events = @(Get-Content -LiteralPath $eventPath -Encoding UTF8 | Where-Object { $_.Trim().Length -gt 0 } |
    ForEach-Object { $_ | ConvertFrom-Json })
if ($events.Count -eq 0) {
    throw 'The session contains no PERF events. Install and run the instrumented DAYU HAP first.'
}

function Find-Stage($items, [string]$stage, [switch]$Last) {
    $matches = @($items | Where-Object { $_.stage -eq $stage } | Sort-Object timestampMs)
    if ($matches.Count -eq 0) { return $null }
    if ($Last) { return $matches[-1] }
    return $matches[0]
}

function Sum-StagePairs($items, [string]$startStage, [string]$endStage) {
    $starts = @($items | Where-Object { $_.stage -eq $startStage } | Sort-Object timestampMs)
    $ends = @($items | Where-Object { $_.stage -eq $endStage } | Sort-Object timestampMs)
    $count = [Math]::Min($starts.Count, $ends.Count)
    $sum = 0.0
    for ($i = 0; $i -lt $count; $i++) {
        $sum += [double]$ends[$i].timestampMs - [double]$starts[$i].timestampMs
    }
    return $sum
}

$terminalStages = @('device_ack', 'switch_ack', 'execution_result', 'flow_failed', 'identify_failed',
    'device_timeout', 'switch_timeout', 'send_failed', 'preview_failed', 'sample_failed',
    'alarm_cloud_reported', 'alarm_receipt_sent', 'alarm_receipt_failed')
$rows = @()
$incomplete = @()

foreach ($group in ($events | Group-Object traceId)) {
    $items = @($group.Group | Sort-Object timestampMs)
    $category = [string]$items[0].category
    $startStage = switch ($category) {
        'lighting' { 'command_send' }
        'ac' { 'command_send' }
        'door' { 'command_send' }
        'curtain' { 'command_send' }
        'alarm' { 'alarm_received' }
        'protocol' { 'switch_request' }
        'crypto' { 'switch_request' }
        'voice' { 'wake_detected' }
        'face' { 'identify_start' }
        default { [string]$items[0].stage }
    }
    $start = Find-Stage $items $startStage
    $endCandidates = @($items | Where-Object { $terminalStages -contains $_.stage } | Sort-Object timestampMs)
    if (-not $start -or $endCandidates.Count -eq 0) {
        $incomplete += $group.Name
        continue
    }
    $end = $endCandidates[-1]
    $transport = Find-Stage $items 'transport_sent'
    $ack = Find-Stage $items 'device_ack'
    $firstAsr = Find-Stage $items 'asr_first_result'
    $finalAsr = Find-Stage $items 'asr_final'
    $intent = Find-Stage $items 'intent_parsed'
    $verified = Find-Stage $items 'identity_verified'
    $algorithmMs = if ($category -eq 'face') { Sum-StagePairs $items 'inference_start' 'inference_complete' } else { 0 }
    $success = [bool]$end.success -and @('device_ack', 'switch_ack', 'execution_result',
        'alarm_cloud_reported', 'alarm_receipt_sent') -contains [string]$end.stage
    if ($category -eq 'face' -and $end.stage -eq 'device_ack') { $success = [bool]$end.success }
    $rows += [pscustomobject][ordered]@{
        TraceId = $group.Name
        Category = $category
        Seq = [int]$end.seq
        Config = if ($category -eq 'protocol' -or $category -eq 'crypto') { [string]$start.detail } else { '' }
        Success = $success
        TerminalStage = [string]$end.stage
        DurationMs = [double]$end.timestampMs - [double]$start.timestampMs
        TransportMs = if ($transport) { [double]$transport.timestampMs - [double]$start.timestampMs } else { $null }
        AckWaitMs = if ($transport -and $ack) { [double]$ack.timestampMs - [double]$transport.timestampMs } else { $null }
        WakeToFirstAsrMs = if ($category -eq 'voice' -and $firstAsr) { [double]$firstAsr.timestampMs - [double]$start.timestampMs } else { $null }
        AsrFinalizeMs = if ($firstAsr -and $finalAsr) { [double]$finalAsr.timestampMs - [double]$firstAsr.timestampMs } else { $null }
        IntentToResultMs = if ($intent) { [double]$end.timestampMs - [double]$intent.timestampMs } else { $null }
        FaceInferenceMs = if ($category -eq 'face') { $algorithmMs } else { $null }
        FaceVerifyMs = if ($category -eq 'face' -and $verified) { [double]$verified.timestampMs - [double]$start.timestampMs } else { $null }
        Detail = [string]$end.detail
    }
}

function Get-Percentile95([double[]]$values) {
    if ($values.Count -eq 0) { return 0 }
    $sorted = @($values | Sort-Object)
    $index = [Math]::Max(0, [Math]::Ceiling($sorted.Count * 0.95) - 1)
    return [double]$sorted[$index]
}

$summary = @()
foreach ($group in ($rows | Group-Object Category)) {
    $durations = [double[]]@($group.Group | ForEach-Object { [double]$_.DurationMs })
    $successCount = @($group.Group | Where-Object Success).Count
    $summary += [pscustomobject][ordered]@{
        Category = $group.Name
        Samples = $group.Count
        Success = $successCount
        SuccessRate = [Math]::Round(100 * $successCount / $group.Count, 2)
        AverageMs = [Math]::Round(($durations | Measure-Object -Average).Average, 1)
        MinimumMs = [Math]::Round(($durations | Measure-Object -Minimum).Minimum, 1)
        MaximumMs = [Math]::Round(($durations | Measure-Object -Maximum).Maximum, 1)
        P95Ms = [Math]::Round((Get-Percentile95 $durations), 1)
    }
}

$trialPath = Join-Path $SessionDirectory 'performance-trials.csv'
$summaryPath = Join-Path $SessionDirectory 'performance-summary.csv'
$combinationPath = Join-Path $SessionDirectory 'security-combinations.csv'
$rows | Export-Csv -LiteralPath $trialPath -NoTypeInformation -Encoding UTF8
$summary | Export-Csv -LiteralPath $summaryPath -NoTypeInformation -Encoding UTF8

$combinationSummary = @()
foreach ($group in ($rows | Where-Object { $_.Category -eq 'protocol' -or $_.Category -eq 'crypto' } |
    Group-Object Category, Config)) {
    $durations = [double[]]@($group.Group | ForEach-Object { [double]$_.DurationMs })
    $successCount = @($group.Group | Where-Object Success).Count
    $combinationSummary += [pscustomobject][ordered]@{
        Category = $group.Group[0].Category
        Config = $group.Group[0].Config
        Samples = $group.Count
        Success = $successCount
        SuccessRate = [Math]::Round(100 * $successCount / $group.Count, 2)
        AverageMs = [Math]::Round(($durations | Measure-Object -Average).Average, 1)
        MaximumMs = [Math]::Round(($durations | Measure-Object -Maximum).Maximum, 1)
        P95Ms = [Math]::Round((Get-Percentile95 $durations), 1)
    }
}
$combinationSummary | Export-Csv -LiteralPath $combinationPath -NoTypeInformation -Encoding UTF8

Write-Host ''
Write-Host 'YuJia Performance Summary' -ForegroundColor Cyan
Write-Host "Evidence : $eventPath"
Write-Host "Trials   : $trialPath"
Write-Host "Summary  : $summaryPath"
Write-Host "Security : $combinationPath"
Write-Host ''
$summary | Format-Table -AutoSize
if ($incomplete.Count -gt 0) {
    Write-Host "Incomplete traces: $($incomplete.Count)" -ForegroundColor Yellow
    $incomplete | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkYellow }
}
