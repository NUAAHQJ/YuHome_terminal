# 禹家 DAYU 智能终端

禹家 DAYU 智能终端运行在 DAYU210 上，是家庭侧的本地控制中心。它统一接入 ESP32 家居节点，汇聚设备状态，承接 APP 和云平台命令，并提供本地界面、语音、人脸、声纹、设备接入和联邦学习端侧能力。

## 主要功能

- 展示家庭环境、设备状态、报警和链路状态
- 控制照明、门禁、空调和窗帘
- 运行本地 MQTT Broker 与 HTTP/HTTPS Bridge
- 在 MQTT 和 HTTP 两种 Wi-Fi 业务模式间进行全屋切换
- 通过 USB BLE 网关扫描、连接、认领和控制多块 ESP32
- 通过 BLE 安全通道无线下发 Wi-Fi 配置
- 执行真实设备移除并清理 ESP32、网关和 DAYU 三侧状态
- 支持 AES-GCM、SM4-GCM 和 P-256 ECDH 动态密钥协商
- 缓存设备周期状态、控制 ACK 和安全报警
- 提供唤醒词、ASR、NLU、动作规划、TTS 和声纹验证
- 通过人脸识别和本地安全策略执行门禁控制
- 采集家庭行为数据并运行联邦模型端侧推理
- 与云平台同步控制队列、状态、场景和报警

## 项目结构

```text
AppScope/                           应用级配置和资源
entry/src/main/ets/pages/            总览、设置、设备接入和主要业务界面
entry/src/main/ets/bridge/           HTTP/HTTPS Bridge 客户端
entry/src/main/ets/cloud/            云平台安全通信
entry/src/main/ets/crypto/           AES/SM4、设备动态密钥和密文处理
entry/src/main/ets/gateway/          本地网关接口
entry/src/main/ets/mqtt/             MQTT/MQTTS 客户端和证书身份
entry/src/main/ets/provisioning/     USB 帧、BLE 网关和兼容串口配网
entry/src/main/ets/voice/            语音助手、录音、声纹和意图解析
entry/src/main/ets/planner/          动作规划与安全门
entry/src/main/ets/face/             人脸识别和门禁管理
entry/src/main/ets/federated/        家庭行为模型和样本上报
entry/src/main/cpp/                   MQTT/HTTP 本地网关、语音和人脸原生实现
entry/src/main/resources/rawfile/     ASR、KWS、NLU、人脸及联邦模型资源
broker.js                             本地 MQTT Broker
tools/                                NLU、规划器、TTS 和音频服务工具
docs/                                 协议、算法和部署说明
```

## 开发环境

- DevEco Studio 与 OpenHarmony SDK
- ArkTS、C 和 C++
- CMake/Hvigor 原生构建工具链
- Node.js 与 npm，用于运行本地 MQTT Broker
- DAYU210 开发板
- 摄像头、麦克风、扬声器和 USB BLE 网关
- 两块家居 ESP32-S3 节点用于完整设备联调

## 构建运行

1. 在本目录执行 `npm install`，安装本地 Broker 依赖。
2. 原生依赖未准备时，按当前开发环境执行 `prepare-native-deps.ps1`。
3. 使用 DevEco Studio 打开本目录并配置 OpenHarmony SDK 与本地调试签名。
4. 选择 `entry` 模块，构建并安装到 DAYU210。
5. 使用 `npm run broker` 或 `start-broker.ps1` 启动本地 MQTT Broker。
6. 连接 BLE 网关、摄像头和音频设备，并在终端设置页检查权限与链路状态。
7. 根据部署环境配置云端地址、Broker/Bridge URL 和证书，再开始 ESP32 联调。

证书私钥、签名密码、Wi-Fi 密码和生产地址只应保存在部署环境中。不要把本机绝对路径或真实凭据写入 README。

## 通信关系

DAYU 是所有本地控制入口的汇合点：

```text
APP/云平台 -----------+
DAYU 本地界面 --------+-> 统一设备命令路由 -> BLE/MQTT/HTTP -> ESP32
语音助手/人脸识别 ----+
```

Wi-Fi 模式下，ESP32 通过 MQTT/MQTTS 或 HTTP/HTTPS 接入本地服务；设备业务模式只有 `mqtt` 和 `http`，TLS 是否启用由 URL scheme 决定。BLE 模式下，DAYU 通过 USB 帧控制 `esp32-ble-gateway`，再由网关通过 GATT 连接家居节点。

正常业务主路径使用每设备独立的 P-256 ECDH/HKDF 动态密钥和 AES-GCM 或 SM4-GCM。BLE 会话复用对应 Wi-Fi 身份的 P-256 密钥对，但通过独立 HKDF 域派生 BLE 业务密钥。空调和窗帘等状态由 ESP32 周期回传，语音查询读取 DAYU 最近一次有效状态缓存。

## 说明

当前 BLE 全屋业务模型以传感器/照明/门禁板和空调/窗帘/报警板两块节点为必需目标。BLE 网关底层可以保存 8 台设备并同时维持最多 4 条连接，但增加新设备仍需补充 DAYU 设备注册、能力映射、状态路由和交互入口。

旧 UART0/USB 串口配网仍用于兼容、调试和现场恢复，当前正常无线接入优先使用 BLE 扫描、动态密钥协商和加密配网。移除设备时必须先取得 ESP32 清除配网 NVS 的确认，再执行网关 `forget` 和 DAYU 本地状态清理。
