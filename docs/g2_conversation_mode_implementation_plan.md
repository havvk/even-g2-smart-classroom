# Even G2 智能眼镜对话模式 (Conversate 实时同传 / Even AI 语音助手) 技术白皮书与实施规划书

> **版本**：v3.0 (原生双视口流式渲染、高保真防抖耳语播报与实时建议决策引擎完整落地版)  
> **状态**：全链路工程落地并通过真机验证 (iPhone 16 Pro Max + Even G2 + AirPods Pro 3 实测闭环)  
> **适用模块**：`mobile_gateway_ios` (SmartGlassGateway) / `watchOS Companion` / `liblc3` / `Service 0x0B-20` & `Service 0x6450`  
> **核心机制**：左右镜腿双外设物理拓扑分流 + 双轨能量/桌面自适应说话人判别 + 原生 0x0B-20 双视口共存 (顶部 AI 提示胶囊卡片 / 底部实时字幕打字流) + 预合成高保真防抖缓冲耳语播报 + 话轮感知实时建议决策引擎 (Gatekeeper 意图过滤与 ≤12 字微文案)

---

## 1. 概述与业务场景定义

在智慧教学、学术交流、涉外会议与日常高端商务沟通中，Even G2 智能眼镜凭借其轻量隐形的单色 MicroLED 绿色衍射光波导显示与双镜腿集成麦克风，具备成为下一代“外脑级实时沟通伴侣”的极高潜力。

官方 Even Realities App 原厂的对话功能虽然体验新颖，但在实际深度使用中存在四大致命短板：
1. **完全依赖公网云端**：弱网或校园内网环境下网络抖动极易导致 ASR 断连、超时卡死（Spinner 转圈）；
2. **双工对话串音与回声干扰**：单麦克风模式无法有效分离佩戴者与外界交谈者的声音；
本规划书旨在为开源/自研生态（`SmartGlassGateway`）设计并实现一套高可靠、低延迟、全本地可控且具备高审美交互的**智能眼镜分屏对话协同引擎（Conversation Copilot Engine）**。

其核心业务价值是：在佩戴者与他人进行面对面对话（商务谈判、学术答辩、涉外交流、面试沟通）时，眼镜系统自动担当**“隐形贴身幕僚”**——全天候监听双方发言，在对方发言结束的瞬间，由后台 **AI 助手引擎** 实时理解上下文意图，并在眼镜视口与耳机中提供极简、致命关键的应对策略与事实支撑。

### 1.1 系统核心全链路数据流

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                   Even G2 对话协同引擎 (Conversation Copilot)              │
├─────────────────────────────────────────────────────────────────────────────┤
│ 1. 声音感知层: 镜腿 LC3 麦克风 + 手机麦克风 ──► 双轨能量实时说话人判定 (我 vs 他) │
│ 2. 语音识别层: 长连流式 ASR 引擎 ──► 毫秒级原地打字与断句定稿 (is_final)       │
│ 3. 视口呈现层: Even G2 MicroLED 屏幕 (Service 0x0B-20) ──► 底部流式字幕滚屏 │
│ 4. 智能决策层 (AI 助手核心 - 双层模型架构):                                │
│    话轮停顿感知 ──► Tier 1 端侧 0.5B 语义守门 ──► Tier 2 策略大模型 ──► 决策卡片 │
│ 5. 双模反馈层: 顶部视口圆角胶囊 (≤12字) + AirPods 防抖缓冲私密耳语播报       │
└─────────────────────────────────────────────────────────────────────────────┘
```

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                       Even G2 分屏对话中枢 (Dual-Region Copilot)             │
├───────────────────────────────────────┬─────────────────────────────────────┤
│         【上半区: Region A】          │         【下半区: Region B】        │
│    主动智能决策层 (Invisible Copilot)  │    客观事实呈现层 (Ground Truth)     │
├───────────────────────────────────────┼─────────────────────────────────────┤
│ • 场景 1【自己讲话时】:                │ • 全天候监听与转写:                  │
│   👉 话题延续与分支推荐 (Topic Steer) │   毫秒级流式呈现双方当前语音内容    │
│   👉 提供关键数据、论据支持或反问技巧 │ • 动静分区规则 (is_final):           │
│                                       │   未完句原位打字，断句后平滑滚屏    │
│ • 场景 2【对方讲话时】:                │ • 硬件声道标识:                     │
│   🔍 意图解读与潜台词剖析 (Intent)    │   清晰标注 [我] 与 [Guest] 说话人    │
│   🔍 关键事实背景或防守论点提示       │                                     │
│ • 交互特性: 提示历史堆栈 + 滑动翻看   │ • 纯语音流驱动，无需任何手势干预    │
└───────────────────────────────────────┴─────────────────────────────────────┘
```

---

## 2. 硬件拓扑与底层 BLE 通信协议解密

### 2.1 左右镜腿双外设物理拓扑与通道映射

Even Realities G2 镜架横梁内**无物理铜线总线**，左右镜腿由两颗独立的 BLE SOC 芯片驱动，因此在物理层表现为两个独立的 BLE 外设：

| 物理实体 | BLE 广播标识规则 | 核心外设职能 | 关键 GATT Characteristic |
| :--- | :--- | :--- | :--- |
| **左镜腿 (`_L_`)** | `Even G2_XX_L_YYYYYY` | **麦克风阵列拾音主力**、音频流低功耗传输 | `6402` (Notify，推送 205B 音频包) |
| **右镜腿 (`_R_`)** | `Even G2_XX_R_YYYYYY` | **MicroLED 显存视口渲染**、Touchpad 触控板手势上报 | `5401` (WriteCmd，信令与字幕下发)<br>`6401` (WriteCmd，流媒体控制)<br>`5402` (Notify，ACK 与触控中断) |

> ⚠️ **双外设协同策略**：
> 网关必须维护与右镜腿的主通信会话（用于控制显示和接收触摸），并在开启音频拾音时动态绑定左镜腿的 `6402` 监听通道。

---

### 2.2 麦克风硬件使能与时序 (`Service 0x6450` / `EvenHub Cmd=18`)

