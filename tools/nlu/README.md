# YuHome DAYU 分层 NLU 数据与训练工具

本目录只服务于 DAYU 端本地语音意图识别，不读取、生成或修改联邦学习数据、模型与训练流程。

## 最终架构

最终交付为 `rbt3_yuhome_hierarchical_v4`，底座模型是开源中文预训练模型 `hfl/rbt3`。完整推理顺序必须保持为：

1. 硬安全规则：拦截取消/否定、开门/解锁等敏感动作，限定受支持的智能家居域。
2. 三分类路由头：`in_domain`、`requires_confirmation`、`unknown`。
3. 十三分类意图头：只对域内请求分类。
4. 确定性槽位提取与范围复核。
5. 模型加载或推理失败时回退现有规则解析器。

ONNX 文件不能脱离硬安全规则单独用于授权或执行。DAYU 运行时已经将模型协议的 `ac_power_set` 显式映射为 ArkTS 的 `ac_set`。

## 数据集

最终训练数据位于 `data/hierarchical_v1/`，模型包中另有逐字节一致的快照 `dist/rbt3_yuhome_hierarchical_v4/training_data/`。

| 划分 | 数量 |
| --- | ---: |
| train | 2856 |
| validation | 386 |
| test | 412 |
| asr_noise_test | 298 |
| boundary_test | 24 |
| safety_adversarial_test | 100 |

数据按表达模板族隔离划分，防止同族句式跨训练/验证/测试泄漏；覆盖正常控制、状态查询、ASR 噪声、取消命令、敏感动作、开放域负例和槽位边界。

重新生成并校验：

```powershell
python scripts/generate_hierarchical_dataset.py
python scripts/validate_hierarchical_dataset.py --data-dir data/hierarchical_v1
python -m unittest discover -s tests -v
```

## GPU 训练

训练脚本默认要求 CUDA；CUDA 不可用时直接报错，不会静默回退到 CPU。只有显式传入 `--device cpu` 才允许 CPU 训练。

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python scripts/train_hierarchical_classifier.py \
  --device cuda \
  --config configs/hierarchical_train_config.json \
  --labels configs/hierarchical_labels.json \
  --data-dir data/hierarchical_v1
```

最终模型使用 seed `20260802` 在 NVIDIA GeForce RTX 4090 上训练，最佳检查点为第 7 轮。阈值为：确认路由 `0.15`、域内路由 `0.50`、意图置信度 `0.15`。

## 最终产物

- `dist/rbt3_yuhome_hierarchical_v4/best_checkpoint/`：Transformers 编码器、双分类头和 tokenizer。
- `dist/rbt3_yuhome_hierarchical_v4/onnx/hierarchical_nlu.fp32.onnx`：FP32 精度基线。
- `dist/rbt3_yuhome_hierarchical_v4/onnx/hierarchical_nlu.hybrid_int8.onnx`：保留 embedding 和 encoder 第 0 层为 FP32、量化第 1/2 层的真机候选。
- `dist/rbt3_yuhome_hierarchical_v4/deployment_manifest.json`：架构、文件哈希、指标和设备验证状态。
- `dist/rbt3_yuhome_hierarchical_v4/final_acceptance.json`：同时包含安全与质量门槛的最终验收结论。
- `dist/rbt3_yuhome_hierarchical_v4/onnx/final_safety_gate_evaluation.json`：最终规则补丁后的 100 条安全对抗验证。

全量 INT8 实验的 test/ASR macro-F1 分别只有 `76.74%`/`69.62%`，已拒收；模型二进制未纳入本地交付包。旧版 `rbt3_yuhome_nlu_v2` 因 unknown 误接收和确认漏判过高已标记为被替代，不得部署。

## DAYU 运行时接入

DAYU 端已经完成 ArkTS/C++ 运行时接入，且没有修改联邦学习模块：

1. NAPI 工作线程异步加载模型并执行分类，不占用 UI/音频线程。
2. 默认先加载混合 INT8，失败时加载 FP32；两者都失败或推理失败时回退现有规则解析器。
3. 推理顺序固定为“硬安全规则 → 三分类路由头 → 十三分类意图头 → 确定性槽位提取与范围校验 → 规则回退”。开门/解锁不能由模型授权。
4. 执行层已接通窗帘百分比、空调温度和空调模式，并显式完成 `ac_power_set` 到 `ac_set` 的协议映射。
5. 工程使用 ONNX Runtime v1.17.1 官方 C API 头文件；随 `sherpa_onnx 1.13.3` 打包的运行库为 1.16.3，因此显式请求兼容的 C API 16。

隔离影子工程和实际 DAYU 仓库均已通过 ArkTS、CMake、Ninja、HAP 打包和签名。签名 HAP 已确认包含 `libvoice_inference.so`、`libonnxruntime.so`、两个模型和词表，包内模型/词表哈希与源文件一致。详细记录见 `RUNTIME_INTEGRATION_REPORT.md`。

正式部署前仍需在 DAYU ARM64 真机验证首次加载、混合 INT8 算子兼容性、P50/P95 延迟和峰值内存；完成前部署状态保持 `pending`。
