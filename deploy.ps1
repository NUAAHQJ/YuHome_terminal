$ErrorActionPreference = "Stop"

$HDC         = "C:\huaweisdk\11\toolchains\hdc.exe"
$DEVICE_ID   = "c4010b545753432020f0e528ee0c6c00"
$HAP_PATH    = "entry\build\default\outputs\default\entry-default-signed.hap"
$BUNDLE_NAME = "com.example.my_smart_home"
$ENTRY_ABILITY = "EntryAbility"
$PROJECT_ROOT = Split-Path -Parent $MyInvocation.MyCommand.Path
$REMOTE_HAP = "/data/local/tmp/yujia-terminal.hap"

Set-Location $PROJECT_ROOT

# ---- 1. Check device --------------------------------------------------
Write-Host "[1/4] Checking Dayu210..." -ForegroundColor Cyan
$targets = @()
for ($i = 1; $i -le 5; $i++) {
    $targets = & $HDC list targets 2>&1
    if (($targets -join "`n") -match [regex]::Escape($DEVICE_ID)) {
        break
    }
    if ($i -lt 5) {
        Write-Host "  Waiting for device... ($i/5)" -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    }
}
if (($targets -join "`n") -notmatch [regex]::Escape($DEVICE_ID)) {
    Write-Host "  FAIL: Device $DEVICE_ID not found" -ForegroundColor Red
    Write-Host "  hdc targets:" -ForegroundColor Yellow
    $targets | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    Write-Host "  Check USB cable and power." -ForegroundColor Yellow
    pause
    exit 1
}
Write-Host "  OK: Device connected" -ForegroundColor Green

# ---- 2. Check package -------------------------------------------------
Write-Host "[2/4] Checking HAP package..." -ForegroundColor Cyan
if (-not (Test-Path $HAP_PATH)) {
    Write-Host "  FAIL: HAP not found at $HAP_PATH" -ForegroundColor Red
    Write-Host "  Build the project in DevEco Studio first." -ForegroundColor Yellow
    pause
    exit 1
}
Write-Host "  OK: HAP is ready" -ForegroundColor Green

# ---- 3. Transfer and install HAP -------------------------------------
Write-Host "[3/4] Installing HAP (gateway is built into Dayu)..." -ForegroundColor Cyan
$sendResult = & $HDC -t $DEVICE_ID file send $HAP_PATH $REMOTE_HAP 2>&1
if (($LASTEXITCODE -ne 0) -or (($sendResult -join "`n") -notmatch "finish")) {
    Write-Host "  FAIL: $sendResult" -ForegroundColor Red
    pause
    exit 1
}
$installResult = & $HDC -t $DEVICE_ID shell "bm install -r -p $REMOTE_HAP -w 600" 2>&1
if ($installResult -match "successfully") {
    Write-Host "  OK: HAP installed" -ForegroundColor Green
} else {
    Write-Host "  FAIL: $installResult" -ForegroundColor Red
    pause
    exit 1
}

# ---- 4. Launch app ----------------------------------------------------
Write-Host "[4/4] Launching app..." -ForegroundColor Cyan
$startResult = & $HDC -t $DEVICE_ID shell "aa start -a $ENTRY_ABILITY -b $BUNDLE_NAME" 2>&1
if ($startResult -match "successfully") {
    Write-Host "  OK: App launched" -ForegroundColor Green
} else {
    Write-Host "  WARN: $startResult" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Deploy complete! MQTT/HTTP gateway runs on Dayu." -ForegroundColor Green
Write-Host "  PC broker is no longer started automatically." -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
pause