眼镜内部声学传感器与高频 BLE 发送模块功耗显著，必须严格遵循安全启停状态机：

```text
手机 Gateway (iOS)                                     Even G2 眼镜
       │                                                    │
       ├──── 1. 下发挂载视口指令 (0x0B-20 Init / 0x0E Setup) ───►│ (MicroLED 光机上电就绪)
       │                                                    │
       ├──── 2. EvenHub Cmd = 18 (APP_REQUEST_AUDIO_CTR) ───►│ (通道 5401 / 6401)
       │         Payload: AudioCtrCommand { AudoFuncEn: 1 } │
       │                                                    │
       │◄─── 3. EvenHub Cmd = 19 (OS_RESPONSE_AUDIO_CTR) ────┤ (通道 5402, AudioStat=1)
       │                                                    │
       │◄─── 4. Unframed 205B 音频包流 (20 packets/s) ───────┤ (通道 6402 持续 Notify)
       │                                                    │
```

- **兼容性降级指令**：在旧版或轻量固件中，直接向 `5401` 写入 `[0x0E, 0x01]` 可直接触发硬件上电；
- **休眠关断指令**：退出对话模式时，下发 `AudioCtrCommand { AudoFuncEn: 0 }` 或 `[0x0E, 0x00]`，防止镜腿发热掉电。

---

### 2.3 205 字节音频包与 LC3 解码流水线

`6402` 特征值抛出的数据包不具备常规协议的 `0xAA 0x21` 包头，其固定二进制规格为 **205 字节**：

```text
┌───────────────────────────────────────────────────────────────────────────┬─────────────────────┐
│                    5 × 40-byte LC3 音频压缩帧 (共 200 字节)                 │ 5-byte Trailer 元数据│
│  [Frame 0: 40B]  [Frame 1: 40B]  [Frame 2: 40B]  [Frame 3: 40B]  [Frame 4] │  保留字节  [SeqNo]  │
└───────────────────────────────────────────────────────────────────────────┴─────────────────────┘
  ◄── 0..39 ──►    ◄── 40..79 ─►   ◄── 80..119 ─►  ◄── 120..159 ─► ◄─ 160..199 ─►  ◄── 200..204 ──►
  ◄──────────────────────── 205 字节 (单包 BLE 接收单位) ──────────────────────────────────────────►
```

- **编码参数**：Bluetooth LE Audio 标准 LC3，16 kHz 采样率，10ms 帧长，单声道 Mono；
- **Byte 204**：单调递增帧序列号（`0..255`），接收端网关通过 `(currentSeq - lastSeq) & 0xFF` 快速判定蓝牙传输是否发生丢包并启动 PLC (Packet Loss Concealment) 丢包隐藏算法；
- **解码输出**：经 Google 原生纯 C 库 `liblc3` 解码后，单包生成 $5 \times 160 = 800$ 个采样点（16-bit PCM / Float32，时长 50ms），封装为 `AVAudioPCMBuffer`。

---

### 2.4 上半区清除旧内容与覆写更新的 3 大工程机制

针对开发者普遍担忧的“上半区无法清除旧内容/显存残影”问题，规划采用以下 3 种经过逆向实证的机制：

```text
机制 A: 空格点阵全灭覆写 (物理级清屏)
[下发充满视口的 0x20 空格字符] ──► MicroLED 像素驱动电流归零 ──► 瞬间全黑透明

机制 B: 卡片插槽整块覆盖 (Card Slot Replacement)
[下发新 Card (携带递增 msg_id)] ──► 固件以新帧缓存整块擦写旧内容 ──► 无任何残影

机制 C: 空串透明消隐 (Empty String Auto-Fadeout)
[下发 text = "" 或超时 8~10s] ──► 上半区视口自动收起 ──► 视野恢复干净无遮挡
```

---

## 3. 全双工双轨音频管道与硬件级说话人判别

### 3.1 真实物理场景的声学挑战与工程痛点

在真实移动场景下，若机械式依赖“双麦克风固定能量比值（$\text{Ratio} = \text{GlassesMic} / \text{PhoneMic}$）”，会遭遇两大致命工程短板：
1. **手机放口袋时的声学倒挂误判 (Acoustic Inversion in Pocket)**：
   - 当用户将手机随手放入裤兜或大衣内袋时，衣物面料（牛仔布、羽绒、毛呢）产生高达 **15~25 dB 的高频吸音与声学衰减**；
   - 此时坐在对面的人说话，声波直接穿透空气传至鼻梁/镜腿上的眼镜麦克风；
   - 眼镜麦克风接收到的能量**反而大幅超过被口袋遮蔽的手机麦克风**，导致比值计算严重失真，将对方讲话完全误判为 `[我]`！
2. **手机麦克风常开的功耗与发热**：
   - 手机端 `AVAudioEngine` 持续安装 Tap 采集 48kHz 音频，强制唤醒 iOS 底层 CoreAudio 硬件线程与 DSP，导致 iPhone 持续发热、电量急剧损耗，并录入裤兜摩擦的低频沙沙声。

针对上述痛点，系统架构演进为**三级复合判别与自适应休眠体系**：

---

### 3.2 方案一：单眼镜 Mic 物理近场能量门限 (Glasses-Only Near-Field Gate)

佩戴者讲话与外界交谈者在眼镜端声学传感器上具有**极其鲜明的物理分界线**：

```text
【佩戴者讲话 (我)】
  距离左镜腿仅 5~8 厘米 + 颌骨/颅骨直接声振传导 + 口腔近场气流冲击
  ──► 眼镜 Mic 能量极高 (RMS 归一化电平通常在 35% ~ 100%)
  ──────────────────────────────────────────────────────────  ◄── [近场门限阈值: 默认 30%]
【对面交谈者 (对方)】
  距离 1~2 米 + 平方反比空气传播衰减 (衰减 > 25dB) + 零骨导震动
  ──► 眼镜 Mic 能量处于低区间 (RMS 归一化电平通常在 8% ~ 25%)
  ──────────────────────────────────────────────────────────  ◄── [环境静音底噪: 约 5%]
```

