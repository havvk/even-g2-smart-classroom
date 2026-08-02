# Even G2 智能眼镜 - 智慧课堂配套应用 用户验收方案 (User Acceptance Plan)

本方案旨在指导用户完成 **Even G2 智能眼镜与智慧课堂配套应用 (Smart Glass Gateway)** 的全功能验收，重点涵盖 **物理协议与算法自动化测试套件**、**本地 iOS/watchOS App 与 G2 眼镜 BLE 蓝牙硬件通讯**、**眼镜滑动文本位置 (0x0601) 实时回传解调** 以及 **Apple Watch 多模态手势与 HUD 显存休眠/唤醒** 等模块。

> [!NOTE]
> **当前阶段开发重点**：系统目前已 100% 完成本地 iOS Gateway 与 Even G2 眼镜的 BLE 蓝牙通讯、提词推屏全屏排版对齐、眼镜 Touchpad 位置 Notify 解调及 Apple Watch 交互。**与智慧课堂服务端的 WebSocket 联动功能目前处于第二阶段集成规划中**。

---

## 1. 验收环境准备

- **开发主机**：macOS (已安装 Xcode 16 / VS Code / Python 3.10+)。
- **硬件终端**（如具备）：iPhone (iOS 16+)、Apple Watch (watchOS 9+)、Even G2 智能眼镜（左/右耳）。
- **项目工程**：根目录 `/Users/l.ylive.cn/OneDrive/smart-glass`。

---

## 2. 验收测试步骤与预期结果

### 阶段一：一键运行物理协议与算法自动化测试套件验收

**操作步骤**：
在 Mac 终端中运行以下命令，执行 7 项核心物理协议与算法自动化测试：

```bash
cd /Users/l.ylive.cn/OneDrive/smart-glass
python3 tests/test_g2_protocol.py && python3 tests/test_hud_adapter.py
```

**预期结果**：

- 终端无缝打印 `Ran 5 tests in 0.000s ... OK` 以及 `Ran 2 tests in 0.000s ... OK`。
- 物理 8-Byte Header 格式、CRC16 校验算法、`TeleprompterInit` 全屏参数（`display_width = 59`, `line_height = 567`, `render_mode = 9`）、14 页缓冲区补齐及 `0x0601` 位置 Notification 解压算法 **100% 通过（PASSED）**。

---

### 阶段二：Even G2 硬件 BLE 蓝牙通讯与全屏推屏验收

**操作步骤**：

1. 确保 Even G2 智能眼镜处于蓝牙就绪状态。
2. 在 Mac 终端运行 Python 实测推屏脚本，或通过 Xcode 运行 `SmartGlassGateway` iOS App：
   ```bash
   cd /Users/l.ylive.cn/OneDrive/smart-glass/even-g2-protocol/examples/teleprompter
   python3 teleprompter.py "欢迎参加 2026 年人机协同 Smart Classroom 集体备课会。"
   ```
3. 佩戴 Even G2 智能眼镜观察绿光 MicroLED 屏幕。

**预期结果**：

- 蓝牙成功扫码与连接 (`Even G2_XX_L_YYYYYY`)。
- 经过 Auth $\rightarrow$ DisplayConfig $\rightarrow$ TeleprompterInit $\rightarrow$ 14 页缓冲下发 $\rightarrow$ UI 路由切换，眼镜成功切入全屏顶格排版提词模式。
- 物理镜片首行完整呈现 28 个中文字符，无缩略框、无换行截断、无缺包黑屏。

---

### 阶段三：眼镜向 APP 实时回传文本位置信息 (0x0601 Notify) 验收

**操作步骤**：

1. 启动 iOS App `SmartGlassGateway` 并完成与 Even G2 智能眼镜的蓝牙连接（App 蓝牙模块 `BLEManager` 将在连接成功后**自动开启 Notify 特征订阅使能**）。
2. 在 App 界面下发一段讲稿并开启提词推屏（使眼镜屏幕进入提词视口状态）。
3. 用手指在 Even G2 智能眼镜镜腿 Touchpad 上向上/向下滑动滚屏。
4. 观察 iOS App 界面及控制日志。

**预期结果（2 种直观校验方式）**：

- **校验方式 A（UI 界面直观联动）**：镜腿 Touchpad 滑动时，APP 控制界面上的 **“当前聚焦卡片 (Active Line Card)”**及**“进度定位滑块”** 会与眼镜 HUD 屏幕同步实时平滑跳动更新。
- **校验方式 B（日志控制台解密打印）**：APP 底部【蓝牙控制日志】面板将实时打印高亮解密日志：
  `📩 [G2 位置 Notify] 接收到视口滑动通知: currentLine = 3 (Page 0, RawLine 3)`
  证明 APP 已成功拦截并解调 `Service 0x0601` (`Type 165` / `0xA5`) 数据包。

---

### 阶段四：Apple Watch 多模态手势与 HUD 显存休眠/唤醒验收

**操作步骤与验证清单**：

| 序号          | 验证子项                         | 操作步骤                                                           | 预期结果判定                                                                                                                      |
| :------------ | :------------------------------- | :----------------------------------------------------------------- | :-------------------------------------------------------------------------------------------------------------------------------- |
| **4.1** | **显存快捷休眠/唤醒**      | 点击 Watch 右上角**`👁️`** 图标                           | 图标切换为红色息屏状态，G2 下发`TeleprompterState(state: 4)` 显存瞬间清空息屏；再次点击在 **<100ms 内秒级唤醒恢复显示**。 |
| **4.2** | **捏手指 / 触控切页**      | 点击 Watch 界面【下一页】按键，或双指捏合 Double Tap               | 手表发出`.click` 触觉震动反馈，iPhone 与眼镜 HUD 页码及文本位置平滑切至下一页。                                                 |
| **4.3** | **数字表冠 (Crown) 微调**  | 顺时针/逆时针旋转 Watch 数字表冠                                   | 手表发出线性震动反馈，视口行高亮微调滚动。                                                                                        |
| **4.4** | **手腕甩动 (Wrist Flick)** | 手腕快速向上甩动翻转                                               | 基于 50Hz IMU 比对触发切页，并触发 1.5s 防抖保护拦截连续连发误操作。                                                              |
| **4.5** | **AI对话与转录卡片**       | 点击 Watch 上**`🤖 AI对话`** 或 **`🎤 转录`** 按钮 | 手表发出`.notification` 震动，调起语音监听。                                                                                    |

---

### 阶段五：服务端 WebSocket 联动与交互提醒 (集成规划)

**操作步骤与说明**：

1. 在服务端口运行 FastAPI 服务 (`uvicorn main:app --reload`)。
2. iOS Gateway 连接服务端 `ws://localhost:8000/ws/session/sess_demo`。
3. 验证服务端广播大屏翻页与抢答/投票消息推送。

---

## 3. 验收结论签署

- [ ] **阶段一：物理协议与算法自动化测试** (PASSED)
- [ ] **阶段二：G2 蓝牙硬件通讯与全屏推屏** (PASSED)
- [ ] **阶段三：眼镜位置 0x0601 Notify 解压与同步** (PASSED)
- [ ] **阶段四：Apple Watch 多模态手势与显存休眠** (PASSED)
- [ ] **阶段五：服务端 WebSocket 联动** (规划集中)

**验收人**：\_\_\_\_\_\_\_\_\_\_\_\_
**验收日期**：2026 年 \_\_ 月 \_\_ 日
