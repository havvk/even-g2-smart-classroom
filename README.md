# Even G2 智能眼镜 - 智慧课堂配套应用 (Smart Glass Classroom Assistant)

基于 Even G2 智能眼镜开发的智慧课堂配套辅助系统。

## 当前开发进度说明
> [!NOTE]
> 目前项目已完成 **本地 iOS Gateway 与 Even G2 智能眼镜的 BLE 蓝牙通讯**（包括协议解密、逐字稿推送、Apple Watch 多模态手势控制及 HUD 显存休眠唤醒）。
> **与智慧课堂服务端的连接与联动功能目前尚未集成，正在规划实现中。**

## 快速导航文档
- 📘 [需求规格与架构规划说明书](docs/requirements_spec.md)
- 🛠️ [开发环境准备指南](docs/dev_environment_setup.md)
- 👓 [Even G2 硬件环境准备与连接指南](docs/hardware_setup_guide.md)
- 📋 [用户验收方案与操作步骤](docs/user_acceptance_plan.md)

## 主要功能
1. **本地 BLE 通讯与逐字稿 HUD 推送**：建立 iOS 网关与 Even G2 智能眼镜的蓝牙连接，下发提词逐字稿并在绿光 HUD 屏幕上显示。
2. **多模态手势与设备控制**：支持通过 Apple Watch（捏手指 Double Tap、表冠、手腕甩动）及眼镜触控板控制切页与 HUD 显存休眠/唤醒。
3. **语音跟随与关键词切页（本地逻辑）**：基于本地语音识别算法实现逐字稿平滑滚屏与尾部关键词切页。
4. **服务端集成（规划中）**：后续将集成与智慧课堂服务端（FastAPI/WebSocket）的连接，实现大屏同步翻页与互动提醒（抢答/投票/倒计时）。

## 架构简述
- **Mobile / Gateway App (iOS / Swift / watchOS)**: 负责管理与 Even G2 智能眼镜的 BLE 蓝牙连接及数据帧交互，接收 Apple Watch 手势控制指令并处理本地语音跟读。
- **Smart Glass UI Display Adapter**: 针对 Even G2 单色 Micro-LED / 绿色 HUD 显存特点进行单行/多行文本截断、高对比度排版与自动滚屏适配。
- **Server Plugin (规划集成中)**: 智慧课堂服务端插件（Python/FastAPI），后续用于处理会话同步与大屏 WebSocket 控制。

## 开发与规划
详见项目规划说明书及需求设计文档。