- **判定规则**：
  - $\text{Level}_{\text{glasses}} \ge \text{Threshold}_{\text{nearField}}$（默认 30%）：确认为**【我方发言】**；
  - $5\% \le \text{Level}_{\text{glasses}} < \text{Threshold}_{\text{nearField}}$：确认为**【对方发言】**；
  - $\text{Level}_{\text{glasses}} < 5\%$：环境静音，维持上一判定状态或未知；
- **极致省电与零误判**：
  - 在此模式下，**手机麦克风完全处于关断休眠状态（Stop）**，iPhone 零额外 CPU 消耗，手机可安心塞入口袋或背包，彻底解决口袋遮挡导致的误判。

---

### 3.3 方案二：基于 CoreMotion 的桌面放置自动侦测与手机 Mic 自适应休眠 (Desktop Placement Auto-Detection)

为了在用户将手机置于桌面时自动发挥双麦克风空间隔离的最大优势，系统利用 iPhone 内置的超低功耗**运动协处理器 (Motion Coprocessor)** 构建三维桌面探测矩阵：

```text
┌────────────────────────────────────────────────────────────────────────┐
│                   桌面放置三维传感器判据 (Desktop Matrix)               │
├───────────────────────┬────────────────────────────────────────────────┤
│ 1. 空间水平姿态       │ 重力分量 |z| > 0.88 (屏幕朝上或朝下，平放夹角 < 25°)  │
│    (Gravity Vector)   │ 证实手机平铺于固定平面，而非竖立在口袋/拿在耳边│
├───────────────────────┼────────────────────────────────────────────────┤
│ 2. 绝对零抖动静止     │ 连续 1.5~2.0 秒内：                            │
│    (Zero Motion)      │ • 动态用户加速度 |userAccel| < 0.015g           │
│    (CoreMotion)       │ • 陀螺仪旋转角速度 |rotRate| < 0.03 rad/s      │
│                       │ 过滤手持微颤(8~12Hz)与步行晃动，锁定绝对静止   │
├───────────────────────┼────────────────────────────────────────────────┤
│ 3. 非口袋贴身遮挡     │ 近距离传感器 proximityState == false           │
│    (Proximity Sensor) │ 排除正面紧贴大腿内侧布料的口袋场景             │
└───────────────────────┴────────────────────────────────────────────────┘
                                  │
                  ┌───────────────┴───────────────┐
                  ▼                               ▼
       【三者同时满足: 放置在桌面】       【任一破坏: 拿起手机 / 口袋手持】
       • 自动唤醒手机麦克风              • 0.1 秒内彻底关闭/休眠手机麦克风
       • 激活双麦空间比对 (模式 B)        • 自动切回单眼镜近场门限 (模式 A)
       • 双向高精度说话人分离            • iPhone 零功耗，防口袋摩擦杂音
```

- **功耗优势**：`CMMotionManager` 仅以 10Hz 低频轮询，功耗处于微安级，相较持续开启 48kHz 录音**省电超过 99%**。

---

### 3.4 方案三：声纹识别 (Voiceprint Diarization) 三阶演进路线

为了追求极端复杂声学环境（如嘈杂餐厅、佩戴者轻声耳语）下的极致判别精度，规划声纹演进路线：

1. **Phase 1（当前工程落地：物理声学能量门限）**：
   - 依赖单眼镜近场骨导与桌面自适应侦测，零冷启动、无需声纹录制，立即投入使用；
2. **Phase 2（轻量频谱共鸣特征识别：FFT Low/High Spectral Energy Ratio）**：
   - 利用近场骨传导特有的声学特征：佩戴者说话时镜腿收录丰富的 **<200Hz 低频胸腔骨导共鸣**，而远场交谈者声音在眼镜端以 **1kHz~3kHz 辅音扩散波**为主；
   - 通过短时 FFT 计算低高频能量比重，辅助能量门限实现无声纹注册下的超强抗噪二重校验；
3. **Phase 3（端侧离线轻量声纹向量模型：CoreML Voiceprint Embedding）**：
   - 预留 `VoiceprintClassifierProtocol` 标准接口；
   - 引入轻量级 ResNet / ECAPA-TDNN 端侧模型，佩戴者首次使用录制 3 秒声纹生成 192 维特征向量，后续实时推断提取 Embedding 计算余弦相似度，实现 100% 绝对声学身份固化。

---

### 3.5 AI 提示耳语语音播报与耳机硬件自适应联动 (Audio Whisper Prompt)

为了在保持 MicroLED HUD 视线极简平静的同时，进一步降低佩戴者的视线转移负担，系统引入**耳语级 AI 语音播报（Audio Whisper）**子系统：

```text
               ┌─────────────────────────────────────────────────────┐
               │              AI 胶囊生成 (pushAIPrompt)             │
               └───────────┬─────────────────────────────┬───────────┘
                           │ 视觉下发 (BLE 5401)          │ 语音耳语 (TTS)
                           ▼                             ▼
                 Even G2 镜片 Region A        ┌───────────────────────┐
                 [💡 建议: 先确认工期]         │ 检查耳机连接状态与开关 │
                                              └───────────┬───────────┘
                                       已佩戴耳机 (AirPods)│       │未戴耳机 / 已拔出
                                                          ▼       ▼
                                                   【耳机私密播报】  【坚决静音关断】
                                                 (零外泄 / 零串扰) (防公放打扰与啸叫)
```

1. **耳机连接状态实时自适应 (Headphone Auto-Sensing)**：
   - 通过 `AVAudioSession.currentRoute.outputs` 实时扫描音频输出端口（`.headphones`、`.bluetoothA2DP`、`.bluetoothHFP`、`.bluetoothLE`）；
   - 监听 `AVAudioSession.routeChangeNotification` 广播：
     - **检测到戴上/连接耳机**：自动开启 `isAudioPromptEnabled = true`，进入耳语辅助模式；
     - **检测到拔出/断开耳机**：自动关闭 `isAudioPromptEnabled = false`，UI 明确指示“已自动静音，防外放泄露”；
     - **用户自主权**：界面提供专属切换开关，用户可在任何时刻手动覆写开启/关闭。
