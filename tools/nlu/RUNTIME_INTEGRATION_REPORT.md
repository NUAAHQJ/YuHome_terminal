# YuHome DAYU 分层 NLU 运行时集成报告

## 结论

分层 NLU 已接入 DAYU 的 ArkTS/C++ 运行时。隔离影子工程和实际 DAYU 仓库均已通过 ArkTS 编译、CMake 配置、ARM64 Ninja 编译、原生库处理、HAP 打包和签名。联邦学习源码与资源未被修改。

当前状态是“工程集成通过，真机验收待完成”。混合 INT8 是默认候选，FP32 保留为正确性基线和加载回退；全量 INT8 已拒绝，不进入运行时包。

## 执行顺序

运行时必须保持以下顺序：

1. ArkTS 硬安全规则先处理取消/否定、开门/解锁、越域设备和开放域请求。
2. C++ ONNX Runtime 在 NAPI 工作线程执行三分类路由头和十三分类意图头。
3. ArkTS 对模型标签执行确定性槽位提取、范围校验与协议映射。
4. 模型加载或推理失败时使用原规则解析器。

开门/解锁不能由模型授权。非法温度或百分比返回 `unknown`，不能下发设备控制。

## 模型与依赖

| 文件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `hierarchical_nlu.hybrid_int8.onnx` | 109245278 | `aaf93bb9cef2e70b123f6d1584e29616de11163994b48d403f013c83e8bc45af` |
| `hierarchical_nlu.fp32.onnx` | 151668932 | `ad819434ec26b883530f72affacf011695a1f3e822234ddfab235be6f8299441` |
| `vocab.txt` | 109540 | `45bbac6b341c319adc98a532532882e91a9cefc0329aa57bac9ae761c27b291c` |
| `onnxruntime_c_api.h` | 206358 | `7e47eb78563da119f740dc0ddfda96800e779e0bcbd169a9a49e9c10746c4cd5` |

头文件来自 ONNX Runtime v1.17.1 官方仓库：

`https://raw.githubusercontent.com/microsoft/onnxruntime/v1.17.1/include/onnxruntime/core/session/onnxruntime_c_api.h`

`sherpa_onnx 1.13.3` 随包的 `libonnxruntime.so` 动态符号版本为 `VERS_1.16.3`。运行时因此显式调用 `GetApi(16)`；v1.17.1 头文件中本项目使用的函数与 C API 16 保持 ABI 兼容。

## 验证结果

- C++ tokenizer 与 Hugging Face `BertTokenizer` 对冻结数据的 4076 条文本逐 token 对比，差异为 0。
- ArkTS 独立测试执行 4076 条硬规则检查和 2915 条模型标签/槽位契约检查，错误为 0。
- 原生运行时通过主机 C++17 语法检查和 HarmonyOS ARM64 实际编译、链接。
- 签名 HAP 已包含 `libvoice_inference.so`、`libonnxruntime.so`、`libsherpa-onnx-c-api.so`、混合 INT8、FP32 和词表。
- HAP 内两个模型和词表的字节数及 SHA-256 与源文件一致。
- 实际仓库签名产物为 `entry/build/default/outputs/default/entry-default-signed.hap`，本次构建大小 558451866 字节，SHA-256 为 `2ffc9f33e491901eaa0752b9086ca8be2c94be385512a2898bf9ba78bad0a932`。

## 真机验收

正式部署前需要在 DAYU ARM64 上记录并通过以下项目：

1. `GetApi(16)`、FP32 session 和混合 INT8 session 均可初始化。
2. 真实 ASR 文本经过完整安全规则、模型和槽位校验后不出现敏感动作绕过。
3. 分别记录两种模型的首次加载耗时、P50/P95 推理延迟和峰值内存。
4. 模型文件损坏、运行库不兼容或推理异常时，规则回退仍能正常工作。

完成上述真机数据前，部署清单中的设备状态必须保持 `pending`。
