# Dayu ALSA audio bridge

This service gives the smart-home app direct access to the USB audio device
without relying on the broken OpenHarmony USB AudioCapturer/AudioRenderer route.

- Capture: ALSA `arecord` -> UDP `127.0.0.1:19101`
- Playback: TCP `127.0.0.1:19102` -> ALSA `aplay`
- Format: 48 kHz, signed 16-bit little-endian, mono PCM
- Device discovery: `/proc/asound/card*/id` with card id `BAR`
- Startup: `/vendor/etc/init/smart_home_audio_service.cfg`

Install once from PowerShell:

```powershell
.\tools\dayu-audio-service\install.ps1
```

Then reboot Dayu. The service works whether the USB card becomes `card0` or
`card3`.

Remove and restore the original boot setup:

```powershell
.\tools\dayu-audio-service\uninstall.ps1
```
