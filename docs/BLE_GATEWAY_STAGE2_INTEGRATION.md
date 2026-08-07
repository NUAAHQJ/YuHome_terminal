# 禹家蓝牙网关第二阶段联调说明

## 1. 本阶段目标

本阶段只打通以下链路：

```text
大禹
  -> USB Type-C
ESP32-S3 蓝牙网关
  -> BLE 扫描并连接
两片家居 ESP32-S3
  -> 返回 device_hello
ESP32-S3 蓝牙网关
  -> USB 上报
大禹显示设备、连接状态和能力
```

本阶段不通过 BLE 控制灯、空调、窗帘、门锁或报警器，也不改变现有 MQTT、HTTP、AES-GCM、SM4-GCM 和 ECDH 逻辑。设备发现稳定后，再进入 BLE 加密业务转发阶段。

## 2. 三类设备的职责

### 2.1 大禹

- 不调用 OpenHarmony 系统蓝牙接口。
- 继续使用已经打通的 USB CDC Serial 通道连接蓝牙网关。
- 向网关发送扫描开始和扫描停止命令。
- 接收网关上报的扫描、设备发现、连接和 `device_hello` 事件。
- 在调试信息窗口显示发现的设备、`deviceId`、RSSI、连接状态和能力。
- 本阶段使用独立蓝牙设备列表，不写入原 MQTT/HTTP 设备注册表。

### 2.2 ESP32-S3 蓝牙网关

- 角色为 BLE Central。
- 通过 USB CDC Serial 与大禹通信。
- 扫描禹家 BLE Service，发现设备后自动连接。
- 连接后读取设备的 `device_hello` 特征值。
- 将 BLE 状态和 `device_hello` 封装成 USB `0x63` 事件上报大禹。
- 至少支持同时维护两台家居设备；建议预留 8 台设备表容量。

### 2.3 两片家居 ESP32-S3

- 角色为 BLE Peripheral。
- 广播禹家 BLE Service UUID。
- 提供可读取的 `device_hello` 特征值。
- 每片设备使用基于 Base MAC 的唯一 `deviceId`，不能使用公共值 `esp32`。
- 现有 Wi-Fi、MQTT、HTTP 和执行器逻辑暂时保持不变。

## 3. USB 外层帧

继续复用现有 USB 二进制帧：

```text
AA 55 | version | type | seq | payload_len_hi | payload_len_lo | payload | crc_lo | crc_hi
```

- `version`：`0x01`
- `payload_len`：大端序
- `payload`：UTF-8 JSON
- `CRC`：CRC16-MODBUS，初值 `0xFFFF`，多项式 `0xA001`，低字节在前
- CRC 范围：从 `version` 到 `payload`，不包含 `AA 55` 和 CRC 本身
- 最大 payload：2048 字节

新增类型：

| type | 名称 | 方向 |
| --- | --- | --- |
| `0x62` | `GATEWAY_BLE_COMMAND` | 大禹 -> 网关 |
| `0x63` | `GATEWAY_BLE_EVENT` | 网关 -> 大禹 |

USB 二进制通道中不得混入普通日志文本。网关调试日志继续走独立 JTAG 日志通道。

## 4. 大禹发送的命令

### 4.1 开始扫描

外层 `type=0x62`，外层 `seq` 与 JSON `seq` 相同：

```json
{
  "type": "gateway_ble_command",
  "cmd": "ble",
  "action": "scan-start",
  "seq": 3,
  "durationMs": 25000,
  "maxDevices": 8,
  "autoConnect": true
}
```

网关收到后立即开始扫描，并返回 `ble_scan_started`。同一轮扫描产生的后续事件都使用这次 `scan-start` 的原始 `seq`。大禹不会在新一轮扫描开始时清空已经通过 `device_hello` 验证的设备，只会重置本轮广播统计。

网关必须先按禹家 Service UUID 过滤扫描结果，不能把附近所有 BLE 广播设备都作为禹家设备上报。`ble_device` 只用于报告匹配禹家 Service 的设备；未匹配的手机、耳机、手环等设备必须直接丢弃。

