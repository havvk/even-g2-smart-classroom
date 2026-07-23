# Even G2 智能眼镜 - 智慧课堂配套应用 需求规格与架构规划说明书

## 1. 项目背景与技术路线
本系统面向使用 **Even G2 智能眼镜** 的授课教师，基于 **“语音页内跟随 + 手势/按键控屏翻页 + 尾部关键词助推”** 的融合技术路线，解决脱离电脑台/翻页笔、免视大屏即可掌握讲义逐字稿并精确控制翻页的需求。

---

## 2. 核心功能规范

### 2.1 语音页内跟随 (Voice-Driven In-Slide Auto Scroll)
- **实时音频流匹配**：Mobile Gateway 捕获教师讲话音频流（ASR），通过模糊滑动窗口算法与当前 Slide 的 `script_text` 进行实时定位。
- **HUD 自动平滑滚屏**：确保教师当前正在讲述的句子保持在 Even G2 绿光 HUD 的中央高亮区。
- **脱稿降级机制**：若检测到连续 5 秒未匹配到逐字稿（如老师脱稿解说或回答学生提问），HUD 自动平滑降级显示当前 Slide 的核心提纲 (Bullet Points)。

### 2.2 翻页消息控制 (Page Turn Control)
- **显示触控/按键翻页**：支持 Even G2 镜腿 Touchpad 上滑/下滑与配套 Smart Ring 戒指按压信号，主动发出 `PAGE_CONTROL` 消息。
- **尾部关键词自动翻页**：解析逐字稿末尾关键词（如 *"下面来看下一张"*），ASR 命中且置信度 $>0.85$ 时自动触发翻页。
- **全链路响应延时**：按键/手势翻页大屏响应延时控制在 **< 150ms**；语音跟随行高亮延时小于 **300ms**。

### 2.3 课堂互动与提醒 (HUD Notification)
- **签到状态提醒**：如 `[签到] 已到 42/45 人`。
- **随堂测试与倒计时**：如 `[投票中] 剩余 01:30`。

---

## 3. 双向通信 JSON 协议

### 3.1 翻页请求 (`PAGE_CONTROL`)
```json
{
  "type": "PAGE_CONTROL",
  "session_id": "sess_20260723_01",
  "action": "NEXT",
  "trigger_source": "VOICE_KEYWORD", // "RING_CLICK" | "TOUCHPAD_SWIPE" | "VOICE_KEYWORD"
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

1. **`mobile_gateway` (手机端 Gateway Bridge)**
   - **ASR & Line Matcher Engine**：负责语音实时识别与逐字稿比对定位。
   - **HUD Layout & Chunking Adapter**：针对 Even G2 (3行, 18字/行) 进行动态字符切片与滚动。
   - **BLE Connection Manager**：与 Even G2 连接并收发手势与显示帧。
   - **WebSocket Client**：与智慧课堂 FastAPI 服务端保持双向长连接。
2. **`server_plugin` (智慧课堂服务端拓展插件)**
   - 维护 Session 页码、幻灯片逐字稿与尾部关键词数据映射。
   - 提供 WebSocket 翻页广播与状态分发机制。