2. **零外泄与防声学回授安全红线 (Zero Acoustic Leakage)**：
   - 严禁在无耳机连接时通过手机扬声器公放！防止会议/交流中暴露“AI 辅助”，同时彻底杜绝手机扬声器声音被手机麦克风或眼镜麦克风二次采集导致 ASR 严重串扰与正反馈啸叫。
3. **音频流水线混合配置 (AudioSession Coexistence)**：
   - 采用 `.playback` 或 `.playAndRecord` 配合苹果官方标准 `.spokenAudio` 模式，在维持清晰拾音的同时，保障最高品质的私密音频耳语输出。
4. **推流毛刺的声学机理定性与高保真防抖缓冲方案 (Anti-Glitch Buffer via Pre-Synthesis)**：
   - **0.5 秒毛刺的物理本质锁定**：
     在 iPhone 16 Pro Max + AirPods Pro 3 蓝牙链路下，系统为追求超低延迟，与蓝牙耳机协商的 I/O 缓冲区极其微小（只有 **5.3ms**，`IO=0.0053s`）。原生 `AVSpeechSynthesizer.speak()` 采用流式计算——先填充约 0.5s 前置音频向硬件推流，随后在 ANE 上边算边推。在 0.5s 前后首批预填充数据耗尽的临界瞬间，蓝牙射频调度或线程切换只要出现微秒级抖动，5.3ms 极小硬件缓冲区瞬间发生**耗尽断流（Buffer Underrun / XRun）**，导致 DAC 数模转换器发生强制过零点撕裂，在耳机中爆出刺耳毛刺；
   - **判决性实测闭环 (2026-09-13)**：
     - *链路 A (原生实时流式)*：必现 0.5s 刺耳毛刺；
     - *链路 B (预合成整句缓冲推流)*：**100% 顺滑，完全无毛刺**！
     - *链路 C (零 TTS 真实离线波形直放)*：**100% 顺滑，完全无毛刺**！
     铁证证实音频模型与文本本身无任何质量缺陷，毛刺 100% 产生于实时推流缓冲区断流。
   - **生产固化方案：全量预合成防抖缓冲推流**：
     系统默认启用 `isPreSynthesizeModeEnabled = true`。调用 `AVSpeechSynthesizer.write(utterance)` 在后台以 ANE 最高算力极速（50~80ms）将整句 PCM 渲染完毕并安全写入本地临时缓存，待整句完整就绪后，交付给拥有充沛饱和缓冲区的 `AVAudioPlayer` 一口气推流播报。硬件推流管道永远处于饱和状态，物理上彻底杜绝了 5.3ms 缓冲区断流下溢的可能；
   - **ARC 强引用生命周期保护**：
     为防止 Swift ARC 机制在函数退出时自动回收局部 `synth` 导致异步 `write` 任务被系统取消（产生无声现象），必须由类级别属性 `preSynthesizer` 实施全局强引用锁定，直到整句渲染完成并交由播放器接管后方可安全复位。

---

### 3.6 总体数据流拓扑图

```text
                             ┌───────────────────────────────────┐
                             │       Even G2 智能眼镜            │
                             │  ┌──────────────┐ ┌─────────────┐ │
                             │  │ 镜腿麦克风(左)│ │MicroLED HUD(右)│ │
                             └──┴──────┬───────┴─┴──────▲──────┴─┘
                                       │ 6402 (LC3)     │ 5401 (0x0B/0x0E)
                                       ▼                │
┌────────────────────────────────────────────────────────────────────────┐
│ iOS 手机网关 (SmartGlassGateway)                                        │
│                                                                        │
│  ┌────────────────────────┐                   ┌──────────────────────┐ │
│  │   G2LC3AudioDecoder    │                   │ G2ProtocolEncoder    │ │
│  │ (Google liblc3 C-Core) │                   │(Region A/B 协议封装) │ │
│  └───────────┬────────────┘                   └──────────▲───────────┘ │
│              │ AVAudioPCMBuffer                          │             │
│              ▼                                           │             │
│  ┌────────────────────────┐                   ┌──────────┴───────────┐ │
│  │ 双轨能量说话人分离器   │                   │ 18字微要点排版与清屏 │ │
│  │ (Glasses vs Phone RMS) │                   │ (空格覆写/卡片置换)  │ │
│  └───────────┬────────────┘                   └──────────▲───────────┘ │
│              │                                           │             │
│              ▼                                           │             │
│  ┌───────────────────────────────────────────────────────┴───────────┐ │
│  │            ConversationCopilotManager (对话中枢控制器)             │ │
│  │  ┌──────────────────────────────┐ ┌─────────────────────────────┐ │ │
│  │  │ 【自己说话分支】              │ │ 【对方说话分支】            │ │ │
│  │  │ • 话题延续与分支推荐 (Steer) │ │ • 意图拆解与潜台词分析    │ │ │
│  │  │ • 论据要点 / 互动反问提词    │ │ • 关键事实核查与应对锦囊  │ │ │
│  │  └──────────────────────────────┘ └─────────────────────────────┘ │ │
│  └───────────────────────────────────────────────────────────────────┘ │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ WCSession
                                    ▼
                     ┌─────────────────────────────┐
                     │     Apple Watch 伴侣应用    │
                     │ • 触控板 1:1 遥控翻页与注销 │
                     │ • 转腕体感静音 / 模式快速切换│
                     └─────────────────────────────┘
```

---

## 4. MicroLED HUD 视口排版与原生 0x0B-20 双视口渲染

