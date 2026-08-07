禹家本机性能测试说明

1. 使用 USB 连接 DAYU，确认 DevEco Studio 或 hdc list targets 能识别设备。
2. 安装包含性能埋点的最新 DAYU HAP。
3. 在项目根目录运行：

   powershell -ExecutionPolicy Bypass -File .\scripts\performance\Start-Performance-Test.ps1

4. 保持终端运行，在 DAYU 上完成测试操作。建议每项先预热 3 次，再正式测试 20 次：

   照明：交替执行开灯和关灯。
   空调：测试开关机、制冷/制热、温度加减。
   门禁：交替执行解锁和上锁。
   协议与加密：依次测试 HTTPS+AES、HTTPS+SM4、MQTTS+AES、MQTTS+SM4。
   语音：使用固定口令分别执行开关灯和开关空调。
   人脸：在正常光照下执行识别，并补充不同距离、角度和光照测试。

5. 测试完成后在采集终端按 Ctrl+C。脚本会生成以下文件：

   hilog-evidence.log            原始 HILOG 证据
   performance-events.jsonl      结构化原始事件
   performance-trials.csv        每一次测试的分阶段耗时
   performance-summary.csv       各类别平均值、最小值、最大值和 P95
   security-combinations.csv     协议与加密组合切换统计
   session.json                  设备编号、HDC 版本和测试开始时间

注意：device_ack 才表示 ESP32 已返回确认。transport_sent 仅表示 DAYU 已完成发送，不能作为设备执行成功的依据。若出现 device_timeout，应先检查 ESP32 在线状态、设备能力绑定和当前通信方式。
