param(
  [string]$Hdc = "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe",
  [string]$DeviceId = "c4010b545753432020f0e528ee0c6c00"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ServiceScript = Join-Path $Root "smart_home_audio_service.sh"
$ServiceConfig = Join-Path $Root "smart_home_audio_service.cfg"

& $Hdc -t $DeviceId file send $ServiceScript /data/local/tmp/smart_home_audio_service.install.sh
& $Hdc -t $DeviceId file send $ServiceConfig /data/local/tmp/smart_home_audio_service.install.cfg
& $Hdc -t $DeviceId shell 'mount -o remount,rw /vendor; cp /data/local/tmp/smart_home_audio_service.install.sh /vendor/bin/smart_home_audio_service.sh; cp /data/local/tmp/smart_home_audio_service.install.cfg /vendor/etc/init/smart_home_audio_service.cfg; chown root:shell /vendor/bin/smart_home_audio_service.sh; chmod 750 /vendor/bin/smart_home_audio_service.sh; chown root:root /vendor/etc/init/smart_home_audio_service.cfg; chmod 644 /vendor/etc/init/smart_home_audio_service.cfg; sync; mount -o remount,ro /vendor'
& $Hdc -t $DeviceId shell 'ls -l /vendor/bin/smart_home_audio_service.sh /vendor/etc/init/smart_home_audio_service.cfg'

Write-Host "Installed. Reboot Dayu to start smart_home_audio_service." -ForegroundColor Green