### 4.1 物理约束与原生协议映射
- **有效显示安全区**：267 点阵宽，高度约 200 点阵，绿色单色 MicroLED；
- **原生双视口协议架构 (`Service 0x0B-20`)**：
  经过对官方 Even Realities App 的真实蓝牙抓包分析，G2 固件原生支持双视口独立渲染：
  - **顶部视口 (Top Viewport / Tag 7: `ConversateAIPrompt`)**：
    下发圆角边框胶囊卡片（`card_type = 4`），内置 AI 标识/Emoji、精炼标题（`title`）与展开详情（`detail`）；
  - **底部视口 (Bottom Viewport / Tag 8: `ConversateTranscript`)**：
    下发实时字幕流（`text`），通过 `is_final` 标志位控制原地打字（0）或定稿滚屏（1）；
  - **显存同步刷帧标记 (Tag 11: `ConversateMarker`)**：
    空载荷 `5A 00` 触发固件内部 VRAM 提交（Flush Latch），确保上下视口无撕裂同步刷新。

### 4.2 双视口交互排版样例

```text
┌────────────────────────────────────────────────────────────────────────┐
│  ╭───────────────────────────────────────╮                             │
│  │ 💡 建议: 先确认交付工期               │ <-- 顶部: AI 提示胶囊卡片
│  ╰───────────────────────────────────────╯     (圆角边框, ≤12字, 4~6s 自隐)
├────────────────────────────────────────────────────────────────────────┤
│ [我] 关于硬件架构，我们重点对低功耗射频芯片进行了二次定制...            │ <-- 底部: 实时流式语音转写区
│ > 并且在实际测试中...                                                   │     (高频 ASR 驱动，is_final 滚动)
└────────────────────────────────────────────────────────────────────────┘
```

---

## 5. 实时对话建议决策引擎 (Real-Time Conversation Copilot Intelligence)

在面对面对话与涉外商务沟通中，如果机械地每句话都请求大模型并向用户推送建议，会导致**极度严重的认知过载（Cognitive Overload）**——佩戴者注意力被持续打碎，眼珠频繁向右上角斜视，导致**眼神交流（Eye Contact）彻底丧失**，极易让对方感知佩戴者正在依赖外设作弊。

因此，对话决策引擎确立三大核心支柱：**“克制触发”**、**“盲区聚焦”**与**“双模低语”**。

```mermaid
flowchart TD
    A[流式 ASR / DualTrackSpeakerDetector] --> B{说话人判定}
    B -- 用户本人发言 (Me) --> C[仅记录转写 / 绝不惊动建议引擎]
    B -- 对方发言 (Other) --> D[话轮结束检测 (Turn-Taking Pause > 0.8s)]
    D --> E[轻量网关 Gatekeeper 意图分类器]
    E -- 纯客套 / 闲聊 / 简单应答 --> F[保持静默 / 仅历史转写归档]
    E -- 触发高价值信号 --> G[组装 Context 提交建议引擎]
    G --> H[大模型极速推断 (流式首 Token / 严格微文案约束)]
    H --> I[双模下发: G2 顶部胶囊 + 耳机私密耳语]
```

### 5.1 实时获取建议的时机与捕获管道 (When & How to Acquire)

1. **说话人感知与话轮转换（Speaker-Aware Turn-Taking）**：
   - **我方发言中**：保持绝对安静，专注记录与视口滚动，**坚决不给佩戴者推送任何提示**（打断用户自己的表述思路是灾难性的）；
   - **对方发言结束（Pause > 0.8s ~ 1.2s）**：这是唯一的**黄金决策介入窗口**。当检测到对方话语停顿、且句末出现疑问（`？`）、质疑、要求报价、确认交期等关键特征时，瞬时唤醒建议引擎。
2. **轻量网关意图过滤（Gatekeeper Filter）**：
   - 不盲目把“好的”、“是的”、“先坐下聊”等寒暄发给大模型；
   - 设立意图触发准则：仅当捕获到**事实咨询、方案质疑、谈判博弈、情绪异动、承诺确认**五类关键意图时才触发建议生成。
3. **滑动对话窗口与先验目标绑定（Sliding Context + Priors）**：
   - 提交给建议引擎的 Context 结构：
     - **先验背景 (Priors)**：本场会话目标与红线（如：`商务谈判·底线是工期延至下周·预算上限40万`）；
     - **短期上下文 (Sliding Context)**：最近 3~4 个话轮的双方发言记录；
     - **最新焦点 (Latest Focus)**：对方刚刚抛出的核心诉求或反问。

### 5.2 建议内容的关注点 (What to Focus On)

大模型在常规对话中倾向于“长篇大论”，但在智能眼镜和耳机里，**绝对不能替用户撰写完整的讲话稿**。
建议内容必须严格聚焦于人类大脑在面对面高压交互时**最容易短路、遗忘或失控的三大盲区**：

| 关注维度 | 痛点场景 | Copilot 建议的关注点 | 典型示例 |
| :--- | :--- | :--- | :--- |
| **1. 事实与硬核数据 (Hard Facts & Anchors)** | 面对面即兴对话时，人脑最难迅速调取准确数字、条款编号或历史定论 | 瞬间调取预设知识库或历史备忘中的确切数字、日期与条款 | 对方问：*“你们之前承诺的验收标准是哪版？”*<br>👉 **建议**：`引用2025版国标GB/T-3450` |
| **2. 谈判与话术支点 (Strategic Pivots)** | 容易被对方带节奏，陷入被动承诺或无预谋让步 | 提供心理学上的“先扬后抑”、“反问探底”或“缓兵之计”话术支点 | 对方施压：*“成本太高了，必须降15%！”*<br>👉 **建议**：`不直接谈价格，询问对方可削减的功能范围` |
| **3. 风险与陷阱预警 (Red Flags & Traps)** | 对方使用了模糊词汇（如“尽快”、“先做做看”），容易埋下履约隐患 | 提醒明确权责边界，防止口头承诺越界 | 对方说：*“这个小改动你们顺手带上吧。”*<br>👉 **建议**：`提示：此变更涉及架构调整，需走变更单` |

### 5.3 展现形式与双模协同规范 (Delivery Modality & Ergonomics)

Even G2 拥有**视觉（MicroLED 视口）与听觉（AirPods 私密耳语）双模输出能力**，两者必须分工协同：

