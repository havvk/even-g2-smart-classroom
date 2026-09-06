# Even G2 麦克风音频采集与双路语音源跟随提词实施计划
> **版本**：v1.0 (2026-09-06)  
> **状态**：待执行 (Ready for Implementation)  
> **适用范围**：`mobile_gateway_ios` (SmartGlassGateway) / `Even G2 MicroLED Firmware` / `Speech.framework`

本实施计划旨在为 SmartGlassGateway (iOS) 网关引入 **Even G2 智能眼镜镜腿近场麦克风音频采集与双路语音源（手机内置麦克风 vs 眼镜麦克风）自由切换架构**，解决教师离开讲台在教室内漫游巡视时手机麦克风拾音距离衰减的问题。

---

## 1. 核心架构决策与物理约束 (Key Architecture Decisions)

#### 1.0 蓝牙独立音频通道 (6401/6402) 修复与绑定
- **根本原因排查**：
  1. G2 协议中，Service `0x6450` 负责流媒体与音频控制，其中 `6401` 为音频写特征（Write Without Response），`6402` 为 205B 音频包接收特征（Notify）。
  2. 此前代码在特征发现时未保存 `6401`（`renderingTxChar`/`audioTxChar`），导致 `sendRawData` 将音频激活命令错误分发至 `5401`（文本通道）。
  3. `buildAudioControlPacket` 中命令字曾标为 15 (`0x0F`)，与协议逆向基准 `Cmd = 18` (`0x12`) 不一致。
- **实施修复**：
  1. 在 `G2Channel` 中增加 `.audio` 通道，在 `sendRawData` 中精准路由至 `6401` 写特征。
  2. 在 `startGlassesMicrophone` 中，采用**双通道多重保障策略**：向 `6401` 与 `5401` 协同下发 `Cmd = 18` 及 `[0x0E, 0x01]` 透传帧，并兼容补发 `Cmd = 15`。
  3. 并在特征发现与状态监控中确保 `6402` 的 Notify CCCD 处于激活状态。

### 1.1 左右镜腿双外设物理拓扑与连接策略
- **硬件现状**：Even G2 智能眼镜左右两耳在蓝牙物理层为两个独立的外设（广播名包含 `_L_` 与 `_R_`），二者之间无内部物理总线通信。
- **麦克风通道归属**：官方实测与开源逆向表明，**左镜腿 (`_L_`)** 是麦克风硬件音频流推送的主力通道（`6402` Notify）；右镜腿 (`_R_`) 主导 MicroLED 光学引擎显示与 Touchpad 触控板滑动通知。
- **连接策略**：
  - **阶段 1**：优先在当前已连接外设上先下发 `Cmd=18` 麦克风开启指令，验证当前连接外设的 `6402` 是否直接回传音频包；
  - **阶段 2**：若当前单外设无音频回传，在 `BLEManager` 中扩展“伴生音频外设连接”逻辑，自动扫描并附带连接同序列号的 `_L_` 镜腿专职接收音频流。

### 1.2 LC3 解码库工程集成方案
- 选用 Google 开源官方参考实现 **`liblc3`**（纯 C 语言编写，零外部依赖，极小体积，无任何 CocoaPods/SPM 第三方包管理负担）。
- 直接作为 C 源码引入 Xcode 工程，通过 Bridging Header 暴露给 Swift，零运行时开销、零网络请求，保证端侧 < 5ms 超低解码延迟。

---

## 2. 实施改动明细 (Detailed Implementation Plan)

### 2.1 协议编码层 (Protocol Encoder)

#### 修改文件：`mobile_gateway_ios/SmartGlassGateway/Services/G2ProtocolEncoder.swift`
- **新增麦克风控制帧编码器**：
  - 实现 `buildAudioControlPacket(enable: Bool, seq: inout UInt8, msgId: inout Int) -> Data`：构造 EvenHub `sid = 0xe0` 的 `Cmd = 18` (`APP_REQUEST_AUDIO_CTR_PACKET`) 报文，携带 `AudioCtrCommand { AudoFuncEn: 1/0 }`；
  - 补充兼容型透传指令 `buildRawMicControlPacket(enable: Bool) -> Data`（`[0x0E, 0x01]` 开启 / `[0x0E, 0x00]` 关闭）。

---

### 2.2 蓝牙管理与音频流接收层 (BLE Manager)

#### 修改文件：`mobile_gateway_ios/SmartGlassGateway/Services/BLEManager.swift`
- **解除 `6402` 拦截并转接专用音频队列**：
  - 在 `peripheral(_:didUpdateValueFor:)` 中，针对 `uuidSuffix == "6402"` 的 205 字节原始音频包，**解除静默丢弃**；
  - 音频包不经过 `processReceivedG2Data`（因为无 `0xAA` 协议头），直接分发至专用的后台串行调度队列 `audioProcessingQueue`，避免阻塞主线程 UI 与蓝牙信令；
- **状态与控制接口暴露**：
  - 增加 `@Published var isGlassesMicActive: Bool = false`；
  - 增加 `@Published var audioPacketPPS: Int = 0`（每秒音频包计数，用于遥测监控）；
  - 增加音频包回调闭包：`var onAudioPacketReceived: ((Data) -> Void)?`；
  - 实现 `startGlassesMicrophone()` 与 `stopGlassesMicrophone()` 方法。

