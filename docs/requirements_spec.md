# Even G2 智能眼镜 - 智慧课堂配套应用 需求规格与架构规划说明书

## 1. 项目背景与技术路线
本系统面向使用 **Even G2 智能眼镜** 的授课教师，基于 **"自研 AI 语音跟随 + 多模态控屏翻页（眼镜触控 / Apple Watch 替代戒指）+ 显存休眠快速唤醒"** 的融合技术路线，解决脱离电脑台/翻页笔、免视大屏即可掌握讲义逐字稿并精确控制翻页的需求。

> ⚠️ **自研 AI 模式动因**：官方 Even AI APP 的 AI 跟随模式 (`scroll_mode = 1`) 在实际课堂使用中存在**频繁失灵**问题——表现为运行一段时间后语音匹配引擎停止响应，提词文本不再滚动，需要手动操作恢复。该缺陷在连续授课场景下严重影响教学体验，因此决定自研基于本地/边缘 ASR + 模糊匹配的语音跟随引擎。

> 💡 **技术选型**：采用 Apple on-device Speech 框架作为 ASR 引擎，利用 iOS 端侧推理能力实现零网络延迟的实时语音识别，配合自研模糊滑动窗口匹配算法完成文本定位。该方案不依赖官方 APP 的黑盒 ASR 通道，可完全控制匹配策略与降级逻辑。

---

## 2. 核心功能规范

### 2.1 自研 AI 语音跟随 (Self-developed Voice-Driven Auto Scroll)

#### 2.1.1 官方 AI 模式已知缺陷
| 缺陷 | 现象 | 影响 |
|------|------|------|
| ASR 匹配引擎超时失灵 | 运行数分钟后语音匹配停止响应，提词文本冻结不再滚动 | 课堂中途需手动操作恢复，严重打断教学节奏 |
| 无降级机制 | 匹配失败后无任何 Fallback，HUD 完全静止 | 教师无法判断系统状态，丧失对讲稿的位置感知 |
| 黑盒不可调试 | ASR 与匹配逻辑封闭在官方 APP 内，无日志与诊断接口 | 无法定位失灵根因，无法优化匹配策略 |

#### 2.1.2 自研方案核心能力
- **实时音频流匹配**：Mobile Gateway 基于 iOS `Speech` 框架 (Apple on-device ASR) 捕获教师讲话音频流，通过模糊滑动窗口算法与当前讲稿 `script_text` 进行实时定位。
- **HUD 自动平滑滚屏**：匹配成功后，通过 `0x06-20 Type 165 ScrollSync` 下发视口滚动指令，确保教师当前正在讲述的句子保持在 Even G2 绿光 HUD 的中央高亮区。
- **脱稿降级机制**：若检测到连续 5 秒未匹配到逐字稿（如老师脱稿解说或回答学生提问），HUD 自动平滑降级显示当前 Slide 的核心提纲 (Bullet Points)。
- **可观测性**：匹配过程全链路日志输出（ASR 文本、匹配得分、候选窗口位置），支持实时调试与事后复盘。

#### 2.1.3 与官方 AI 模式的关系
- **完全替代，非并存**：自研语音跟随引擎将完全替代官方 AI 模式 (`scroll_mode = 1`)，不依赖官方 APP 的 ASR 通道。
- **协议层复用**：底层 HUD 滚动指令仍复用 `0x06-20 Type 165 ScrollSync` 帧协议（与官方一致），确保 MicroLED 显示兼容性。
- **官方 APP 保留为降级方案**：若自研引擎遇到不可预期的硬件兼容问题，可临时回退使用官方 APP 的 Manual 模式 (`scroll_mode = 0`)。

### 2.2 多模态翻页与控制消息 (Multi-modal Page & Device Control)
系统支持三种外设手势源接入，发出的 WebSocket 消息要求在 **< 150ms** 内驱动教室大屏翻页或响应硬件动作：

