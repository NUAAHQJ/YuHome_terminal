# 禹家终端自然语言理解模块交接说明

## 1. 文档用途

本文档用于将禹家终端自然语言理解（NLU）模块的项目背景、现状和后续任务交接给新的开发对话。开始工作前应先阅读本文档，再检查当前源码和Git状态，不要只根据本文档直接覆盖代码。

本任务只涉及DAYU终端的本地语音意图理解与状态查询，不要修改联邦学习的家庭行为预测模型，也不要把两类模型的数据集、标签或置信度策略混在一起。

## 2. 项目与源码位置

项目总目录：

```text
C:\HUAWEI\YuJia
```

相关工程：

```text
C:\HUAWEI\YuJia\YuHome_terminal   DAYU智能终端
C:\HUAWEI\YuJia\YuHome_app        HarmonyOS手机APP
C:\HUAWEI\YuJia\YuHome_cloud      云平台
C:\HUAWEI\YuJia\YuHome_federated  家庭行为联邦学习工程
```

本次主要修改 `YuHome_terminal`。`YuHome_federated`中的家庭行为数据和MLP模型与语音NLU无关，不得直接复用为Transformer语料。

## 3. 当前语音链路

DAYU端当前语音处理链路为：

```text
麦克风音频
  -> 本地唤醒词检测
  -> 本地流式ASR
  -> 可选声纹验证
  -> VoiceIntentParser意图解析
  -> Index.executeVoiceIntent业务执行
  -> 设备控制或状态查询结果
```

当前唤醒词检测、ASR和声纹特征提取均在DAYU本地完成，不上传原始音频。语音推理基于 `sherpa-onnx`，原生模块已经链接ONNX Runtime。

关键文件：

```text
entry/src/main/ets/voice/VoiceAssistant.ets
entry/src/main/ets/voice/VoiceIntentParser.ets
entry/src/main/ets/voice/VoiceAudioBridge.ets
entry/src/main/ets/voice/SpeakerProfileManager.ets
entry/src/main/ets/pages/Index.ets
entry/src/main/cpp/voice_inference.cpp
entry/src/main/cpp/CMakeLists.txt
entry/src/main/ets/types/libvoice_inference.d.ts
entry/src/main/resources/rawfile/voice/
```

职责说明：

- `VoiceAssistant.ets`：负责唤醒、ASR、声纹校验、意图解析调用和执行状态反馈。
- `VoiceIntentParser.ets`：当前为规则解析器，是后续Transformer的兜底解析器。
- `Index.executeVoiceIntent()`：读取真实设备状态或调用控制函数，不应把业务执行逻辑写进模型推理层。
- `voice_inference.cpp`：本地KWS、ASR和声纹原生推理入口，后续可在这里增加NLU ONNX会话，或建立独立的NLU原生模块。

## 4. 已实现能力

### 4.1 现有控制意图

当前语音执行层已经可靠支持：

- 客厅灯开关；
- 空调电源开关。

门锁属于敏感操作。语音中出现开门、解锁等高风险指令时，当前返回“需要人脸或手动确认”，不得因为接入Transformer而绕过该限制。

窗帘开合度、空调温度和空调模式已有底层控制函数，但尚未完整接入语音意图执行，接入时需要复用现有控制函数、ACK状态和防重复逻辑。

### 4.2 已实现的状态查询意图

`VoiceIntentParser.ets`和`Index.executeVoiceIntent()`已经增加以下状态查询：

```text
light_status_query
curtain_status_query
ac_status_query
door_status_query
temperature_query
humidity_query
environment_query
alarm_status_query
```

已支持的典型表达包括：

```text
客厅灯开着吗
灯是不是关着
窗帘现在开了多少
窗帘开合度是多少
空调开着吗
空调现在多少度
门锁了吗
当前温度是多少
温度和湿度怎么样
有没有烟雾报警
家里是否漏水
```

查询结果必须读取DAYU当前状态：

```text
livingLightOn
curtainPercent
acPower
acTemp
acMode
doorLocked
indoorTemp
indoorHumidity
smokeAlarm
waterAlarm
hasLiveSensorData
```

温湿度没有真实传感器上报时，应返回“暂未收到温湿度传感器数据”，不能使用页面初始化值冒充实时数据。

