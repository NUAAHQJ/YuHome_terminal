# Local MQTT Broker

This project includes a lightweight local MQTT broker for ESP32 and Dayu210 debugging.

## Start

Run from the project root:

```powershell
.\start-broker.ps1
```

You can also double-click `启动MQTT-Broker.bat`.

The broker listens on:

```text
mqtt://0.0.0.0:1883
```

Other devices on the same Wi-Fi should connect to this computer's WLAN IP:

```text
<printed LAN address>:1883
```

The campus network may change your computer IP. Each time the broker starts, it prints lines like:

```text
[MQTT] LAN address: WLAN -> mqtt://10.100.38.66:1883
```

Use the `WLAN` address for ESP32 and the Dayu210 app.

The app also has a Broker address input box on the left panel. If the computer IP changes, enter the new address there and tap reconnect. You can input either:

```text
10.100.38.66:1883
```

or:

```text
tcp://10.100.38.66:1883
```

The default value lives in:

```text
entry/src/main/ets/pages/Index.ets
```

## Topics

ESP32 publishes sensor data:

```text
smart_home/esp32/sensor/indoor
```

Compatible topic:

```text
esp32/sensor
```

Payload:

```json
{"temperature":24.6,"humidity":48}
```

Compatible payload fields:

```json
{"temp":24.6,"hum":48}
```

ESP32 publishes light status:

```text
smart_home/esp32/light/status
```

Payload:

```json
{"living":true,"bedroom":false,"pirEnabled":true}
```

Dayu210 publishes light control:

```text
smart_home/esp32/light/set
```

Payload:

```json
{"target":"living","power":true,"timestamp":1710000000000}
```

## UDP relay

Dayu210 sends UDP commands to ESP32 through the HTTP bridge:

```text
Dayu210 -> http://<PC WLAN IP>:3000/api/udp/send -> UDP broadcast <subnet>.255:1350 -> ESP32
```

ESP32 can send a UDP test message back to Dayu210 through the broker:

```text
ESP32 -> UDP <PC WLAN IP>:1351 -> UDP broadcast <subnet>.255:1346 -> Dayu210
```

ESP32 only needs the PC WLAN IP. For example, if the broker prints:

```text
[UDP-in] ESP32 send to 192.168.3.5:1351; broker forwards to Dayu UDP 1346
```

send UDP packets to:

```text
192.168.3.5:1351
```

Dayu210 listens on UDP port `1346`.
