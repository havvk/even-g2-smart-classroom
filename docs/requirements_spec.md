# Even G2 智能眼镜 - 智慧课堂配套应用 需求规格与架构规划说明书

## 1. 项目背景与目标
本系统面向使用 **Even G2 智能眼镜** 的授课教师，解决在智慧课堂授课过程中脱离电脑台/翻页笔、免视大屏即可掌握讲义逐字稿与控制翻页的需求。

---

## 2. 核心功能规范

### 2.1 翻页消息控制 (Page Turn Control)
- **手势与按键触发**：支持 Even G2 镜腿 Touchpad 上滑/下滑、Smart Ring 单击/双击手势。
- **消息路由**：眼镜手势 -> BLE -> 移动端 Gateway -> WebSocket (`PAGE_CONTROL`) -> 智慧课堂服务端 -> 广播大屏 (`BS`)。
- **低延迟保证**：全链路响应延时必须小于 **200ms**。

### 2.2 幻灯片逐字稿与 HUD 显存同步 (Teleprompter Sync)
- **逐字稿关联**：智慧课堂 Slide Manager 将每页 PPT/Marp 的讲义逐字稿 (Script) 与核心要点 (Bullets) 预索引。
- **动态切片引擎**：鉴于 Even G2 绿光 Micro-LED 显示限制（每屏最多 3 行，每行 18 字符），移动端 Gateway 对推送文本进行智能断句与自动/手动滚屏切片。
- **状态恢复**：支持网络断开重连后自动拉取当前 Slide 的逐字稿位置。

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
  "timestamp": 1784783900
}
```

### 3.2 逐字稿同步 (`TELEPROMPTER_SYNC`)
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
  "script_text": "同学们好，今天我们进入第二十四讲..."
}
```

---

## 4. 软件模块架构

1. **`smart-glass-mobile-gateway`**
   - 移动端 Bridge 桥接应用（手机端后台服务）。
   - 负责 Even G2 BLE 连接管理、触摸手势解调、HUD 显存排版切片、WebSocket 保持连接。
2. **`smart-classroom-teleprompter-plugin`**
   - 智慧课堂 FastAPI 服务端插件/扩展模块。
   - 维护 Session 页码、幻灯片逐字稿数据映射与广播机制。