### 4.3 当前语音反馈限制

当前语音提示采用预录制WAV文件，只覆盖灯和空调的部分固定控制结果。动态状态查询已经能够在界面显示准确文字，但通过 `skipPrompt` 暂停播放不匹配的固定提示音。

Transformer只负责理解意图，不能自动解决动态语音播报。若要求朗读“窗帘当前开合度为62%”等动态结果，需要单独接入本地TTS。不要使用固定的“开灯成功”音频代替状态查询回答。

## 5. Transformer NLU方案

### 5.1 模型定位

本模块不是对话大模型，而是轻量中文Transformer意图分类器。推荐流程：

```text
ASR文本
  -> 文本规范化与Tokenizer
  -> 轻量Transformer意图分类
  -> 置信度与未知意图过滤
  -> 规则提取槽位参数
  -> 业务执行器
```

第一版采用“Transformer分类 + 规则槽位提取”的混合方案。不要一开始同时训练意图分类和序列标注，以免数据量、部署复杂度和错误面同时扩大。

### 5.2 基础模型选择

当前优先候选为：

```text
hfl/rbt3
```

选择原因：

- 中文三层RoBERTa结构，适合短指令分类；
- Apache-2.0许可证明确；
- 可使用PyTorch微调并导出ONNX；
- INT8量化后适合在DAYU本地CPU推理。

备选模型为 `huawei-noah/TinyBERT_4L_zh`。使用备选模型前应重新核对许可证、Tokenizer兼容性和端侧延迟。

不要从随机权重训练Transformer。应加载中文预训练模型，再使用禹家NLU数据进行监督微调。

### 5.3 意图范围

模型标签至少覆盖以下三组。

控制类：

```text
light_set
ac_power_set
curtain_set
ac_temperature_set
ac_mode_set
```

查询类：

```text
light_status_query
curtain_status_query
ac_status_query
door_status_query
temperature_query
humidity_query
environment_query
alarm_status_query
```

安全与兜底类：

```text
requires_confirmation
unknown
```

门锁状态可以查询；开门或解锁仍必须进入 `requires_confirmation`，不能直接执行。

### 5.4 槽位字段

分类完成后由确定性规则提取以下参数：

```text
device          light / curtain / ac / door / environment / alarm
room            living 等实际支持的房间
power           on / off
percentage      0-100
temperature     16-30
mode            cool / heat
query_attribute power / percentage / temperature / mode / lock / alarm
```

模型结果建议统一为：

```json
{
  "intent": "curtain_status_query",
  "confidence": 0.96,
  "device": "curtain",
  "queryAttribute": "percentage",
  "rawText": "窗帘现在开了多少"
}
```

ArkTS不允许无类型对象字面量。新增结构必须先声明明确的接口或类。

## 6. NLU数据集现状与要求

当前尚未生成Transformer NLU数据集。现有联邦学习数据集用于预测家庭行为，不是语言数据。

建议在DAYU工程中建立独立目录：

```text
tools/nlu/
  configs/
  data/
  scripts/
  artifacts/
```

数据集应包含：

- 正常控制表达；
- 状态查询表达；
- 同义改写和口语表达；
- 否定、取消、反问和歧义表达；
- 与智能家居无关的未知语句；
- 门锁等敏感指令；
- ASR常见漏字、错字和近音字；
- 当前设备不支持的房间或设备表达。

真实日志中曾出现类似识别偏差：

```text
客厅灯 -> 客厅都
关掉客厅灯 -> 关掉客厅都
```

不能只通过随机拆分同一批模板形成训练集和测试集，否则指标会虚高。应至少做到：

- 按表达模板族划分训练、验证和测试集；
- 测试集保留训练阶段未见过的说法；
- 单独建立ASR噪声测试集；
- 单独统计未知意图误接收率和敏感操作误执行率；
- 对数字、百分比、温度范围进行边界测试。

## 7. AutoDL训练与模型导出

当前本地电脑没有可用的NVIDIA CUDA环境，建议在AutoDL临时训练，不需要长期租用。

建议环境：

```text
PyTorch 2.x
Python 3.10或3.11
CUDA 12.x兼容镜像
11GB或12GB显存的低价GPU即可
```

初始训练参数建议从以下范围开始，再根据验证集调整：

