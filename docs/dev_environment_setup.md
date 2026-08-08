# Even G2 智能眼镜 - 智慧课堂配套应用 开发环境准备指南

本指南详细说明搭建 **Even G2 智能眼镜 - 智慧课堂配套应用** 所需的软硬件环境、依赖库安装、蓝牙/麦克风权限设置、全网卡 IP 绑定及本地/手表模拟调试方法。

---

## 1. 软硬件准备要求

### 1.1 硬件要求

- **智能眼镜**：Even G2 智能眼镜 + Smart Ring 配套戒头/触控镜腿。
- **手表设备**：Apple Watch (watchOS 10.0+)，用于替代官方戒指进行 1:1 镜腿触控板盲操、表冠滚动与手腕甩动翻页。
- **宿主测试设备**：支持 BLE 5.0+ 的 iPhone（iOS 16+）或带蓝牙模块的 Mac。
- **开发主机**：macOS (推荐 Xcode 27.4+，便于 iOS/watchOS/BLE 全栈调试)。

### 1.2 核心软件栈与版本要求

- **Python 3.10+**：用于运行智慧课堂后端插件 (FastAPI + WebSockets)。
- **Swift / SwiftUI / Xcode 27+**：用于构建 Mobile Gateway 应用与 Apple Watch 扩展。
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
2. **安装依赖包**

   ```bash
   pip install fastapi uvicorn websockets pydantic jinja2 python-multipart
   ```
3. **启动本地与局域网广播服务端 (必须指定 `--host 0.0.0.0`)**

   ```bash
   uvicorn server_plugin.main:app --host 0.0.0.0 --port 8000 --reload
   ```

   > ⚠️ **关键注意**：必须显式指定 `--host 0.0.0.0`。如果省略，Uvicorn 默认仅监听 `127.0.0.1`（本机 Loopback），同个 Wi-Fi 下的 iPhone 手机与 Apple Watch 将**无法连接**服务端！

   - WebSocket 端点测试：`ws://<局域网IP>:8000/ws/session/sess_demo`
   - Swagger 交互文档地址：`http://localhost:8000/docs`

---

### 2.2 模块二：iOS 与 watchOS 网关环境 (SmartGlassGateway & SmartGlassWatch)

1. **打开 Xcode 项目**

   ```bash
   open mobile_gateway_ios/SmartGlassGateway.xcodeproj
   ```
2. **硬件与开发者证书配置**

   - 在 Xcode `Signing & Capabilities` 中选择开发团队 (`Personal Team` 或付费团队)；
   - 目标部署版本：iOS 16.0+ / watchOS 10.0+；
   - Scheme 选择 **`SmartGlassGateway`** 运行手机宿主端，选择 **`SmartGlassWatch`** 运行 Apple Watch 手表端。

---

## 3. 开发联调全链路验证步骤

1. **第一步：启动全网卡监听的服务端**
   ```bash
   uvicorn server_plugin.main:app --host 0.0.0.0 --port 8000
   ```
2. **第二步：启动 iPhone 宿主 App 并连接眼镜/开启 Debug 代理**
   打开 iPhone 上的 `SmartGlassGateway.app`，确认已连通 `ws://<局域网IP>:8000`。
3. **第三步：Apple Watch 触控板盲操与手表翻页**
   - 打开 Apple Watch 上的 `SmartGlassWatch`；
   - 在【G2 触控板】模式下单击、双击或上下滑动，观察服务端终端是否实时刷出鲜绿色的 `⌚️ [服务端收到手表/触控手势]` 日志与 `0x06-20` 眼镜物理 HEX 字节！

---

## 4. 常见问题诊断 (Troubleshooting)

- **iPhone / Watch 无法连接 WebSocket 服务端**：检查 `uvicorn` 是否使用了 `--host 0.0.0.0` 启动，并确保手机、手表与 Mac 处在**同一个 Wi-Fi 局域网**下。
- **Apple Watch 卡在 Uninstalling / 无法安装**：使用免费开发者证书时，苹果限制通过 iPhone Watch App 蓝牙下发。请直接在 Xcode 中把 Scheme 选为 `SmartGlassWatch`，目标选为你的物理 Apple Watch，按 `⌘R` 刷入。
