# ESP32-S3 网关 USB 联通测试

## 目的

第一阶段只验证大禹与 ESP32-S3 网关之间的 USB 物理链路和二进制收发，不接入 BLE 扫描、连接或设备控制。

测试流程如下：

```text
ESP32-S3 网关上电
    -> USB Type-C 数据线连接大禹
    -> 大禹枚举并显示 USB 设备
    -> 调试信息窗口底部点击“连接”
    -> 点击“发送测试帧”
    -> ESP32-S3 校验并返回 ACK
    -> 大禹显示测试成功和往返耗时
```

本阶段直接复用大禹已有的串口配网 USB 通道。USB 同时负责供电和数据传输，不需要额外的杜邦线、UART 转换器或蓝牙模块。

## USB 设备要求

ESP32-S3 固件应以 USB Device 方式工作，并暴露大禹当前配网已经使用的 USB CDC-ACM 或 USB Bulk IN/OUT 接口。

要求：

- 使用与现有配网相同的 USB Type-C 数据口和 USB 接口。
- 数据通道支持 115200/8N1 语义；如果使用原生 USB Bulk，波特率只作为兼容配置，不影响 Bulk 帧格式。
- Bulk OUT 用于接收大禹请求。
- Bulk IN 用于返回网关 ACK。
- 不要在同一个二进制数据通道直接输出未封装的日志文本。
- 如果必须保留日志，请输出到另一条日志通道，或在固件中增加明确的日志开关。

## 二进制帧格式

所有字段按下面顺序发送，整数为单字节，长度为大端序：

```text
AA 55 | version | type | seq | payload_len_hi | payload_len_lo | payload | crc_lo | crc_hi
```

字段说明：

| 字段 | 长度 | 说明 |
| --- | ---: | --- |
| Header | 2 B | 固定为 `0xAA 0x55` |
| version | 1 B | 当前为 `0x01` |
| type | 1 B | 当前测试请求为 `0x60`，ACK 为 `0x61` |
| seq | 1 B | 大禹生成的序号，ACK 必须原样返回 |
| payload_len | 2 B | Payload 长度，大端序 |
| payload | N B | UTF-8 JSON；无 payload 时 N 为 0 |
| CRC | 2 B | CRC16-MODBUS，低字节在前 |

CRC 计算范围为：

```text
version + type + seq + payload_len_hi + payload_len_lo + payload
```

不包含开头的 `AA 55`，不包含最后两个 CRC 字节。初始值为 `0xFFFF`，多项式为 `0xA001`。

## 测试请求

大禹发送：

- `type = 0x60`
- `seq =` 大禹本次生成的序号
- payload：

```json
{
  "type": "gateway_test",
  "message": "dayu-usb-test",
  "timestamp": 0
}
```

其中 `timestamp` 是大禹发送时的毫秒时间戳，实际值不是固定的 `0`。

ESP32-S3 收到 `0x60` 后应完成以下检查：

1. 按 USB read 分片安全地拼接数据，不能假设一次 read 就是一个完整帧。
2. 找到 `AA 55`，读取完整帧头和 payload 长度。
3. 等待完整 payload 和 CRC 到达。
4. 校验 CRC16-MODBUS。
5. 解析 JSON，并确认 `type` 为 `gateway_test`、`message` 为 `dayu-usb-test`。
6. 立即返回 `0x61` ACK。

## ACK 格式

ESP32-S3 返回：

- `type = 0x61`
- `seq =` 与请求完全相同
- payload：

```json
{
  "type": "gateway_test_ack",
  "ok": true,
  "message": "esp32-s3-gateway-ready",
  "seq": 1
}
```

ACK 外层的 `seq` 必须与请求一致，JSON 内的 `seq` 也建议填写同一个值，便于日志定位。成功时 `ok` 必须为 `true`。

如果请求 CRC、JSON 或类型不正确，可以返回同样的 `0x61`，但将 `ok` 设为 `false`，例如：

```json
{
  "type": "gateway_test_ack",
  "ok": false,
  "message": "bad_crc",
  "seq": 1
}
```

## 固件实现注意事项

### 接收缓冲

USB 数据可能出现以下情况，固件都必须支持：

- 一个帧被拆成多次 read；
- 一次 read 包含多个帧；
- 帧前面有残留字节；
- ACK 发送后大禹立即再次发送测试帧。

建议使用循环缓冲区，按照 Header、长度和 CRC 逐帧取出，不要使用固定 read 长度直接强转结构体。

### 日志隔离

类似下面的文本不能混在 Bulk IN 的协议流中：

```text
ESP32_S3_GATEWAY_READY\r\n
gateway received test\r\n
```

如果这些文本进入同一通道，大禹会先丢弃非 `AA 55` 字节，但连续日志仍可能造成时序和调试误判。建议本阶段关闭协议通道日志，或者使用 ESP-IDF 日志输出到独立的 UART/JTAG/USB Serial-JTAG 通道。

### 本阶段不做的内容

- 不实现 BLE 广播扫描；
- 不实现 BLE Central 连接；
- 不实现 BLE 外设控制协议；
- 不使用 AES-GCM、SM4-GCM 或 ECDH；
- 不修改现有 Wi-Fi、MQTT、HTTP 配网和设备控制协议。

这是物理 USB 链路验证阶段，待 ACK 稳定后再在同一网关固件上增加 BLE 层。BLE 数据进入网关后，后续仍可以复用项目现有的 AES-GCM/SM4-GCM 业务加密策略，但不应在本次 USB 测试中混入。

## 联调判定标准

满足以下条件即认为第一阶段通过：

1. 大禹调试窗口能枚举出 ESP32-S3 网关；
2. 大禹能成功连接 USB 设备；
3. ESP32-S3 能收到完整 `0x60` 帧并通过 CRC；
4. ESP32-S3 返回完整 `0x61` 帧；
5. 大禹显示匹配序号的 `ok=true` ACK；
6. 连续点击发送测试帧 10 次，10 次均能在 3 秒内收到对应 ACK；
7. 测试过程中没有出现乱码、半帧、CRC 错误或 ACK 串序。

