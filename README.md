# YuHome Terminal

YuHome Terminal (禹家终端) is an OpenHarmony smart-home control center built
for the Dayu development board. It runs the home gateway locally, so normal
operation does not require a permanently running PC.

## Features

- Embedded NanoMQ MQTT broker and HTTP bridge on the Dayu terminal
- MQTT, MQTTS, HTTP and HTTPS device transports
- Per-device ECDH sessions with SM4-GCM and AES-GCM payload encryption
- Multi-device discovery through `device_hello` and capability-based routing
- Lighting, air-conditioner, curtain and door-lock control
- Universal air-conditioner IR learning
- Local wake word, streaming ASR and semantic command parsing
- Local speaker verification and face access control
- Smoke/water alarm display, acknowledgement and source-device routing
- USB serial provisioning for new devices

## Current LAN Endpoints

| Service | Plain | TLS |
| --- | ---: | ---: |
| MQTT | `1883` | `8884` |
| HTTP | `3000` | `3444` |

The application connects to its embedded broker over the local loopback
interface. ESP32 devices use the Dayu LAN address, normally with MQTTS or
HTTPS. Business payloads remain encrypted with SM4-GCM or AES-GCM above TLS.

## Repository Layout

```text
entry/src/main/ets/          OpenHarmony UI and application logic
entry/src/main/cpp/          Native inference and local gateway
entry/src/main/resources/    Models, prompts, certificates and UI resources
docs/                        User, algorithm and protocol documentation
deploy.bat / deploy.ps1      Dayu installation helper
screenshot.bat               Dayu screenshot helper for Windows
```

NanoMQ and Mbed TLS are vendored under
`entry/src/main/cpp/third_party` because the project contains a small
concurrency fix required by the embedded MQTTS listener.

## Prerequisites

- DevEco Studio with the OpenHarmony SDK used by the project
- Huawei `hdc`
- Git LFS
- A Dayu development board
- The NCNN OpenHarmony runtime referenced by `entry/src/main/cpp/CMakeLists.txt`

After cloning, run:

```powershell
git lfs install
git lfs pull
```

## TLS Private Keys

Private keys are intentionally not included in this public repository.

Before building a TLS-enabled local gateway, provision a certificate and its
matching private key at:

```text
entry/src/main/resources/rawfile/gateway/server.crt
entry/src/main/resources/rawfile/gateway/server.key
```

`server.key` is ignored by Git. The repository contains only public
certificate material. Use a certificate whose SAN contains the Dayu LAN IP,
or provision a trusted local CA for your deployment.

The public version of
`entry/src/main/ets/mqtt/TlsClientIdentity.ets` contains empty placeholders.
If mutual TLS is required, provision a unique client identity per terminal by
secure local configuration or a hardware-backed keystore. Never commit the
private key.

## Build

Build with DevEco Studio, or use the project's hvigor wrapper/configuration.
The generated signed HAP is expected at:

```text
entry/build/default/outputs/default/entry-default-signed.hap
```

Then connect the Dayu board over USB and run:

```text
deploy.bat
```

The device ID and HDC path in `deploy.ps1` are development-machine defaults;
adjust them for another board or SDK installation.

## Device Contract

Each ESP32 owns a stable ID generated from its base MAC:

```text
esp32-XXXXXXXXXXXX
```

Important topics:

```text
dayu/cmd/{deviceId}
device/{deviceId}/sensor
device/{deviceId}/ac
device/{deviceId}/status
key/ecdh/pub/{deviceId}
```

Every ACK must include the real `deviceId` and echo the command `seq`.

## Documentation

- [禹家终端详细使用说明](docs/禹家终端详细使用说明.md)
- [大禹本地网关协议](docs/DAYU_LOCAL_GATEWAY_PROTOCOL.md)
- [大禹硬件与通信接口说明](docs/大禹智能家居终端硬件与通信接口说明.md)
- [语音助手算法设计与实现](docs/大禹语音助手算法设计与实现.md)
- [串口配网算法详细设计](docs/串口配网算法详细设计.md)
- [人脸识别算法详细设计](docs/人脸识别算法详细设计.md)

## Security Notes

- Keep production TLS keys out of Git.
- Replace development static fallback keys before production deployment.
- Prefer MQTTS/HTTPS plus SM4-GCM or AES-GCM.
- Assign every device a unique `deviceId`.
- Reserve the Dayu LAN address in the home router.