#### 1. 眼镜视口形式（一瞥即得 · 极致微文案）
- **胶囊卡片 Title（严格约束 ≤ 12 个字）**：
  - 格式公式：`[标签] 动作动词 + 核心名词`；
  - 示例：`[💡 策略] 反问对方验收指标`、`[📌 数据] 工期底线为10月15日`、`[⚠️ 预警] 勿口头承诺硬件成本`；
- **胶囊卡片 Detail（触控板触控展开）**：
  - 如果用户快速敲击镜腿，胶囊卡片展开展示 2~3 行话术要点（Bullets，上限 40 字）；
- **渐隐时序（Auto-Fadeout）**：
  - 卡片在视口停驻 **4~6 秒**后自动自然渐隐淡出，绝不长期霸屏干扰视线。

#### 2. 耳机耳语形式（贴身副手 · 免动眼珠）
- **语态设计**：口语化、平稳、无冷硬前缀（禁止播报“AI建议您……”），以**贴身幕僚**的口吻低声提醒；
- **字数限制**：控制在 **1 句话、8~15 个字以内**（播放耗时约 1.5 秒），听完即可自然接话；
- **发音保障**：采用经实证闭环的**高保真预合成防抖缓冲推流**，彻底杜绝爆音与毛刺。

#### 3. 三大体验交互模式
- **安静隐蔽模式（仅眼镜）**：在极度安静的会议室，仅通过视口胶囊闪现提示；
- **自然视线聚焦模式（仅耳机）**：完全不看屏幕，视线 100% 锁定对方眼睛，全靠耳机里的简短耳语提点（社交表现力最强）；
- **双模联动模式（默认推荐）**：耳机播放关键动作（如“反问验收标准”），眼镜同步呈现详细数据支持（如“国标第4.2款”）。

### 5.4 核心数据结构与模型定义 (`Models/CopilotSuggestionModels.swift`)

```swift
/// 会话先验背景 (用户在开启对话前配置的立场与红线)
struct MeetingContextPriors {
    var topic: String             // 会话主题 (例如: "Q4 交付工期与价格谈判")
    var myRole: String            // 我方立场 (例如: "乙方项目负责人")
    var goal: String              // 核心诉求 (例如: "保住毛利率，工期可宽限至10月底")
    var bottomLines: [String]     // 绝对底线 (例如: ["绝不答应两周内交付", "硬件成本另计"])
    var counterparty: String      // 对方身份 (例如: "甲方采购总监，风格强势挑剔")
}

/// 大模型生成的结构化决策建议
struct CopilotSuggestion: Codable {
    let shouldSuggest: Bool       // 是否确有必要提示 (Gatekeeper 再次兜底)
    let title: String             // 眼镜顶部单行胶囊 (严格 ≤ 12 汉字，动宾短语)
    let detail: String            // 触控展开阅读要点 (2~3 行 Bullets，≤ 40 汉字)
    let whisper: String           // 耳机耳语播报词 (8~15 汉字，贴身幕僚口语)
    let category: SuggestionType  // 建议分类: 事实数据 / 谈判支点 / 风险预警
    
    enum SuggestionType: String, Codable {
        case hardFact = "fact"    // 硬核数据
        case strategy = "strat"   // 谈判话术
        case warning = "warn"     // 陷阱预警
    }
}
```

### 5.5 话轮停顿感知与触发调度器 (`ConversationTriggerScheduler`)

为了避免在对方长句的中间顿挫时过早打扰，调度器必须具备**话轮停顿感知**与**佩戴者开口防打断撤销机制**：

```swift
class ConversationTriggerScheduler {
    private var silenceTimer: DispatchWorkItem?
    private var lastSuggestionTime: DispatchTime = .now() - .seconds(60)
    
    /// 两次建议推送之间的最小冷却期 (默认 10 秒，防止频繁弹窗打乱交流节奏)
    let cooldownInterval: Double = 10.0
    
    /// 话轮结束停顿阈值 (对方停顿超过 800ms 判定为话轮转折点)
    let turnSilenceThreshold: Double = 0.8
    
    /// 收到转写定稿事件
    func onUtteranceCommitted(speaker: SpeakerRole, text: String, onTrigger: @escaping () -> Void) {
        // 规则 1: 佩戴者自己 (Me) 讲话，坚决取消任何挂起的建议任务，保持绝对安静
        if speaker == .me {
            silenceTimer?.cancel()
            silenceTimer = nil
            return
        }
        
        // 规则 2: 处于 10 秒冷却期内，直接忽略
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - lastSuggestionTime.uptimeNanoseconds) / 1_000_000_000.0
        guard elapsed >= cooldownInterval else { return }
        
        // 规则 3: 对方讲话定稿，重置并启动 800ms 静音停顿定时器
        silenceTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lastSuggestionTime = .now()
            onTrigger()
        }
        silenceTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + turnSilenceThreshold, execute: timer)
    }
}
```

### 5.3 双层模型协同决策架构 (Two-Tier Model Architecture)

面对面高压对话中，对方的施压与质疑往往极其隐晦（如：“*以目前的市场行情，友商给出的配套方案似乎更具诚意*”），死板的正则表达式和关键词匹配根本无法理解潜台词。
系统必须依托 iPhone 16 Pro Max (A18 Pro) 的端侧神经算力，构建**“端侧毫秒级意图守门人 + 高智商策略生成引擎”**的双层模型架构：

```mermaid
flowchart TD
    A[对方语音结束 / 停顿 800ms] --> B[【Tier 1: 端侧毫秒级语义守门人】\nQwen2.5-0.5B-Instruct (CoreML / ANE)\n耗时 < 30ms / 内存 350MB]
    B -- 判定: 纯客套 / 闲聊 / 无深层意图 --> C[保持静默 / 视口与耳机零打扰 / 零云端开销]
    B -- 判定: 捕获隐式施压 / 质疑 / 数据索求 / 承诺越界 --> D{网络状态判决}
    D -- 在线 (主力) --> E[【Tier 2: 云端极速大模型】\nGemini 2.5 Flash / DeepSeek-V3\n耗时 ~250ms / 深度博弈心理学]
    D -- 离线 (无网兜底) --> F[【Tier 2: 端侧 1.5B 离线接管】\nQwen2.5-1.5B (CoreML)\n耗时 ~150ms]
    E --> G[输出结构化决策微文案:\n• G2 顶部 Tag 7 圆角胶囊 (≤12字)\n• AirPods 防抖缓冲幕僚低语 (8~15字)]
    F --> G
```