1. **Apple Watch 替代官方指环 (Smart Ring Alternative)**：
   - **方式 1（捏手指 Double Tap / AssistiveTouch）**：捏合双指触发大屏翻页，误触率最低。
   - **方式 2（数字表冠 Digital Crown）**：顺时针/逆时针扭动表冠微调逐字稿行高亮与翻页。
   - **方式 3（CoreMotion 手腕甩动 Wrist Flick）**：基于 50Hz IMU 角速度与加速度回弹比对算法（带 1.5s 防抖冷却），手腕快速向上甩动触发翻页。
   - **快捷触发 AI 对话与实时转录**：手表端提供 `🤖 AI对话` 与 `🎤 实时转录` 快捷触控卡片，100% 替代官方物理戒指的按键功能。
   - **watchOS 表盘组件 (Watch Complications)**：支持在 Apple Watch 表盘直接添加一键唤醒图标。
   - **Taptic Engine 震动**：手表接收到任何手势触发成功后，发出 `.click` 触觉震动反馈。
2. **Even G2 HUD 显存休眠与秒级激活 (Display Sleep / Fast Wake)**：
   - 支持在 Apple Watch （点击 `👁️` 按钮）或 iPhone 上一键发送 `SLEEP_HUD` / `WAKE_HUD` 指令。
   - 课间或暂时无需看稿时进入息屏休眠状态（极度省电且无绿光干扰）；讲课时点击**秒级瞬间激活显示**。
3. **Even G2 镜腿 Touchpad / 物理手势**：
   - 镜腿 Touchpad 上滑/下滑。
4. **尾部关键词自动翻页**：
   - 解析逐字稿末尾关键词（如 *"下面来看下一张"*），ASR 命中且置信度 $>0.85$ 时自动触发翻页。

### 2.3 课堂互动与提醒 (HUD Notification)
- **签到状态提醒**：如 `[签到] 已到 42/45 人`。
- **随堂测试与倒计时**：如 `[投票中] 剩余 01:30`。

---

### 2.4 Even G2 官方 App 提词功能与 UI 结构深度解析

根据对官方 iOS 客户端的逆向分析与 UI 界面架构拆解，官方提词器功能由**讲稿管理列表**与**讲稿预览控制台**两大核心视图构成：

```mermaid
graph TD
    A["提词器 App (Teleprompter Hub)"] --> B["1. 讲稿管理列表 (List View)"]
    A --> C["2. 讲稿预览控制台 (Preview View)"]
    
    B --> B1["讲稿卡片列表 (标题/修改时间)"]
    B --> B2["排序与检索 (更新日期/升降序)"]
    B --> B3["[+] 新建 (纯文本创建)"]
    B --> B4["[↓] 导入 (TXT/Word/PDF)"]
    
    C --> C1["模式选择器 (AI 跟随 / Auto 匀速 / Manual 手动)"]
    C --> C2["可视化视口 (中央焦点卡片 / 上下非焦点行降低对比度)"]
    C --> C3["进度控制条 (首页重置 / 滑块定位 / 视口缩放)"]
    C --> C4["[✎] 编辑讲稿"]
    C --> C5["[→] 开始 (蓝牙 5 阶段推屏)"]
```

#### 1. 讲稿管理列表视图 (Teleprompter List View)
- **讲稿元数据卡片**：展示讲稿标题（如 *“人机协同程序设计课程建设思路_演讲版_逐字稿”*）、最后修改时间（如 *`2026/07/24 22:48`*）及一键进入预览的导航箭头 `>`。
- **排序与筛选机制**：支持按“更新日期”等维度进行下拉筛选，并提供正序/倒序一键切换与记录总数统计（如 *`3 记录`*）。
- **快捷导入与创建**：
  - `[+] 新建`：直接调起内嵌编辑器输入或粘贴演讲文本。
  - `[↓] 导入`：支持从本地 Files / 云盘导入外部文档（TXT、Word、PDF 等）。

#### 2. 讲稿预览与控制台视图 (Teleprompter Preview View)
- **多模态滚动模式选择器 (Mode Selector Dropdown)**：
  - **AI 模式 (`scroll_mode = 1`)**：基于实时语音识别（ASR）与文本滑动窗口算法，按教师当前讲述位置自动进行视口平滑滚动。
  - **Auto 模式 (匀速滚屏)**：设定固定时间速率自动向上滚屏。