### 4.2 停止扫描

```json
{
  "type": "gateway_ble_command",
  "cmd": "ble",
  "action": "scan-stop",
  "seq": 4,
  "scanSeq": 3
}
```

`seq` 是停止命令序号，`scanSeq` 是要停止的扫描序号。停止后，网关返回 `ble_scan_finished`，其 `seq` 仍使用原始 `scanSeq`。

## 5. 网关上报事件

所有事件使用外层 `type=0x63`。外层 `seq` 和 JSON `seq` 必须一致。

### 5.1 扫描开始

```json
{
  "type": "ble_scan_started",
  "seq": 3,
  "ok": true
}
```

### 5.2 发现广播设备

```json
{
  "type": "ble_device",
  "seq": 3,
  "deviceId": "AA:BB:CC:DD:EE:FF",
  "name": "YJ-SENSOR-253C",
  "address": "AA:BB:CC:DD:EE:FF",
  "rssi": -55,
  "connected": false,
  "capabilities": []
}
```

扫描阶段还不知道真实 `deviceId` 时，可暂时用 BLE 地址作为 `deviceId`。后续 `device_hello` 必须同时带同一个 `address`，大禹会按地址合并并替换为真实 `deviceId`。大禹界面不会把只有临时地址、尚未读取到 `device_hello` 的广播设备显示为正式家居设备。

### 5.3 连接状态

```json
{
  "type": "ble_device_state",
  "seq": 3,
  "deviceId": "esp32-744DBD8A253C",
  "address": "AA:BB:CC:DD:EE:FF",
  "connected": true
}
```

### 5.4 读取设备能力

传感器、照明板示例：

```json
{
  "type": "device_hello",
  "seq": 3,
  "deviceId": "esp32-744DBD8A253C",
  "name": "Sensor Controller",
  "room": "",
  "address": "AA:BB:CC:DD:EE:FF",
  "rssi": -55,
  "capabilities": ["sensor", "light", "alarm"],
  "connected": true,
  "transport": "ble",
  "crypto": "sm4",
  "epoch": 0
}
```

空调综合板示例：

```json
{
  "type": "device_hello",
  "seq": 3,
  "deviceId": "esp32-94A990D24D10",
  "name": "AC Controller",
  "room": "",
  "address": "11:22:33:44:55:66",
  "rssi": -61,
  "capabilities": ["ac", "ir_learning", "curtain", "door", "alarm"],
  "connected": true,
  "transport": "ble",
  "crypto": "sm4",
  "epoch": 0
}
```

`address`、`rssi`、`connected` 和 `seq` 可以由网关注入后再转发，不要求家居设备自己维护这些字段。

### 5.5 扫描结束

```json
{
  "type": "ble_scan_finished",
  "seq": 3,
  "ok": true,
  "count": 2,
  "reason": "completed"
}
```

### 5.6 错误

```json
{
  "type": "ble_error",
  "seq": 3,
  "ok": false,
  "message": "scan_failed"
}
```

错误消息建议使用稳定的英文枚举，例如 `scan_failed`、`connect_failed`、`service_not_found`、`hello_read_failed` 和 `busy`。

## 6. 建议的 BLE GATT 定义

三块 ESP32 固件统一使用以下 UUID：

| 用途 | UUID | 属性 |
| --- | --- | --- |
| 禹家服务 | `7A6A0001-6B2D-4F01-9C6A-7E8B1A2C0001` | Primary Service |
| 设备信息 | `7A6A0002-6B2D-4F01-9C6A-7E8B1A2C0001` | Read、Notify |
| 业务命令 | `7A6A0003-6B2D-4F01-9C6A-7E8B1A2C0001` | Write、Write Without Response |
| 设备事件 | `7A6A0004-6B2D-4F01-9C6A-7E8B1A2C0001` | Notify |

第二阶段只要求实现服务和“设备信息”特征。业务命令和设备事件特征可以先注册为空实现，为下一阶段保留协议位置。