#### 1. Tier 1: 端侧毫秒级语义守门人 (`Services/OnDeviceGatekeeperLLM.swift`)
- **硬件承载**：部署在 iPhone 16 Pro Max 的 A18 Pro 神经引擎 (ANE) 上；
- **模型规格**：4-bit 量化 **Qwen2.5-0.5B-Instruct**（转换并封装为 `CoreML` 模型包，体积仅 **~350 MB**，内存常驻约 450 MB）；
- **极速推断**：针对 short-sequence（< 256 tokens）优化，端侧首 Token 延迟 **< 30 ms**；
- **守门人 Prompt 规范**：
  ```text
  你是一个面对面对话中的语义守门人。分析对方最后一句话是否存在深层潜台词、隐性施压、事实质询、交期/价格博弈或需我方谨慎应对的陷阱。
  若存在，输出 JSON: {"trigger": true, "intent": "隐式比价施压", "urgency": 2}
  若属于寒暄、纯信息应答或客套，输出: {"trigger": false}
  禁止输出多余字符。
  ```

#### 2. Tier 2: 高智商策略生成引擎 (`Services/ConversationAIService.swift`)
- **放行机制**：仅当 Tier 1 输出 `trigger == true` 时，瞬间唤醒 Tier 2；
- **模型配置**：
  - **在线主力**：调用极速大模型（Gemini 2.5 Flash / DeepSeek-V3 / Qwen-Turbo），设置 2.0s 严格超时熔断；
  - **离线兜底**：无网络时自动调用本地 **Qwen2.5-1.5B (CoreML)** 兜底，保障机舱与无网络环境下 100% 可用；
- **高智商 System Prompt 规范**：
  ```text
  你是一个显示在 Even G2 智能眼镜上的实时对话副手 (Copilot)。
  【佩戴者背景与立场】
  - 会话主题: \(priors.topic)
  - 我方立场: \(priors.myRole)
  - 核心诉求: \(priors.goal)
  - 绝不让步的底线: \(priors.bottomLines.joined(separator: "; "))
  - 对方身份与风格: \(priors.counterparty)
  - Tier 1 意图识别结果: \(tier1Intent)
  
  【物理显示与输出约束】
  1. 佩戴者正在与对方眼神交汇，严禁生成长篇讲话稿！
  2. 输出严格 JSON 格式:
  {
    "title": "[💡策略] 动宾短语",    // 必须 ≤ 12 个汉字！作为顶部圆角胶囊
    "detail": "1.要点一\n2.要点二",  // ≤ 40 汉字，触控展开提纲
    "whisper": "口语化幕僚建议",      // 8~15 汉字，供耳机私密播报
    "category": "strat"             // "fact" / "strat" / "warn"
  }
  ```

---

### 5.4 双层模型级联调度实现 (`ConversationTriggerScheduler`)

```swift
class ConversationTriggerScheduler {
    private var silenceTimer: DispatchWorkItem?
    private var lastSuggestionTime: DispatchTime = .now() - .seconds(60)
    
    let cooldownInterval: Double = 10.0
    let turnSilenceThreshold: Double = 0.8
    
    func onUtteranceCommitted(
        speaker: SpeakerRole,
        text: String,
        history: [ConversationUtterance],
        priors: MeetingContextPriors,
        onSuggestionReady: @escaping (CopilotSuggestion) -> Void
    ) {
        // 规则 1: 自己说话坚决不安静打扰
        if speaker == .me {
            silenceTimer?.cancel()
            silenceTimer = nil
            return
        }
        
        // 规则 2: 冷却期过滤
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - lastSuggestionTime.uptimeNanoseconds) / 1_000_000_000.0
        guard elapsed >= cooldownInterval else { return }
        
        silenceTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            // 🚀 第一层: 触发端侧毫秒级 Qwen2.5-0.5B CoreML 意图判断 (< 30ms)
            OnDeviceGatekeeperLLM.shared.evaluateIntent(text: text, history: history) { result in
                guard result.shouldTrigger else {
                    NSLog("🤫 [Tier 1 Gatekeeper] 本地模型判定无深层博弈，保持静默")
                    return
                }
                
                NSLog("🎯 [Tier 1 Gatekeeper] 捕获高价值意图: [%@] (紧迫度: %d)，唤醒 Tier 2", result.intent, result.urgency)
                self.lastSuggestionTime = .now()
                
                // 🚀 第二层: 唤醒高智商策略生成引擎 (~200ms)
                ConversationAIService.shared.generateSuggestion(
                    history: history,
                    priors: priors,
                    tier1Intent: result.intent
                ) { suggestion in
                    guard let suggestion = suggestion else { return }
                    onSuggestionReady(suggestion)
                }
            }
        }
        silenceTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + turnSilenceThreshold, execute: timer)
    }
}
```

### 5.8 视口与耳机协同消费流水线

当 `ConversationAIService` 返回 `CopilotSuggestion` 后，`ConversationCopilotManager` 执行全链路消费下发：
1. **视口推送**：调用 `pushAIPrompt(rawTitle: suggestion.title, detail: suggestion.detail)`；
   - 构造原生 `0x0B-20` Tag 7 协议包（`card_type=4` 圆角卡片），带入递增 `seq` 与时间戳；
   - 下发 `5A 00` (Tag 11) 触发显存锁存提交，视口瞬时平滑渲染；
2. **耳机耳语推送**：
   - 提取 `suggestion.whisper`（8~15 字口语）；
   - 调用 `audioWhisperManager.speakPrompt(suggestion.whisper)`；
   - 触发高保真预合成防抖缓冲推流，耳机内响起无毛刺的贴身提醒；
