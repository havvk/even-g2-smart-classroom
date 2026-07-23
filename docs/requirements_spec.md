# Even G2 智能眼镜 - 智慧课堂配套应用 需求规格与架构规划说明书

## 1. 项目背景与技术路线
本系统面向使用 **Even G2 智能眼镜** 的授课教师，基于 **“语音页内跟随 + 多模态控屏翻页（眼镜触控 / Apple Watch 替代戒指）+ 显存休眠快速唤醒”** 的融合技术路线，解决脱离电脑台/翻页笔、免视大屏即可掌握讲义逐字稿并精确控制翻页的需求。

---

## 2. 核心功能规范

### 2.1 语音页内跟随 (Voice-Driven In-Slide Auto Scroll)
- **实时音频流匹配**：Mobile Gateway 捕获教师讲话音频流（ASR），通过模糊滑动窗口算法与当前 Slide 的 `script_text` 进行实时定位。
- **HUD 自动平滑滚屏**：确保教师当前正在讲述的句子保持在 Even G2 绿光 HUD 的中央高亮区。
- **脱稿降级机制**：若检测到连续 5 秒未匹配到逐字稿（如老师脱稿解说或回答学生提问），HUD 自动平滑降级显示当前 Slide 的核心提纲 (Bullet Points)。

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

## 3. 双向通信 JSON 协议

### 3.1 翻页与设备控制请求 (`PAGE_CONTROL`)
```json
{
  "type": "PAGE_CONTROL",
  "session_id": "sess_20260723_01",
  "action": "NEXT", // "NEXT" | "PREV" | "JUMP" | "SLEEP_HUD" | "WAKE_HUD" | "TRIGGER_AI_CHAT" | "TOGGLE_TRANSCRIBE"
  "trigger_source": "WATCH_DOUBLE_TAP", // "RING_CLICK" | "TOUCHPAD_SWIPE" | "VOICE_KEYWORD" | "WATCH_DOUBLE_TAP" | "WATCH_CROWN" | "WATCH_WRIST_FLICK" | "WATCH_POWER_TOGGLE" | "WATCH_AI_BUTTON"
  "timestamp": 1784783900
}
```

### 3.2 逐字稿与关键词同步 (`TELEPROMPTER_SYNC`)
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