建议连接后协商 MTU 247。`device_hello` 特征值必须是完整 UTF-8 JSON，最大不超过 512 字节。

## 7. ESP32 网关实现要求

1. 在现有 USB 帧解析器中接受 `0x62`，不能破坏已通过的 `0x60/0x61` 测试。
2. 解析 `cmd=ble` 和 `action`，未知命令返回 `ble_error`。
3. 收到 `scan-start` 后立即上报 `ble_scan_started`。
4. 按禹家 Service UUID 过滤扫描结果，每个 BLE 地址只上报一次 `ble_device`；RSSI 更新可限频。
5. `autoConnect=true` 时自动连接发现的设备，至少支持两台设备。
6. 连接后发现 GATT 服务并读取“设备信息”特征。
7. 验证 `device_hello` JSON 至少包含 `type`、唯一 `deviceId` 和 `capabilities`。
8. 网关补充 `seq`、`address`、`rssi`、`connected=true`、`transport=ble` 后，通过 `0x63` 上报。
9. 扫描窗口结束且连接/读取任务处理完毕后，上报一次 `ble_scan_finished`。
10. 扫描、连接、USB 收发不得长期阻塞同一个任务；建议使用队列分离 USB 解析和 BLE 工作任务。
11. 网关跨扫描保留已知设备，并在新扫描开始时重新上报它们的 `ble_device`、`device_hello` 和 `ble_device_state`；大禹按 `address` 和 `deviceId` 合并更新。

## 8. 两片家居 ESP32 实现要求

### 8.1 传感器、照明板

- 广播名建议：`YJ-SENSOR-253C`，末尾可取 MAC 后四位。
- `deviceId`：继续使用 `esp32-744DBD8A253C` 这一类 Base MAC 格式。
- `capabilities`：按实际硬件声明 `sensor`、`light`、`alarm`。
- “设备信息”特征读取时返回完整 `device_hello` JSON。

### 8.2 空调综合板

- 广播名建议：`YJ-AC-D24D10`。
- `deviceId`：继续使用 `esp32-94A990D24D10` 这一类 Base MAC 格式。
- 若窗帘、门禁和报警硬件确实接在该板上，能力应声明为 `ac`、`ir_learning`、`curtain`、`door`、`alarm`。
- “设备信息”特征读取时返回完整 `device_hello` JSON。

两片设备不得使用相同 BLE 地址、广播名或 `deviceId`。BLE 上线不要求重新串口配网，也不得覆盖现有 Wi-Fi 配置。

## 9. 联调步骤

1. 只连接大禹和蓝牙网关，先连续执行 10 次 `0x60/0x61` USB 测试，确认全部成功。
2. 给两片家居 ESP32 上电，确认它们开始广播禹家 Service UUID。
3. 大禹打开设置页，三连“调试信息”，在底部连接 USB 网关。
4. 点击“开始扫描”。
5. 网关日志应依次出现扫描开始、发现设备、连接、读取 `device_hello`。
6. 大禹应显示两台设备，且设备编号不相同。
7. 两台设备状态应由“已发现”变为“已连接”。
8. 大禹应分别显示两台设备声明的能力，不能把两片设备的能力合并到同一 `deviceId`。
9. 连续执行 10 轮扫描，不能出现设备重复增长、USB CRC 错误或界面卡死；某一轮没有重新发现设备时，已验证的设备记录不能消失。

## 10. 第二阶段通过标准

- 大禹能稳定发出 `0x62 scan-start`。
- 网关能返回 `0x63 ble_scan_started`。
- 两片家居设备均能被发现并连接。
- 两条 `device_hello` 均能到达大禹，且 `deviceId`、地址和能力对应正确。
- 扫描结束后大禹解除“扫描中”状态。
- 重复扫描不会产生重复设备项。
- 原 MQTT/HTTP 控制、串口配网和 `0x60/0x61` USB 测试不受影响。

完成以上标准后，再设计 BLE 业务帧、逐设备 ECDH 会话、AES-GCM/SM4-GCM 加解密和能力路由。
