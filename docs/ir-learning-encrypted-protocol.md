# 空调红外学习加密通信协议

红外学习复用当前设备控制链路，不使用 USB 串口。大禹使用当前算法、当前动态密钥和当前 MQTT/HTTP 通道发送命令；ESP32 ACK 走相同加密体系返回。

## 通信主题

- 大禹命令：加密后发送到 `dayu/cmd`。
- ESP32 ACK：加密后发送到 `esp32/ac`。
- MQTT 和 HTTP 都复用项目现有的加密命令封装，不发送明文业务 JSON。
- 大禹命令必须带 `seq`。ESP32 ACK 可回显该 `seq`；为兼容当前固件，逐键 ACK 也允许不带 `seq`，此时大禹使用活动学习会话和 `index` 顺序校验。

## 按键索引

| index | 按键 |
| --- | --- |
| 1 | 开机 |
| 2 | 关机 |
| 3 | 温度+ |
| 4 | 温度- |
| 5 | 制冷 |
| 6 | 制热 |

## 学习流程

1. 大禹发送学习模式握手：

```json
{"cmd":"ir","action":"learn-all","seq":1001}
```

2. ESP32 确认已入队：

```json
{"type":"ack","cmd":"ir","action":"learn-all","ok":true,"msg":"learning 1~6, ~6min","seq":1001}
```

`seq` 允许省略。大禹在整个学习过程中不再发送单键 `learn`指令。

3. ESP32 自动进入 index 1 的 65 秒学习窗口。用户按下对应遥控器按键后，ESP32 回复：

```json
{"type":"ack","cmd":"ir","action":"learn","ok":true,"index":1,"keyName":"开机","msg":"learned"}
```

4. ESP32 等待 3 秒后自动进入下一项。大禹只根据逐键 ACK 更新提示和步骤状态。

5. 超时或捕获失败时，ESP32 回复：

```json
{"type":"ack","cmd":"ir","action":"learn","ok":false,"index":1,"keyName":"开机","msg":"timeout"}
```

大禹将该项标红为“已跳过”，ESP32 继续下一项。若 `msg` 为 `enter learn failed`，大禹提示红外模块异常并停止流程。

6. 大禹收齐 index 1~6 的 ACK 后进入测试阶段。编码由红外模块自身 Flash 保存，不需要大禹发送额外保存命令。

## 测试与退出

测试开机或关机：

```json
{"cmd":"ir","action":"send","index":1,"seq":1010}
```

```json
{"type":"ack","cmd":"ir","action":"send","ok":true,"index":1,"keyName":"开机","seq":1010}
```

退出学习模式：

```json
{"cmd":"ir","action":"exit","seq":1011}
```

## ACK 兼容约定

- `learn-all` ACK 必须返回 `action:"learn-all"`。
- 大禹按 `index` 独立记录每项结果，重复 ACK 会被忽略；某一项 ACK 丢失、延迟或解密失败不会阻塞后续 index。
- ACK 带 `seq` 时必须与 `learn-all` 会话一致；不带 `seq` 时按当前学习会话及 `index` 校验。