```text
max_length: 32或48
batch_size: 32或64
epochs: 5-10
learning_rate: 2e-5至5e-5
```

训练完成后必须产出：

```text
PyTorch最佳检查点
标签映射
Tokenizer词表与配置
验证集和测试集指标
混淆矩阵
错误样本清单
FP32 ONNX
INT8 ONNX
模型版本和SHA-256摘要
```

不要只报告总体准确率。至少记录：

```text
macro F1
各意图Precision / Recall / F1
unknown误接收率
requires_confirmation漏检率
槽位提取准确率
端侧推理P50 / P95延迟
端侧内存增量
```

## 8. DAYU端部署注意事项

DAYU设备为ARM64，约8GB内存。禹家应用当前常驻内存约数百MB，轻量INT8模型具备部署条件，但最终结论必须由真机测试得出。

当前 `voice_inference` 已链接：

```text
sherpa-onnx-c-api
onnxruntime
```

但工程中尚未直接引入ONNX Runtime C/C++头文件。新增通用文本分类会话前，需要确认当前`sherpa-onnx`所带ONNX Runtime版本和ABI，并使用匹配的官方头文件，不能随意复制其他版本的头文件。

模型资源建议放在：

```text
entry/src/main/resources/rawfile/voice/nlu/
```

至少包含：

```text
intent_classifier.int8.onnx
vocab.txt
labels.json
model_manifest.json
```

端侧运行原则：

- 模型加载失败时自动退回 `VoiceIntentParser`；
- 模型置信度不足时返回unknown或使用安全规则兜底；
- 敏感指令的安全规则优先级高于模型输出；
- 模型不得直接调用设备控制函数；
- 所有参数必须经过范围校验；
- 不上传原始语音和完整识别文本作为默认行为；
- 模型推理不能阻塞音频采集线程和UI线程。

NLU置信度阈值必须根据独立验证集校准，不要直接照搬联邦行为模型的65%/85%产品门槛。两者含义不同。

## 9. 构建和验证

构建命令：

```powershell
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' `
  'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' `
  --mode module `
  -p product=default `
  -p module=entry@default `
  -p buildMode=debug `
  assembleHap `
  --analyze=normal `
  --parallel `
  --incremental `
  --no-daemon
```

当前签名HAP输出位置：

```text
entry/build/default/outputs/default/entry-default-signed.hap
```

连接设备前先执行：

```powershell
& 'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe' list targets
```

不要硬编码设备UDID。设备可能因重新连接而变化。

当前工程能够成功完成ArkTS编译和HAP打包，但存在一些历史警告，例如废弃API、可能抛出异常和SDK兼容性提醒。这些警告不是本次NLU改动引入的，不应为了做NLU而顺手大范围重构。

## 10. 推荐实施顺序

1. 读取本文档并检查当前Git状态和相关源码。
2. 汇总当前规则解析支持范围，编写回归样例。
3. 固定意图标签、槽位协议和安全边界。
4. 编写并检查NLU数据集生成器。
5. 人工抽查各类别、否定样本、ASR噪声和数据划分。
6. 在AutoDL微调中文轻量Transformer。
7. 在独立测试集评测并分析误分类。
8. 导出FP32和INT8 ONNX并核对输出一致性。
9. 接入DAYU原生推理，保留规则兜底。
10. 真机测试端到端延迟、内存和误触发。
11. 最后再考虑动态TTS，不要将TTS混入意图模型训练。

## 11. 新对话启动要求

新的开发对话应先完成以下动作：

```text
1. 阅读本文件。
2. 检查YuHome_terminal的Git状态，不覆盖已有改动。
3. 阅读VoiceIntentParser、VoiceAssistant、voice_inference和executeVoiceIntent。
4. 用自己的话总结现状、风险和实施顺序。
5. 确认总结与源码一致后，再开始生成NLU数据集。
```

建议对新对话使用以下开场指令：

```text
请先阅读 C:\HUAWEI\YuJia\YuHome_terminal\docs\NLU_IMPLEMENTATION_HANDOFF.md，
然后检查当前DAYU源码和Git状态。先总结现状并核对文档，不要立即改代码。
本任务只做本地Transformer自然语言理解，不要修改联邦学习模块。
确认无误后，再从意图标签、槽位协议和数据集生成开始实施。
```