3. **自愈渐隐与抽屉归档**：
   - 胶囊卡片推入 20 槽位 FIFO 历史镜像抽屉（支持镜腿 Touchpad 滑动回溯翻看）；
   - 设定 5.0 秒自隐定时器，超时自动发送空串清除指令恢复视口通透，进入下一轮对话监听。

---

## 6. 多模态交互与手势解耦

### 6.1 触控手势路由隔离
- **镜腿 Touchpad 单击/双击**：**展开或关闭当前顶部 AI 提示胶囊**（Detail 展开/折叠）；
- **镜腿 Touchpad 前后滑动**：**回溯翻看历史提示卡片堆栈**（`HistoryIndex +/- 1`）；
- **底部视口完全静默**：手势操作时，底部视口的实时语音听写**绝对不被打断**，持续在后台更新；
- **长按镜腿**：退出对话模式，发送 `Service 0x80-00 Render Commit`。

---

---

## 7. iOS Gateway 核心代码实施清单

| 模块分层 | 目标文件路径 | 改动类型 | 职责说明 |
| :--- | :--- | :--- | :--- |
| **建议数据模型** | `.../Models/CopilotSuggestionModels.swift` | **新增** | 定义 `MeetingContextPriors`、`CopilotSuggestion`、`GatekeeperResult` 与建议类型枚举 |
| **端侧守门人 (Tier 1)** | `.../Services/OnDeviceGatekeeperLLM.swift` | **新增** | **端侧轻量小模型守门**：iPhone 16 Pro Max A18 Pro (ANE) 运行 4-bit 量化 Qwen2.5-0.5B CoreML，<30ms 识别潜台词/隐性施压，彻底替代死板正则 |
| **策略中枢 (Tier 2)** | `.../Services/ConversationAIService.swift` | **新增** | **高智商策略大模型生成**：极速 Flash/DeepSeek（本地 1.5B 离线兜底），结合底线诉求输出 ≤12 字圆角胶囊与 8~15 字防抖耳语 |
| **双层级联调度器** | `.../Services/ConversationTriggerScheduler.swift` | **新增** | 800ms 话轮停顿静音感知、10s 冷却防刷；触发 Tier 1 判决，判定命中时级联唤醒 Tier 2 并传递意图上下文 |
| **提示抽屉镜像** | `.../Services/AICopilotPromptManager.swift` | **优化** | 20 槽位 FIFO 历史镜像抽屉、8~12 字微标签安全截断与触控展开同步 |
| **耳机耳语播报** | `.../Audio/AudioWhisperPromptManager.swift` | **优化** | 耳机接入自适应感知、离线整句预合成防抖缓冲推流（彻底消除 5.3ms 硬件下溢毛刺） |
| **说话人分离** | `.../Audio/DualTrackSpeakerDetector.swift` | **完善** | 单眼镜物理近场能量门限、桌面 CoreMotion 自适应休眠与双轨判别 |
| **协议编码层** | `.../Services/G2ProtocolEncoder.swift` | **完善** | 原生 `0x0B-20` 协议封装：Tag 7 圆角边框胶囊、Tag 8 实时字幕打字流与 Tag 11 显存刷新 |
| **对话总控调度** | `.../Services/ConversationCopilotManager.swift` | **完善** | **核心总调度**：串联 ASR、双轨说话人、调度器、AIService、G2 视口下发与耳机耳语消费 |
| **网关前端交互** | `.../Views/ConversationCopilotView.swift` | **优化** | SwiftUI 界面，呈现 HUD 数字孪生、双麦波形、防抖缓冲设置、发音人切换与抽屉面板 |

---

## 8. 官方 APP 蓝牙抓包实操指南与逆向实证成果 📋

为了在自研网关中 100% 精确还原官方 App 的真实帧结构与指令字，项目组已在 iPhone 16 Pro Max 实机环境下通过 Apple 官方开发者工具 **PacketLogger** 完成了全套逆向抓包与真机报文解密。

### 8.1 已沉淀归档的测试抓包数据集 (`tests/`)

| 抓包文件路径 | 测试场景与动作 | 核心逆向实证结论 |
| :--- | :--- | :--- |
| `tests/对话模式_无AI提示.pklg` | 仅开启对话模式，单向/双工说话，无 AI 提示 | 证实原生对话模式由 **`Service 0x0B-20`** 统管；底部字幕打字流使用 **Tag 8** (`ConversateTranscript`)，`is_final` 负责原地打字与滚屏 |
| `tests/对话模式_有AI提示.pklg` | 对方发言完毕后，官方 App 触发并弹出 AI 建议 | **重大突破**：锁定顶部圆角胶囊卡片使用 **Tag 7** (`ConversateAIPrompt`)，`card_type=4` 触发圆角框，`title` 展示建议，`5A 00` (Tag 11) 触发 VRAM 提交 |
| `tests/对话模式_有AI提示_有展开提示操作.pklg` | 顶部胶囊弹出后，佩戴者在镜腿 Touchpad 上点击展开 | 证实 Touchpad 中断在 `5402` 上报手势码，卡片从单行胶囊平滑展开展示 `detail` 文本要点 |
| `tests/翻译模式_中译英.pklg` | 实时同传翻译模式 | 证实翻译模式走 **`Service 0x05-20`**，上屏为目标语言，下屏为源语言，由 Tag 4 (`TranslationSentence`) 驱动 |

### 8.2 抓包自动化验证脚本工具箱 (`scripts/`)
- `scripts/parse_conversation_pklg.py`：解析 `.pklg` 文件并按 Service ID/Tag 自动解密 Protobuf 载荷；
- `scripts/dissect_0b_packets.py`：深入拆解 `0x0B-20` 每一帧的 Protobuf 序列化细节与 Tag 分布；
- `scripts/test_conversate_ai_capsule.py`：向真机甚至模拟端注入 Tag 7 胶囊卡片，验证圆角卡片渲染；
- `scripts/test_dual_viewport_coexistence.py`：双视口共存压力测试，验证高频打字流与顶部卡片互不干扰。
