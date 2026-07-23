# Even G2 智能眼镜 - 智慧课堂配套应用 (Smart Glass Classroom Assistant)

基于 Even G2 智能眼镜开发的智慧课堂配套辅助系统。

## 主要功能
1. **幻灯片逐字稿/演讲提示同步**：在 Even G2 智能眼镜绿光 HUD 屏幕上实时显示当前 Slide 对应的演讲提纲与逐字稿。
2. **服务端翻页与指令控制**：通过智能眼镜触控/戒指向智慧课堂服务端发送上一页/下一页控制指令，实现讲课过程中的无感控屏与提示。
3. **实时课堂互动提醒**：接收智慧课堂服务端的抢答、投票、课堂倒计时提醒与消息通知。

## 架构简述
- **Mobile / Gateway App (Flutter / React Native / Web)**: 建立与智慧课堂服务端（FastAPI / WebSockets）的连接，同时通过 BLE/SDK 与 Even G2 智能眼镜保持通信。
- **Smart Glass UI Display Adapter**: 针对 Even G2 单色 Micro-LED / 绿色 HUD 显存特点进行单行/多行文本截断、高对比度排版与自动滚屏适配。

## 开发与规划
详见项目规划说明书及需求设计文档。