```json
{
  "type": "TELEPROMPTER_SYNC",
  "session_id": "sess_20260723_01",
  "current_page": 6,
  "total_pages": 24,
  "slide_title": "HOTL 实战 - 指挥 AI 完成结构化预测任务",
  "bullet_points": [
    "1. 声明式 Prompt 与结构化 Output 约束",
    "2. Schema 校验失败时的重试机制"
  ],
  "script_text": "同学们好，今天我们进入第二十四讲...",
  "end_keywords": ["下一张幻灯片", "进入下一节", "来看这个案例"]
}
```

---

## 4. 软件模块架构

1. **`mobile_gateway_ios` (iOS & watchOS 手机/手表网关)**
   - **SmartGlassGateway (iPhone App)**：
     - BLEManager：包含 `sleepHUD()` 与 `wakeHUD()` 显存休眠/激活控制器。
     - SpeechFollowEngine：语音识别与逐字稿比对。
     - WatchSessionManager：管理 Apple Watch 消息解调。
   - **SmartGlassWatch (watchOS Extension)**：
     - 支持 Double Tap 捏手指、Digital Crown 表冠、CoreMotion 手腕甩动、显存快捷开关 `👁️`、`🤖 AI对话` 与 `🎤 实时转录` 卡片。
2. **`server_plugin` (智慧课堂服务端插件)**
   - 维护 Session 页码、幻灯片逐字稿与尾部关键词数据映射。
   - 提供 WebSocket 翻页广播与状态分发机制。

---

## 5. Even G2 物理通信层协议与发包控制规范 (v2.0.0 规范)

### 5.1 1:1 物理点灯与初始化序列 (Setup Sequence)
推送提词界面时，必须严格按顺序下发以下 Setup 指令帧，完成显存布局与光机供电：
1. **Auth 绑定 (0x80-00 / 0x80-20)**：下发 7 包验证安全会话；
2. **视口参数 (0x07-20)**：`08 0A 10 08 6A 06 08 00 10 50 20 00`；
3. **画布布局 (0x03-20)**：定义 10 行文本阵列网格结构；
4. **显存通道与光机供电 (0x0C-20)**：`08 02 10 msgId 22 04 08 01 10 00`；
5. **系统模式与 MicroLED 点灯 (0x30-20)**：`08 01 10 msgId 1A 04 08 01 10 00`；
6. **触控中断解绑定 (0x01-20)**：`22 0C 1A 0A 12 08 1A 06 08 00 10 00 20 01` (`20 01` 使能镜腿滑动中断)；
7. **【关键禁令】绝不发送 22 02 08 01**：Setup 中严禁包含切回 Dashboard (`0x01`) 的指令，保证路由直通 `0x52 Teleprompter` 显存。

### 5.2 发包序号单调递增 (Strict Monotonic Sequence)
- **`seq` 字节与 `msgId` 约束**：从 `0x00` 起始，全量 Protobuf 帧的 `seq` 必须严格单调自增（`0, 1, 2, 3...`），严禁出现静态硬编码序号倒跳；
- **回环保护**：`seq` 达到 255 后，使用 `seq = (seq + 1) & 0xFF` 进行显式溢出回环保护。

### 5.3 120ms 物理发包间隔平滑保护 (Inter-packet Pacing)
- **物理平滑节奏**：两包 `Tx` 发送物理间隔**不得少于 120ms**（收到 ACK 后延时 80ms~120ms 步进）；
- **死锁防护**：严禁在 20ms~30ms 内高频连发爆破，防止撑爆 G2 蓝牙 RX Buffer 引发 MicroLED 显像芯片保护性死锁熄灭（黑屏）。

---

## 6. 系统健壮性与“推送新文本”架构规范

