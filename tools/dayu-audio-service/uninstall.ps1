param(
  [string]$Hdc = "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe",
  [string]$DeviceId = "c4010b545753432020f0e528ee0c6c00"
)

$ErrorActionPreference = "Stop"

& $Hdc -t $DeviceId shell 'begetctl stop_service smart_home_audio_service; mount -o remount,rw /vendor; rm -f /vendor/bin/smart_home_audio_service.sh /vendor/etc/init/smart_home_audio_service.cfg; sync; mount -o remount,ro /vendor'

Write-Host "Removed. Reboot Dayu to complete cleanup." -ForegroundColor Green
