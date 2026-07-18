# Dayu Local Gateway Protocol

This document freezes the LAN protocol used while moving the PC gateway into
the Dayu terminal. The existing PC `broker.js` remains the rollback target
until every compatibility check passes.

## Network endpoints

| Transport | Plain | TLS | Purpose |
| --- | ---: | ---: | --- |
| MQTT | 1883 | 8884 | ESP32 publish, command and key exchange |
| HTTP | 3000 | 3444 | ESP32 sensor/ACK upload and command polling |

The Dayu UI talks to the local gateway in-process. Ports are exposed only for
ESP32 devices on the home LAN. MQTT is provided by embedded NanoMQ; TLS for
MQTTS and HTTPS is provided by the bundled mbedTLS runtime.

New-device provisioning automatically uses the Dayu Wi-Fi IPv4 address. The
TLS switch selects `mqtts://{dayu-ip}:8884` and
`https://{dayu-ip}:3444`; plain mode selects ports 1883 and 3000.

## Device identity and topics

Each board owns one stable `deviceId`, normally generated from its base MAC:

```text
esp32-XXXXXXXXXXXX
```

Scoped topics:

```text
dayu/cmd/{deviceId}
device/{deviceId}/sensor
device/{deviceId}/ac
device/{deviceId}/status
key/ecdh/pub/{deviceId}
```

The legacy `esp32` ID may use `dayu/cmd`. New devices must use scoped topics.

## Encryption contract

MQTT payloads and HTTP `payloadBase64` values carry the same encrypted frame:

```text
12-byte IV | 16-byte GCM tag | ciphertext
```

Supported modes are AES-GCM and SM4-GCM. Each `deviceId` independently owns:

- AES dynamic key
- SM4 dynamic key
- epoch
- selected transport and crypto mode
- ECDH pending and recovery state

A 65-byte uncompressed ECDH public key beginning with `0x04` is routed as raw
key material and is not passed through GCM decryption.

The gateway never decrypts business payloads. It routes opaque bytes to the
existing Dayu crypto layer.

TLS secures the LAN transport. AES-GCM or SM4-GCM still secures the business
payload end to end, and ECDH still creates an independent dynamic key set for
each `deviceId`.

## HTTP sensor upload

```http
POST /api/http/sensor
Content-Type: application/json
```

```json
{
  "deviceId": "esp32-94A990D24D10",
  "topic": "device/esp32-94A990D24D10/ac",
  "crypto": "sm4",
  "payloadBase64": "..."
}
```

Successful response:

```json
{"ok":true,"deviceId":"esp32-94A990D24D10","bytes":80,"timestamp":1784340000000}
```

## HTTP command polling

```http
GET /api/http/command?deviceId=esp32-94A990D24D10
```

Empty response:

```json
{"ok":true,"hasCommand":false,"deviceId":"esp32-94A990D24D10"}
```

Command response:

```json
{
  "ok": true,
  "hasCommand": true,
  "deviceId": "esp32-94A990D24D10",
  "commandId": "1784340000000-1",
  "topic": "dayu/cmd/esp32-94A990D24D10",
  "payloadBase64": "...",
  "bytes": 80,
  "timestamp": 1784340000000
}
```

Queues are isolated by `deviceId`, contain at most 20 commands, and discard
expired protocol-switch commands.

## HTTP command enqueue

The Dayu UI normally calls the native gateway directly. The compatibility
endpoint remains available for diagnostics:

```http
POST /api/http/command
Content-Type: application/json
```

```json
{
  "deviceId": "esp32-94A990D24D10",
  "topic": "dayu/cmd/esp32-94A990D24D10",
  "payloadBase64": "..."
}
```

## Acknowledgements

Every business ACK must include its real `deviceId` and echo the command
`seq`. Dayu matches both fields before updating UI state.

## Migration rule

No ESP32 business command, topic, encrypted frame or ACK format changes during
the gateway migration. Only the configured broker and HTTP host move from the
PC address to the Dayu LAN address.

`deploy.bat` installs and launches the application only. It no longer starts
the PC broker. `restart-broker.ps1` remains available as an explicit rollback
tool while existing devices are migrated.