```mermaid
flowchart TD
    A["推送新文本请求 (Push New Text)"] --> B{"眼镜当前状态判断"}
    
    B -- "状态 A: 全新讲稿 / 未在提词模式" --> C["全量覆盖流程 (Full Refresh)"]
    B -- "状态 B: 已在提词模式 / 需更新文本" --> D["快速 Session 轮转 (Fast Session Rotation)"]
    
    C --> C1["1. 取消挂起 Lock-Step 队列"]
    C1 --> C2["2. 下发 State=4 Session 释放包"]
    C2 --> C3["3. 150ms 强制物理平滑冷却"]
    C3 --> C4["4. 重置 seq=0x00，下发 Setup + 全量 Pages"]
    C4 --> C5["5. 重置视口至 Line 0"]
    
    D --> D1["1. 下发 State=4 释放当前 Session"]
    D1 --> D2["2. 等待 0x0D-01 Session Terminated 确认"]
    D2 --> D3["3. 150ms 物理平滑冷却"]
    D3 --> D4["4. 重置 seq=0x00，下发完整 Setup + 新文本 Pages"]
    D4 --> D5["5. HUD Mount + Viewport Flush (视觉感知 < 200ms)"]
```

### 6.1 双模式推送新文本处理规范

#### 1. 模式 A：全量讲稿覆盖 (Full Text Replacement)
- **触发条件**：用户选择全新的讲稿文件，或者系统强制重置演讲。
- **处理步骤**：
  1. 调用 `cancelPendingTeleprompterTasks()` 清空挂起队列与超时定时器；
  2. 下发 `Service 06-20 type=4 state=4` 释放包，清空 SRAM 环形缓冲区；
  3. 执行 **150ms 强制物理平滑冷却**；
  4. 重置 `seq = 0x00`，下发全量 Setup 指令帧与 Content Pages，完成重新挂载。

#### 2. 模式 B：快速 Session 轮转更新 (Fast Session Rotation Refresh)
- **触发条件**：眼镜处于提词模式下，需要更新文本内容（如 AI 语音跟随触发翻页后加载下一段逐字稿，或 WebSocket 接收到新文本）。
- **关键约束 (经 §23.2 验证)**：Even G2 MCU **不支持在活跃 Session 内直接覆写或追加文本**——不存在"预填充后台 Buffer 再翻转"的能力。切换文本的唯一路径是完整的 **Session 销毁→重建闭环**。
- **处理步骤**：
  1. 下发 `Service 06-20 type=4 state=4` 释放当前 Session；
  2. 等待眼镜 MCU 返回 `0x0D-01 Session Terminated` 确认（物理注销完成）；
  3. 执行 **150ms 物理平滑冷却** 窗口；
  4. 重置 `seq = 0x00`（MCU 在 Session Terminated 后会重置 Seq 计数器），下发完整 Setup + 新文本 Pages；
  5. 下发 `HUD Mount (0x04-20)` 与 `Viewport Flush Line 0 (0x06-20 Type 165)` 完成挂载。
- **效果**：虽然经历 Session 销毁→重建，但因 150ms 窗口极短，视觉上用户感知接近无缝（MicroLED 亮度变化 < 200ms）。

---

### 6.2 系统 4 大防线健壮性设计规范

1. **并发锁与防抖机制 (Anti-Reentrancy & Debounce)**
   - 引入 `isPushingText` 并发锁，防止多源（WebSocket / UI 快速点击）并发冲撞；
   - 针对高频实时文本流增加 **300ms 防抖 (Debounce)**，确保发包队列的有序性。
2. **`UInt8` 序号回环保护 (Sequence Rollover Protection)**
   - 在长时演讲场景下，发包数超过 255 时，使用 `seq = (seq + 1) & 0xFF`，保证 `UInt8` 不溢出 Crash。
3. **蓝牙断开自愈与现场恢复 (BLE Reconnection State Recovery)**
   - 蓝牙重连成功后，App 自动校验 `isTeleprompterSessionActive`；
   - 根据记录的 `currentFocusPageLine` 自动恢复现场，重新下发 Setup + 对应行号，做到**断线无感恢复看屏**。
4. **心跳保活与异常路由拉回 (Heartbeat & Route Auto-Revert)**
   - 处于提词模式时，超过 10 秒无触控操作自动触发 `0x0D-20` 心跳查询；
   - 若发现眼镜 MCU 误切回 Dashboard (`0x32`)，自动下发 `0x09-20` 将路由**拉回 `0x52 Teleprompter`**，保证持续看屏。