---

### 2.3 音频解码与缓冲流水线 (Audio Pipeline)

#### 新增目录：`mobile_gateway_ios/SmartGlassGateway/Audio/LC3/`
- 引入 Google 原生纯 C `liblc3` 解码器核心源文件：
  - `lc3.h` / `lc3.c`
  - `tables.h` / `tables.c`
  - `common.h` / `bits.h`

#### 新增文件：`mobile_gateway_ios/SmartGlassGateway/Services/G2LC3AudioDecoder.swift`
- 实现 Swift 包装的流式解码器：
  - 初始化 16kHz, 10ms frame, mono 解码上下文（单帧 40 字节压缩，输出 160 个 `Int16` 采样点）；
  - 实现 `decodePacket(_ packetData: Data) -> AVAudioPCMBuffer?`：
    - 校验数据包长度（必须为 205 字节）；
    - 循环解码 5 个 40 字节 LC3 帧（对应 50ms 音频，共 800 个采样点）；
    - 检查 Byte 204 序列号判定丢包；
    - 封装生成标准 `AVAudioPCMBuffer`。

---

### 2.4 语音跟随引擎重构 (Speech Follow Engine)

#### 新增文件：`mobile_gateway_ios/SmartGlassGateway/Services/AudioInputSourceProtocol.swift`
- 抽象统一输入源接口：
  ```swift
  enum AudioSourceType: String, CaseIterable {
      case phoneMic    = "📱 手机麦克风"
      case glassesMic  = "👓 眼镜麦克风"
  }
  
  protocol AudioInputSourceProtocol: AnyObject {
      var sourceType: AudioSourceType { get }
      func startStreaming(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws
      func stopStreaming()
  }
  ```

#### 修改文件：`mobile_gateway_ios/SmartGlassGateway/Services/SpeechFollowEngine.swift`
- **解耦原生麦克风依赖**：
  - 将原有的 `AVAudioEngine.inputNode` 封装为 `PhoneBuiltinAudioSource`；
  - 新建 `GlassesBLEAudioSource`（监听 `BLEManager.onAudioPacketReceived` 并经 `G2LC3AudioDecoder` 转换为 `AVAudioPCMBuffer`）；
- **动态无缝热切换**：
  - 增加 `@Published var currentAudioSource: AudioSourceType = .phoneMic`；
  - 实现 `switchAudioSource(to: AudioSourceType)`：平滑关闭当前源、切换输入管道、重置识别请求任务，无需重启提词器。

---

### 2.5 用户界面与遥测交互 (UI & Telemetry)

#### 修改文件：`mobile_gateway_ios/SmartGlassGateway/Views/ContentView.swift`
- 在提词与控制视图中增加“🎤 采音源切换器”Picker：
  - 允许教师在 `[ 📱 手机麦克风 | 👓 眼镜麦克风 ]` 之间一键点选；
  - 动态显示当前选中的输入源与音频状态（如眼镜麦克风流速 `20 pps`、音频输入电平指示）。

#### 修改文件：`mobile_gateway_ios/SmartGlassGateway/Views/G2DebugView.swift`
- 在 G2 调试面板增加：
  - “麦克风单测控制”区域（测试开启 / 关闭麦克风）；
  - “6402 音频流原始遥测”（实时包数、最近 1 包 Hex、解码采样率与音量分贝值）。

---

## 3. 验证计划 (Verification Plan)

### 3.1 协议与解码自动化单元测试
- **测试命令**：
  在 `mobile_gateway_ios/` 下编写并运行轻量协议测试脚本：
  ```bash
  swift mobile_gateway_ios/test_audio_protocol.swift
  ```
- **验证内容**：
  - `G2ProtocolEncoder.buildAudioControlPacket(enable: true)` 输出标准 Cmd=18 报文；
  - 模拟合成 205B 音频包，经 `G2LC3AudioDecoder` 解码后，验证输出格式为 16kHz 单声道、有效采样点数为 800，且 PCM 数据无崩溃或溢出。

### 3.2 真机硬件联调与物理断言
1. **握手与 6402 通道激活验证**：
   - 连接 Even G2 智能眼镜，进入提词模式；
   - 点击“启动眼镜麦克风”，观察控制台日志：
     - `5401` 下发 Cmd=18；
     - `5402` 收到 Cmd=19 ACK；
     - `6402` 开始高频接收 205B 数据包，PPS 稳定在约 19~21 包/秒。
2. **端到端 ASR 识别与提词跟随验证**：
   - 手机放置在远离教师 5 米外的讲台上；
   - 教师佩戴 Even G2 智能眼镜，切换输入源为“👓 眼镜麦克风”；
   - 教师正常口述幻灯片逐字稿，观察 iPhone 调试界面是否实时产生高准确率的 ASR 增量文本；
   - 验证 MicroLED 提词视口是否根据教师眼镜拾音的进度平滑自动推进。
3. **双向热切换稳定性验证**：
   - 在提词进行中连续在“📱 手机麦克风”和“👓 眼镜麦克风”之间切换，验证系统无崩溃、无内存泄漏、ASR 任务平滑续期无卡死。
