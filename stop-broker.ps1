$ErrorActionPreference = "Stop"

$BROKER_TCP_PORTS = @(1883, 8883, 8884, 3000, 3443, 3444)
$BROKER_UDP_PORTS = @(1351)

function Get-BrokerProcessIds {
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

    return $brokerIds
}

Write-Host "Stopping broker processes..." -ForegroundColor Cyan

$brokerIds = Get-BrokerProcessIds
foreach ($id in $brokerIds) {
    try {
        Write-Host "Stopping broker PID ${id}..." -ForegroundColor Yellow
        Stop-Process -Id $id -Force -ErrorAction Stop
    } catch {
        Write-Host "WARN: Failed to stop PID ${id}: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

if ($brokerIds.Count -eq 0) {
    Write-Host "No broker process found." -ForegroundColor DarkGray
} else {
    Start-Sleep -Seconds 1
    Write-Host "OK: Broker processes stopped." -ForegroundColor Green
}