---

## 7. 自研 AI 语音跟随架构规划 (Self-developed Voice Following Architecture)

### 7.1 系统架构总览

```mermaid
flowchart LR
    MIC["🎤 iPhone 麦克风"] --> ASR["iOS Speech\n(On-device ASR)"]
    ASR --> |"实时转录文本"| MATCH["模糊滑动窗口\n匹配引擎"]
    SCRIPT["当前 Slide\nscript_text"] --> MATCH
    MATCH --> |"匹配位置 (行号)"| SCROLL["ScrollSync 指令\n生成器"]
    SCROLL --> |"0x06-20 Type 165"| BLE["BLE Manager\n→ Even G2"]
    MATCH --> |"连续 5s 未匹配"| FALLBACK["脱稿降级\n→ Bullet Points"]
    FALLBACK --> BLE
```

### 7.2 核心组件设计

#### 7.2.1 ASR 引擎 (SpeechRecognitionEngine)
- **框架**：iOS `Speech.framework`，使用 `SFSpeechAudioBufferRecognitionRequest` 流式识别
- **模式**：On-device 推理（`requiresOnDeviceRecognition = true`），零网络延迟
- **语言**：`zh-CN` (普通话)，支持运行时切换
- **输出**：实时输出 partial results（`shouldReportPartialResults = true`），每次回调携带累积文本与时间戳

#### 7.2.2 模糊滑动窗口匹配器 (FuzzySlideWindowMatcher)
- **输入**：ASR partial text + 当前 Slide 的 `script_text`
- **算法**：在 `script_text` 上维护一个滑动窗口（窗口大小 = ASR 最近 N 个字），计算窗口内文本与 ASR 输出的编辑距离 / Jaccard 相似度
- **匹配阈值**：相似度 ≥ 0.6 视为匹配成功，更新 `currentMatchPosition`
- **滑动策略**：窗口仅前向滑动（教师不会倒退念稿），降低搜索空间

#### 7.2.3 ScrollSync 指令生成器 (ScrollSyncController)
- 将 `currentMatchPosition`（行号）映射为 `0x06-20 Type 165` ScrollSync 帧的目标行偏移
- 平滑插值：避免跳帧，采用逐行步进下发（每 300ms 最多推进 1 行）
- 与 BLE 发包队列协调：复用 §5.3 的 120ms 物理发包间隔保护

#### 7.2.4 脱稿降级控制器 (DigressionFallbackController)
- **触发条件**：连续 5 秒匹配得分 < 0.3（教师脱稿或回答学生问题）
- **降级行为**：HUD 切换显示当前 Slide 的 `bullet_points`（需要 Session 轮转更新文本，参见 §6 模式 B）
- **恢复机制**：当匹配得分恢复 ≥ 0.6 时，自动切回逐字稿显示并定位到匹配行

### 7.3 数据流时序

```mermaid
sequenceDiagram
    participant MIC as 🎤 Microphone
    participant ASR as Speech Engine
    participant MATCH as Fuzzy Matcher
    participant SCROLL as ScrollSync
    participant BLE as BLE → G2 HUD

    loop 实时语音流
        MIC->>ASR: Audio Buffer (每 100ms)
        ASR->>MATCH: Partial Text + Timestamp
        MATCH->>MATCH: 滑动窗口计算相似度
        alt 匹配成功 (score ≥ 0.6)
            MATCH->>SCROLL: matchPosition (行号)
            SCROLL->>BLE: 0x06-20 Type 165 (目标行)
            BLE->>BLE: 120ms 发包间隔保护
        else 连续 5s 未匹配
            MATCH->>SCROLL: FALLBACK → bullet_points
            SCROLL->>BLE: Session 轮转 → 推送提纲
        end
    end
```

### 7.4 可观测性设计
- **实时日志面板**：iPhone 调试界面展示 ASR 文本、匹配得分、窗口位置的实时滚动日志
- **匹配热力图**：记录每行 script_text 的匹配次数与得分分布，用于事后分析匹配策略有效性
- **性能指标**：ASR → 匹配 → 下发 BLE 的端到端延迟 (Target: < 500ms P95)
