# Even G2 智能眼镜 - 智慧课堂配套应用 开发环境准备指南

本指南详细说明搭建 **Even G2 智能眼镜 - 智慧课堂配套应用** 所需的软硬件环境、依赖库安装、蓝牙/麦克风权限设置及本地模拟调试方法。

---

## 1. 软硬件准备要求

### 1.1 硬件要求
- **智能眼镜**：Even G2 智能眼镜 + Smart Ring 配套戒头/触控镜腿。
- **宿主测试设备**：支持 BLE 5.0+ 的 iPhone（iOS 14+）或 Android 手机（Android 10+），或者带蓝牙模块的 macOS/Windows 电脑。
- **开发主机**：macOS (推荐，便于 iOS/BLE 双平台调试) 或 Linux / Windows 11。

### 1.2 核心软件栈与版本要求
- **Python 3.10+**：用于运行智慧课堂后端插件 (FastAPI + WebSockets)。
- **Node.js 18+** / **npm** / **pnpm**：用于 Web 模拟器与本地前端联调。
- **Flutter SDK 3.19+** 或 **React Native 0.73+**：用于构建 Mobile Gateway 应用。
- **Git** & **GitHub CLI (`gh`)**：版本控制与代码推送。

---

## 2. 分模块环境搭建

### 2.1 模块一：智慧课堂服务端插件环境 (Python / FastAPI)

1. **进入服务端目录与创建虚拟环境**
   ```bash
   cd server_plugin
   python3 -m venv .venv
   source .venv/bin/activate  # Windows: .venv\Scripts\activate
   ```

2. **安装依赖依赖包**
   ```bash
   pip install fastapi uvicorn websockets pydantic jinja2 python-multipart
   ```

3. **启动本地测试服务端**
   ```bash
   uvicorn main:app --reload --host 0.0.0.0 --port 8000
   ```
   - WebSocket 端点可测试：`ws://localhost:8000/ws/session/test_session_01`
   - Swagger 交互文档地址：`http://localhost:8000/docs`

---

### 2.2 模块二：移动端 Gateway 环境 (Flutter / Mobile Bridge)

1. **安装 Flutter SDK**
   ```bash
   flutter doctor
   ```
   确保 Flutter, Android Studio / Xcode 环境诊断全部为绿勾。

2. **移动端权限配置**
   - **iOS (`ios/Runner/Info.plist`)**：
     ```xml
     <key>NSBluetoothAlwaysUsageDescription</key>
     <string>应用需要蓝牙连接 Even G2 智能眼镜以同步显示逐字稿</string>
     <key>NSMicrophoneUsageDescription</key>
     <string>应用需要麦克风权限以实现语音跟随提词</string>
     ```
   - **Android (`android/app/src/main/AndroidManifest.xml`)**：
     ```xml
     <uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
     <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
     <uses-permission android:name="android.permission.RECORD_AUDIO" />
     <uses-permission android:name="android.permission.INTERNET" />
     ```

3. **导入 SDK 依赖 (`pubspec.yaml`)**
   ```yaml
   dependencies:
     flutter:
       sdk: flutter
     flutter_blue_plus: ^1.30.0  # BLE 蓝牙通信
     web_socket_channel: ^3.0.0  # WebSocket 通信
     speech_to_text: ^7.0.0      # 本地轻量级 ASR 语音识别
     provider: ^6.1.2            # 状态管理
   ```

---

### 2.3 模块三：Even G2 本地模拟测试器 (Web Simulator)

在没有实体 Even G2 眼镜的情况下，可以使用基于 Web 技术的 HUD 显存模拟器进行开发与逻辑联调。

1. **进入模拟器目录并启动**
   ```bash
   cd simulator
   npm install
   npm run dev
   ```
2. 在 Chrome 浏览器中打开 `http://localhost:3000`，屏幕将严格模拟 Even G2 的绿色 Micro-LED 像素面板（3行 $\times$ 18字符），并可通过网页按键模拟 Smart Ring 戒指的击发事件。

---

## 3. 开发联调全链路验证步骤

1. **第一步：启动服务端 WebSocket 监听**
   ```bash
   uvicorn server_plugin.main:app --port 8000
   ```
2. **第二步：启动移动端 Gateway / 模拟器连接**
   打开移动端 App，输入服务器 WebSocket 地址 `ws://<局域网IP>:8000/ws/session/sess_test` 完成握手。
3. **第三步：触发模拟翻页与语音跟随**
   - 说话或播放测试音频，观察 HUD 模拟器是否逐行向上滚动；
   - 点击移动端/模拟器上的“翻页”按钮，观察服务端大屏广播 `PAGE_CONTROL` 是否推送到大屏客户端。

---

## 4. 常见问题诊断 (Troubleshooting)

- **蓝牙无法扫描到 Even G2**：检查移动端蓝牙定位权限是否开启（特别是 Android 12+ 需要显式申请 `BLUETOOTH_SCAN` 动态权限）。
- **WebSocket 连接失败**：如果在真机调试，确保手机与电脑在**同一局域网（Wi-Fi）**下，且主机防火墙放行了 8000 端口。
- **ASR 识别延时过高**：优先使用 iOS/Android 原生 Speech API 或本地离线 STT 引擎，避免公网 API 带来网络延迟。
