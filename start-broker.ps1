$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$MqttPort = if ($env:MQTT_PORT) { [int]$env:MQTT_PORT } else { 1883 }
$MqttTlsPort = if ($env:MQTT_TLS_PORT) { [int]$env:MQTT_TLS_PORT } else { 8883 }
$Esp32MqttTlsPort = if ($env:ESP32_MQTT_TLS_PORT) { [int]$env:ESP32_MQTT_TLS_PORT } else { 8884 }
$BridgePort = if ($env:BRIDGE_PORT) { [int]$env:BRIDGE_PORT } else { 3000 }
$BridgeHttpsPort = if ($env:BRIDGE_HTTPS_PORT) { [int]$env:BRIDGE_HTTPS_PORT } else { 3444 }
$BridgeTlsPort = if ($env:BRIDGE_TLS_PORT) { [int]$env:BRIDGE_TLS_PORT } else { 3443 }
$Esp32UdpRelayPort = if ($env:ESP32_UDP_RELAY_PORT) { [int]$env:ESP32_UDP_RELAY_PORT } else { 1351 }

Set-Location $ProjectRoot

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ' Smart Home Local MQTT Broker' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ''

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Write-Host '[ERROR] Node.js is not available in PATH.' -ForegroundColor Red
  Write-Host 'Install Node.js or open this project from an environment where node works.'
  exit 1
}

if (-not (Test-Path (Join-Path $ProjectRoot 'node_modules\aedes'))) {
  Write-Host '[INFO] Dependencies are missing. Installing npm packages...' -ForegroundColor Yellow
  npm install
}

$tcpListeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
  Where-Object { $_.LocalPort -eq $MqttPort -or $_.LocalPort -eq $MqttTlsPort -or $_.LocalPort -eq $Esp32MqttTlsPort -or $_.LocalPort -eq $BridgePort -or $_.LocalPort -eq $BridgeHttpsPort -or $_.LocalPort -eq $BridgeTlsPort -or $_.LocalPort -eq $Esp32UdpRelayPort }
$udpListeners = Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
  Where-Object { $_.LocalPort -eq $Esp32UdpRelayPort }
if ($tcpListeners -or $udpListeners) {
  Write-Host "[WARN] Required port is already in use:" -ForegroundColor Yellow
  $tcpListeners | ForEach-Object {
    $processName = 'unknown'
    try {
      $processName = (Get-Process -Id $_.OwningProcess -ErrorAction Stop).ProcessName
    } catch {}
    Write-Host "  TCP PID $($_.OwningProcess) ($processName) is listening on $($_.LocalAddress):$($_.LocalPort)"
  }
  $udpListeners | ForEach-Object {
    $processName = 'unknown'
    try {
      $processName = (Get-Process -Id $_.OwningProcess -ErrorAction Stop).ProcessName
    } catch {}
    Write-Host "  UDP PID $($_.OwningProcess) ($processName) is listening on $($_.LocalAddress):$($_.LocalPort)"
  }
  Write-Host ''
  Write-Host 'If this is an old broker window, close it first. Otherwise change MQTT_PORT/BRIDGE_PORT and restart.'
  exit 1
}

Write-Host '[INFO] Current IPv4 addresses:' -ForegroundColor Green
$addresses = Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { $_.IPAddress -notlike '127.*' -and $_.PrefixOrigin -ne 'WellKnown' } |
  Sort-Object { if ($_.InterfaceAlias -like '*WLAN*' -or $_.InterfaceAlias -like '*Wi-Fi*') { 0 } else { 1 } }, InterfaceAlias

foreach ($addr in $addresses) {
  $label = if ($addr.InterfaceAlias -like '*WLAN*' -or $addr.InterfaceAlias -like '*Wi-Fi*') { ' <= use this for ESP32/Dayu210 if on Wi-Fi' } else { '' }
  Write-Host "  $($addr.InterfaceAlias): mqtt://$($addr.IPAddress):$MqttPort    ESP32 MQTT$label"
  Write-Host "  $($addr.InterfaceAlias): mqtts://$($addr.IPAddress):$MqttTlsPort   DAYU MQTT mutual TLS$label"
  Write-Host "  $($addr.InterfaceAlias): mqtts://$($addr.IPAddress):$Esp32MqttTlsPort   ESP32 MQTT server-auth TLS$label"
  Write-Host "  $($addr.InterfaceAlias): http://$($addr.IPAddress):$BridgePort   DAYU Bridge"
  Write-Host "  $($addr.InterfaceAlias): https://$($addr.IPAddress):$BridgeHttpsPort   ESP32/DAYU HTTPS Bridge"
  Write-Host "  $($addr.InterfaceAlias): wss://$($addr.IPAddress):$BridgeTlsPort    DAYU mutual TLS WebSocket bridge"
  Write-Host "  $($addr.InterfaceAlias): udp://$($addr.IPAddress):$Esp32UdpRelayPort    ESP32 UDP -> DAYU"
}

Write-Host ''
Write-Host "[INFO] Starting MQTT broker on mqtt://0.0.0.0:$MqttPort" -ForegroundColor Green
Write-Host "[INFO] Starting MQTT TLS broker on mqtts://0.0.0.0:$MqttTlsPort" -ForegroundColor Green
Write-Host "[INFO] Starting ESP32 MQTT TLS broker on mqtts://0.0.0.0:$Esp32MqttTlsPort" -ForegroundColor Green
Write-Host "[INFO] Starting HTTP bridge on http://0.0.0.0:$BridgePort" -ForegroundColor Green
Write-Host "[INFO] Starting HTTPS bridge on https://0.0.0.0:$BridgeHttpsPort" -ForegroundColor Green
Write-Host "[INFO] Starting DAYU mutual TLS WebSocket bridge on wss://0.0.0.0:$BridgeTlsPort" -ForegroundColor Green
Write-Host "[INFO] Starting ESP32 UDP relay on udp://0.0.0.0:$Esp32UdpRelayPort" -ForegroundColor Green
Write-Host '[INFO] Keep this window open while debugging. Press Ctrl+C to stop.'
Write-Host ''

node broker.js
