# Even G2 智能眼镜 - 智慧课堂配套应用 用户验收方案 (User Acceptance Plan)

本方案旨在指导用户一步步完成 **Even G2 智能眼镜与智慧课堂配套应用** 的全功能验收，涵盖自动化测试、服务端 WebSocket 通信、iOS 显存模拟器、Apple Watch 多模态手势及语音跟随等 5 大模块。

---

## 1. 验收环境准备

- **开发主机**：macOS (已安装 Xcode 16 / VS Code / Python 3.10+)。
- **硬件终端**（如具备）：iPhone/iPad (iOS 16+)、Apple Watch (watchOS 9+)、Even G2 智能眼镜。
- **项目工程**：根目录 `/Users/l.ylive.cn/OneDrive/smart-glass`。

---

## 2. 验收测试步骤与预期结果

### 阶段一：一键运行自动化测试套件验收

**操作步骤**：
在 Mac 终端中运行以下命令，执行 8 项自动化测试用例：
```bash
cd /Users/l.ylive.cn/OneDrive/smart-glass
python3 -m unittest discover -s server_plugin/tests -p "test_*.py" && python3 -m unittest discover -s tests -p "test_*.py"
```

**预期结果**：
- 终端打印 `Ran 6 tests ... OK` 以及 `Ran 2 tests ... OK`。
- 所有 8 项测试用例 **100% 通过（PASSED）**，无报错。

---

### 阶段二：智慧课堂 FastAPI 服务端验收

**操作步骤**：
1. 在 Mac 终端运行：
   ```bash
   cd /Users/l.ylive.cn/OneDrive/smart-glass/server_plugin
   uvicorn main:app --reload --port 8000
   ```
2. 打开浏览器访问 `http://localhost:8000/docs`。
3. 测试 `GET /api/session/sess_demo/info` 接口。

**预期结果**：
- Swagger 页面正常加载，`GET /api/session/sess_demo/info` 返回 200 OK。
- 返回 JSON 包含 `type: "TELEPROMPTER_SYNC"`、`current_page: 1`、`total_pages: 3` 以及第一页逐字稿内容。

---

### 阶段三：iOS App 网关与绿光 HUD 显存视图验收

**操作步骤**：
1. 在 VS Code 中打开项目，按下快捷键 **`⌘Shift+B`**（或菜单栏 *Terminal -> Run Build Task*）。
2. 选择 **`3. 部署并运行 iOS 应用到模拟器`**。
3. 模拟器启动后打开 **SmartGlassGateway** 应用：
   - 观察顶部绿色 **Even G2 绿光 HUD 模拟显存视口**；
   - 在“智慧课堂服务端”卡片中输入 `ws://localhost:8000/ws/session/sess_demo` 并点击【连接智慧课堂服务端】；
   - 点击底部【下一页 (NEXT)】按钮。

**预期结果**：
- HUD 视口正确呈现 520nm 绿光高对比度 3 行文本（第一行为 `[P01/03] 签到 42/45` 状态栏，第二行为高亮讲述行，第三行为下一行预告）。
- 点击【下一页】后，界面与服务端同步切换至 `P02/03`，标题更新为 *"HOTL 实战——指挥 AI 完成结构化预测任务"*。

---

### 阶段四：Apple Watch 多模态手势与显存休眠/唤醒验收

**操作步骤与验证清单**：

| 序号 | 验证子项 | 操作步骤 | 预期结果判定 |
| :--- | :--- | :--- | :--- |
| **4.1** | **显示快捷休眠/唤醒** | 点击 Watch 右上角 **`👁️`** 图标 | 图标切换为红色息屏状态，HUD 视口显存瞬间清空息屏；再次点击按钮在 **<100ms 内秒级恢复激活**。 |
| **4.2** | **捏手指 / 触控翻页** | 点击 Watch 界面【下一页】按键，或食指拇指捏合两下 | 手表发出 `.click` 震动反馈，iPhone 与大屏页码从 P01 瞬间翻至 P02。 |
| **4.3** | **数字表冠 (Crown) 翻页**| 顺时针旋转 Watch 侧边数字表冠 | 手表发出震动反馈，大屏与眼镜逐字稿顺畅跳页。 |
| **4.4** | **手腕甩动 (Wrist Flick)** | 手腕快速向上甩动翻转（带回弹动作） | 经过 50Hz IMU 比对触发翻页并触发 1.5s 防抖保护，避免连续误触发。 |
| **4.5** | **AI对话与转录快捷触控**| 点击 Watch 上 **`🤖 AI对话`** 或 **`🎤 转录`** 按钮 | 手表发出 `.notification` 震动，触发 ASR 监听开启。 |

---

### 阶段五：语音页内跟随 (ASR Voice-Following) 验收

**操作步骤**：
1. 在 iOS App 界面开启 **【语音识别自动跟随 (ASR)】** 开关（允许麦克风权限）。
2. 面向手机/Mac 朗读逐字稿第一句："*同学们好！今天我们来讲解 Even G2 智能眼镜在智慧课堂中的应用...*"。

**预期结果**：
- ASR 实时文本打印在控制卡片中。
- HUD 模拟显存的高亮行自动向下滚动定位至当前朗读的句子，实现免手扶行聚焦。

---

## 3. 验收结论签署

- [ ] **阶段一：自动化测试** (PASSED)
- [ ] **阶段二：服务端 API 与 WebSocket** (PASSED)
- [ ] **阶段三：iOS App 与 HUD 显存** (PASSED)
- [ ] **阶段四：Apple Watch 多模态手势与显存休眠** (PASSED)
- [ ] **阶段五：语音页内跟随** (PASSED)

**验收人**：\_\_\_\_\_\_\_\_\_\_\_\_  
**验收日期**：2026 年 \_\_ 月 \_\_ 日
