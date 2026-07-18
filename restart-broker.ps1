$ErrorActionPreference = "Stop"

$PROJECT_ROOT = Split-Path -Parent $MyInvocation.MyCommand.Path
$START_BROKER_SCRIPT = Join-Path $PROJECT_ROOT "start-broker.ps1"
$BROKER_SCRIPT = Join-Path $PROJECT_ROOT "broker.js"
$BROKER_TCP_PORTS = @(1883, 8883, 8884, 3000, 3443, 3444)
$BROKER_UDP_PORTS = @(1351)

Set-Location $PROJECT_ROOT

function Stop-ExistingBroker {
    $brokerIds = New-Object "System.Collections.Generic.HashSet[int]"

    Get-CimInstance Win32_Process |
        Where-Object {
            ($_.Name -eq "node.exe" -or $_.Name -eq "node") -and
            $_.CommandLine -and
            ($_.CommandLine -match '(^|[\\/\s"])broker\.js(["\s]|$)')
        } |
        ForEach-Object {
            [void]$brokerIds.Add([int]$_.ProcessId)
        }

    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $BROKER_TCP_PORTS -contains $_.LocalPort } |
        ForEach-Object {
            try {
                $process = Get-Process -Id $_.OwningProcess -ErrorAction Stop
                if ($process.ProcessName -eq "node") {
                    [void]$brokerIds.Add([int]$_.OwningProcess)
                }
            } catch {}
        }

    Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
        Where-Object { $BROKER_UDP_PORTS -contains $_.LocalPort } |
        ForEach-Object {
            try {
                $process = Get-Process -Id $_.OwningProcess -ErrorAction Stop
                if ($process.ProcessName -eq "node") {
                    [void]$brokerIds.Add([int]$_.OwningProcess)
                }
            } catch {}
        }

    foreach ($id in $brokerIds) {
        try {
            Write-Host "Stopping old broker PID ${id}..." -ForegroundColor Yellow
            Stop-Process -Id $id -Force -ErrorAction Stop
        } catch {
            Write-Host "WARN: Failed to stop PID ${id}: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    if ($brokerIds.Count -gt 0) {
        Start-Sleep -Seconds 2
    } else {
        Write-Host "No old broker process found" -ForegroundColor DarkGray
    }
}

Write-Host "Restarting broker with latest code..." -ForegroundColor Cyan

if (-not (Test-Path $BROKER_SCRIPT)) {
    Write-Host "FAIL: broker.js not found at $BROKER_SCRIPT" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $START_BROKER_SCRIPT)) {
    Write-Host "FAIL: start-broker.ps1 not found at $START_BROKER_SCRIPT" -ForegroundColor Red
    exit 1
}

Stop-ExistingBroker

Start-Process powershell -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$START_BROKER_SCRIPT`"") -WindowStyle Hidden
$brokerRunning = $null
for ($attempt = 1; $attempt -le 15; $attempt++) {
    $brokerRunning = Get-NetTCPConnection -State Listen -LocalPort 3000 -ErrorAction SilentlyContinue
    if ($brokerRunning) {
        break
    }
    Start-Sleep -Seconds 1
}

if ($brokerRunning) {
    Write-Host "OK: Fresh broker started (http://192.168.3.5:3000)" -ForegroundColor Green
} else {
    Write-Host "WARN: Broker start was requested, but port 3000 did not listen within 15 seconds." -ForegroundColor Yellow
}
