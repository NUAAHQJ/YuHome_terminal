# BLE 网关自动重连联调说明

## 目标

蓝牙网关第一次接入时允许用户手动扫描和连接。扫描完成并读取到家居设备的 `device_hello` 后，网关负责保存设备地址和设备身份。以后大禹启动、USB 网关重新连接或蓝牙连接断开时，优先自动恢复已知设备，不要求用户再次进入扫描界面。

调试界面只用于以下情况：首次接入新设备、自动恢复失败、替换网关或重新排查蓝牙链路。

## 大禹端行为

大禹首次在调试界面手动连接蓝牙网关后，会持久化当前 USB 网关的设备标识。应用再次启动时，大禹会等待 USB 枚举，匹配已保存的网关后自动打开 USB 通道，并发送：

```json
{
  "type": "gateway_ble_command",
  "cmd": "ble",
  "action": "connect-known",
  "seq": 9
}
```

大禹不会因为应用启动而自动扫描附近所有蓝牙设备，也不会自动连接新的、未确认过的 USB 设备。新网关或首次接入仍需用户在调试界面完成一次手动连接和扫描。

## 网关端要求

### 1. 保存已知设备

首次扫描并成功读取 `device_hello` 后，将以下信息写入 NVS：

- BLE address
- `deviceId`
- `name`
- `capabilities`

同一地址重复扫描时更新记录，不新增重复设备。设备列表不能因为某一轮扫描没有发现设备而清空。

### 2. 处理 `connect-known`

收到 `cmd=ble`、`action=connect-known` 后：

1. 不启动全量扫描。
2. 按 NVS 中保存的地址逐个连接已知家居设备。
3. 连接成功后重新读取 `device_hello`。
4. 通过 USB `0x63` 上报 `device_hello` 和 `ble_device_state`。
5. 所有已知设备处理完成后返回结果事件。

建议按顺序连接，避免两片家居板同时抢占 ESP32-S3 的 2.4 GHz 射频。单台连接失败不能影响其他设备继续恢复。

### 3. 推荐结果事件

连接成功后至少发送：

```json
{
  "type": "device_hello",
  "seq": 9,
  "deviceId": "esp32-744DBD8A253C",
  "address": "AA:BB:CC:DD:EE:FF",
  "name": "Sensor Controller",
  "capabilities": ["sensor", "light", "alarm"],
  "connected": true,
  "transport": "ble"
}
```

```json
{
  "type": "ble_device_state",
  "seq": 9,
  "deviceId": "esp32-744DBD8A253C",
  "address": "AA:BB:CC:DD:EE:FF",
  "connected": true
}
```

全部设备处理完成后发送：

```json
{
  "type": "ble_reconnect_finished",
  "seq": 9,
  "ok": true,
  "count": 2
}
```

如果没有已知设备：

```json
{
  "type": "ble_reconnect_finished",
  "seq": 9,
  "ok": true,
  "count": 0,
  "reason": "no_known_devices"
}
```

如果某台设备连接失败，建议单独上报：

```json
{
  "type": "ble_device_state",
  "seq": 9,
  "deviceId": "esp32-94A990D24D10",
  "address": "11:22:33:44:55:66",
  "connected": false,
  "message": "connect_failed"
}
```

然后继续处理下一台设备，最后将 `ok` 设为 `false` 并在 `reason` 中说明失败原因。

## 什么时候允许扫描

以下情况才需要重新扫描：

- NVS 中没有任何已知设备。
- 用户在大禹调试界面点击“开始扫描”。
- 用户添加或更换家居设备。
- 已知地址连续多次重连失败。

由于 Wi-Fi 和 BLE 共用射频，一次扫描可能只发现一台家居板。网关应跨扫描保留已知列表，大禹也按 `address` 和 `deviceId` 去重合并，不能用本轮扫描结果覆盖旧列表。

## 联调验收

1. 首次扫描完成后，两台家居设备均显示真实 `deviceId` 和能力列表。
2. 退出并重新打开大禹，USB 网关自动连接。
3. 大禹自动发送 `connect-known`，不需要点击扫描。
4. 网关重新上报两台设备的 `device_hello` 和连接状态。
5. 临时关闭一台家居板，另一台仍能自动恢复。
6. 重新打开故障设备或再次扫描后，设备列表不会重复或消失。

