@echo off
setlocal EnableExtensions

set "HDC=C:\huaweisdk\11\toolchains\hdc.exe"
set "TARGET=c4010b545753432020f0e528ee0c6c00"
set "REMOTE_FILE=/data/local/tmp/dayu_screenshot.jpeg"

if not exist "%HDC%" (
  echo [ERROR] HDC was not found: %HDC%
  pause
  exit /b 1
)

"%HDC%" list targets | findstr /c:"%TARGET%" >nul
if errorlevel 1 (
  echo [ERROR] Dayu is not connected.
  echo Check the USB cable, device power, and HDC connection.
  echo.
  "%HDC%" list targets
  pause
  exit /b 1
)

for /f "usebackq delims=" %%I in (`powershell -NoProfile -Command "Get-Date -Format 'yyyyMMdd-HHmmss'"`) do set "STAMP=%%I"

set "TEMP_FILE=%TEMP%\Dayu-%STAMP%.jpeg"

echo Capturing the Dayu screen...
"%HDC%" -t "%TARGET%" shell "snapshot_display -f %REMOTE_FILE%"
if errorlevel 1 goto :capture_failed

"%HDC%" -t "%TARGET%" file recv "%REMOTE_FILE%" "%TEMP_FILE%"
if errorlevel 1 goto :capture_failed

"%HDC%" -t "%TARGET%" shell "rm -f %REMOTE_FILE%" >nul 2>&1
if not exist "%TEMP_FILE%" goto :capture_failed

powershell -NoProfile -Command "$src=Join-Path $env:TEMP 'Dayu-%STAMP%.jpeg'; $dir=Join-Path ([Environment]::GetFolderPath('Desktop')) 'DayuScreenshots'; [IO.Directory]::CreateDirectory($dir) | Out-Null; $dst=Join-Path $dir 'Dayu-%STAMP%.jpeg'; Move-Item -LiteralPath $src -Destination $dst -Force; Write-Host $dst; Start-Process -FilePath $dst"
if errorlevel 1 goto :capture_failed

echo.
echo [OK] Screenshot saved to Desktop\DayuScreenshots.
exit /b 0

:capture_failed
echo.
echo [ERROR] Screenshot failed. Check the device connection and try again.
pause
exit /b 1
