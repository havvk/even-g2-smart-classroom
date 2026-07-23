# Even G2 智能眼镜 - 智慧课堂配套应用 (Smart Glass Classroom Assistant)

基于 Even G2 智能眼镜开发的智慧课堂配套辅助系统。

## 快速导航文档
- 📘 [需求规格与架构规划说明书](docs/requirements_spec.md)
- 🛠️ [开发环境准备指南](docs/dev_environment_setup.md)
- 👓 [Even G2 硬件环境准备与连接指南](docs/hardware_setup_guide.md)


## 主要功能
1. **语音页内跟随 & 逐字稿 HUD 显示**：在 Even G2 绿光 HUD 屏幕上显示 Slide 逐字稿，语音识别自动平滑滚屏。
2. **服务端翻页与指令控制**：通过智能眼镜触控/戒指或尾部语音关键词向智慧课堂服务端发送上一页/下一页控制指令，实现大屏同步翻页。
3. **实时课堂互动提醒**：接收智慧课堂服务端的抢答、投票、课堂倒计时提醒与消息通知。


## 架构简述
- **Mobile / Gateway App (Flutter / React Native / Web)**: 建立与智慧课堂服务端（FastAPI / WebSockets）的连接，同时通过 BLE/SDK 与 Even G2 智能眼镜保持通信。
- **Smart Glass UI Display Adapter**: 针对 Even G2 单色 Micro-LED / 绿色 HUD 显存特点进行单行/多行文本截断、高对比度排版与自动滚屏适配。

## 开发与规划
详见项目规划说明书及需求设计文档。
