# Even G2 智能眼镜全套协议与 APK / SO 逆向工程全景规范 (2026 100% 完整大师版)

---

## 1. 概述与逆向工程体系

本规范基于对 **Even Realities G2 智能眼镜**（型号 B210/G2）官方 Android App（包名 `com.even.sg`，版本 1.1.9）Java 反编译代码 (`decompiled_app`)、Flutter C/C++ 核心库 (`libapp.so` 符号表与 FFI 闭包) 以及 BLE GATT 抓包数据的全面逆向拆解编写。

报告覆盖了 G2 智能眼镜协议栈 **100% 的 15 大业务子系统与底层通信机制**，包含全量 BLE 命令表、9 大 Protobuf Schema 定义、物理 GATT ATT 句柄映射、传输层帧校验算法以及实测失败的数据流反模式归档。

---

## 2. 系统架构与 GATT ATT 句柄物理映射 (ATT Handles)

### 2.1 整体应用架构
- **前端 UI 与业务逻辑**：Flutter 框架编译产物 `libapp.so` (ARM64 Native 符号表未加密)，包含 `package:even/...` 与 `package:teleprompt/...` 全部 Dart 模块。
- **底层 BLE 通信库**：Android 原生 `com.fzfstudio.ezw_ble` 插件模块（包含 `BleManager`, `BleDevice`, `BleMC` 方法通道与命令队列）。

### 2.2 GATT 物理写特征值 (Characteristic UUID) 与 ATT 句柄对照表

```
Base UUID: 00002760-08c2-11e1-9073-0e8ac72e{xxxx}
```

| 通道/特征值名称 | 物理 UUID | ATT Handle | 传输方向 | 物理属性与用途 |
| :--- | :--- | :--- | :--- | :--- |
| **Main Service** | `00002760-08c2-11e1-9073-0e8ac72e0000` | - | - | 主 GATT 服务定义 |
| **控制与内容写通道**| `00002760-08c2-11e1-9073-0e8ac72e5401` | `0x0842` | Phone $\rightarrow$ G2 (Write) | Write Without Response, MTU 512, 主 Session 鉴权、仪表盘与通用命令 |
| **眼镜 Notify 监听通道**| `00002760-08c2-11e1-9073-0e8ac72e5402` | `0x0844` | G2 $\rightarrow$ Phone (Notify)| Notify 监听应答 (需向 `0x2902` CCCD 写入 `0x0100` 激活) |
| **Service 声明** | `00002760-08c2-11e1-9073-0e8ac72e5450` | - | - | 服务广播描述符 |
| **GPU 渲染通道** | `00002760-08c2-11e1-9073-0e8ac72e6402` | `0x0864` | Phone $\rightarrow$ G2 (Write) | Write Without Response, 204字节 GPU VSYNC 渲染脉冲/RAW 画布帧 |
| **提词器专用写通道**|`00002760-08c2-11e1-9073-0e8ac72e7401` | - | Phone $\rightarrow$ G2 (Write) | Write Without Response, 提词器硬件前台与视口控制通道 |

### 2.3 蓝牙物理层连接参数 (Connection Parameters)
- **Connection Interval**：`7.5ms - 30ms` (典型 15ms)
- **Slave Latency**：`0`
- **Supervision Timeout**：`2000ms`
- **MTU Size**：`512 字节` (支持长帧 TLV 切片分包)
- **广播命名规则**：`Even G2_XX_L_YYYYYY` (左耳) / `Even G2_XX_R_YYYYYY` (右耳)

---

## 3. 全量 BLE 服务号 (Service IDs) 映射体系

Service ID 在物理帧头中占 2 字节（`svc_hi`, `svc_lo`）：

### 3.1 核心与鉴权服务
| Service ID | 名称 | 功能描述 |
| :--- | :--- | :--- |
| `0x80-00` | Auth Control | 会话建立、句柄控制、GPU Sync Trigger 刷新脉冲 |
| `0x80-20` | Auth Data | 带 Payload 的 Session 鉴权与 Unix 时间戳同步 |
| `0x80-01` | Auth Response | G2 固件返回的鉴权确认 ACK (`AA 12 ...`) |

### 3.2 全量 15 大业务功能服务
| Service ID | 名称 | 功能描述 |
| :--- | :--- | :--- |
| `0x02-20` | Notification | 手机 App 消息通知镜像与未读数推送 (`proto_notification_ex`) |
| `0x04-20` | Display Wake | 物理唤醒 MicroLED 光学引擎总线电源 |
| `0x06-20` | Teleprompter | 提词器服务 (初始化、讲稿列表、正文分页、ScrollSync) (`proto_teleprompter_ext`) |
| `0x07-20` | Dashboard | 主屏仪表盘挂件数据 (日历、天气、简讯、股票) (`proto_dashboard_ext`) |
| `0x09-00` | Device Info | 固件版本、电量与 SN 硬件信息查询 (`proto_base_settings`) |
| `0x0B-20` | Conversate | 实时语音同传听写与双语字幕 (`proto_translate_ext`) |
| `0x0C-20` | Tasks | 待办事项与任务列表挂件 (`proto_task_manager_ext`) |
| `0x0D-00` | Configuration | 眼镜物理按键与系统参数配置 (`proto_base_settings`) |
| `0x0E-20` | Display Config | 屏幕 Region 视口物理布局配置 (IEEE754 Float 幅宽) |
| `0x11-20` | Conversate (Alt) | 备用语音同传字幕服务 |
| `0x20-20` | Commit | 硬件级显存 Commit 提交确认指令 |
| `0x81-20` | Display Trigger | 显示屏激活触发器 |

---

## 4. 传输层物理帧结构与 Varint / CRC 编解码算法

### 4.1 8-Byte Header 帧头物理结构
```
┌────────┬────────┬────────┬────────┬────────┬────────┬────────┬────────┬─────────────┬────────┬────────┐
│ Magic  │  Type  │  Seq   │  Len   │  Pkt   │  Pkt   │  Svc   │  Svc   │   Payload   │  CRC   │  CRC   │
│  0xAA  │  0x21  │   ID   │        │  Tot   │  Ser   │  Hi    │  Lo    │     ...     │   Lo   │   Hi   │
└────────┴────────┴────────┴────────┴────────┴────────┴────────┴────────┴─────────────┴────────┴────────┘
   [0]      [1]      [2]      [3]      [4]      [5]      [6]      [7]       [8:N-2]      [N-1]    [N]
```

- **Magic (byte 0)**：固定魔数 `0xAA`。
- **Type (byte 1)**：`0x21`（Command, 手机 $\rightarrow$ 眼镜），`0x12`（Response, 眼镜 $\rightarrow$ 手机）。
- **Seq ID (byte 2)**：单包平滑自增计数器 (`0x00 ~ 0xFF`)。
- **Len (byte 3)**：
  - **单包** (`pktTot=1`)：`Payload 长度 + 2`（包含帧级 CRC16 的 2 字节）。
  - **多包子包** (`pktTot≥2`)：`Chunk 长度`（**不含** CRC，直接等于本子包承载的字节数）。
- **Packet Total (byte 4)**：长数据切片总包数（未切片恒为 `0x01`，实测最大值为 `4`）。
- **Packet Serial (byte 5)**：当前切片序号（从 `0x01` 开始）。
- **Service Hi/Lo (bytes 6-7)**：服务分类 ID（如 `0x06 0x20`）。

### 4.2 CRC16-CCITT 双层校验机制 🆕

> ⚠️ **关键发现 (2026-07-29)**：单包与多包使用**完全不同的 CRC 校验机制**。这一差异是导致第三方多包推送黑屏的核心根因。

**算法参数（两者共用）**：
- **算法模型**：CRC-16/CCITT (`XModem`)
- **初始值**：`0xFFFF`
- **多项式**：`0x1021`
- **输出格式**：Little-Endian（低字节在前）

**单包模式** (`pktTot=1`)：**帧级 CRC**
- **计算范围**：仅 Payload（`data[8:]`，不含 Header 前 8 字节）
- **存放位置**：追加在 BLE 写入帧末尾 2 字节
- **验证**：39/39 单包帧 CRC 匹配 ✅

**多包模式** (`pktTot≥2`)：**Payload 级 CRC**
- **计算范围**：完整 Protobuf payload（即固件重组后的完整消息体）
- **存放位置**：追加在 Protobuf 消息末尾 2 字节，**包含在分包数据流中**
- **子包本身**：**无帧级 CRC**
- **验证**：9/9 多包内容页 CRC 匹配 ✅

```
单包帧结构:                         多包帧结构（重组后）:
┌────────┬─────────┬────────┐       ┌─────────────────────────┬────────┐
│ Header │ Payload │ CRC16  │       │  Protobuf Payload       │ CRC16  │
│ (8B)   │ (N B)   │ (2B)   │       │  (固件重组后的完整消息) │ (2B)   │
└────────┴─────────┴────────┘       └─────────────────────────┴────────┘
  Len = N + 2                         各子包 Len = chunk_size
  CRC = crc16(Payload)                CRC = crc16(Protobuf Payload)
```

---

## 5. 全量 Protobuf 协议 Schema 描述 (核心服务源码)

```protobuf
syntax = "proto3";
package even.g2;

// 1. 鉴权与 Session 时间同步 (Service 0x80-00 / 0x80-20)
message AuthRequest {
  uint32 type = 1;          // 0x04 = capability, 0x80 = time sync
  uint32 msg_id = 2;
  AuthData data = 3;
}

message AuthData {
  uint32 capability = 1;    // 0x01 = basic, 0x04 = full
}

message TimeSyncRequest {
  uint32 type = 1;          // 0x80
  uint32 msg_id = 2;
  TimeSyncData sync = 16;   // Field 16 (0x82 0x08)
}

message TimeSyncData {
  uint32 unknown1 = 2;      // 17 (0x11)
  uint64 timestamp = 1;     // Unix timestamp
  int64 transaction_id = 2; // -24 (0xFFFFFFFFFFFFFFE8)
}

// 2. 提词器服务 (Service 0x06-20)
message TeleprompterMessage {
  uint32 type = 1;          // 1=init, 2=list, 3=content, 4=complete, 255=marker
  uint32 msg_id = 2;
  TeleprompterInit init = 3;           // type=1
  TeleprompterList list = 4;           // type=2
  TeleprompterContent content = 5;     // type=3
  TeleprompterComplete complete = 6;   // type=4
  TeleprompterMarker marker = 13;      // type=255
}

message TeleprompterInit {
  uint32 script_index = 1;
  TeleprompterDisplaySettings display = 2;
}

message TeleprompterDisplaySettings {
  uint32 field1 = 1;            // 官方值=0（非1）
  uint32 field2 = 2;            // 0
  uint32 field3 = 3;            // 0
  uint32 display_width = 4;     // 官方值=59（非267/644）
  uint32 content_height = 5;    // 官方值=585（画卷总高度）
  uint32 line_height = 6;       // 官方值=567（非230）
  uint32 viewport_height = 7;   // 官方值=3113（非1294/2588）
  uint32 font_size = 8;         // 官方值=0（非5）
  uint32 scroll_mode = 9;       // 0=manual, 1=AI
  uint32 render_mode = 10;      // 🆕 官方值=9（可能控制全屏渲染模式）
  uint32 field11 = 11;          // 🆕 官方值=0
}

message TeleprompterList {
  repeated TeleprompterScript scripts = 1;
}

message TeleprompterScript {
  string script_id = 1;     // e.g., "script_01"
  string title = 2;         // e.g., "SmartClassroom"
}

message TeleprompterContent {
  uint32 page_number = 1;   // 0-indexed
  uint32 line_count = 2;    // 10
  bytes text = 3;           // UTF-8 \n 分隔
}

message TeleprompterComplete {
  uint32 start_page = 1;    // 0
  uint32 total_pages = 2;   // >= 14
  uint32 total_lines = 3;   // >= 140
}

message TeleprompterState {
  uint32 state = 1;         // 1 (Active 开启前台), 4 (Stop/Exit 退出关闭提词)
}

message TeleprompterMarker {
  uint32 field1 = 1;        // 0
  uint32 field2 = 2;        // 6
}

message TeleprompterStart {
  uint32 type = 1;          // 1
  uint32 msg_id = 2;
  TeleprompterState state = 3;
}

message TeleprompterState {
  uint32 state = 1;         // 1 (Active)
}

// 3. 屏幕视口物理布局配置 (Service 0x0E-20)
message DisplayConfig {
  uint32 type = 1;          // 2
  uint32 msg_id = 2;
  DisplaySettings settings = 4;
}

message DisplaySettings {
  uint32 enabled = 1;
  repeated DisplayRegion regions = 2;
  uint32 field3 = 3;
}

message DisplayRegion {
  uint32 region_id = 1;     // Region 2, 3, 4, 5, 6, 9
  uint32 param1 = 2;
  float param2 = 3;         // 32-bit IEEE 754 Float（官方值全部为 0.0f）
  float param3 = 4;         //（官方值全部为 0.0f）
  uint32 param4 = 5;
  uint32 param5 = 6;
  uint32 param6 = 7;        // 🆕 官方值=0
}

// 4. GPU VSYNC 同步刷屏脉冲 (Service 0x80-00)
message SyncMessage {
  uint32 type = 1;          // 0x0E (type=14)
  uint32 msg_id = 2;
  bytes data = 13;          // 6A-00
}

// 5. 系统级 Setup 与基础设施配置 Schema (Service 0x07/0x03/0x0C/0x30/0x0D/0x1F/0x10/0x04) 🆕
message DashboardSetup { // Service 0x07-20 (语言/基线)
  uint32 type = 1;          // 10
  uint32 msg_id = 2;        // 10
  DashboardConfig config = 13;
}

message DashboardConfig {
  uint32 field1 = 1;        // 0
  uint32 lang_code = 2;     // 80 (UTF-8 字符映射)
  uint32 field4 = 4;        // 0
}

message ScreenGeometrySetup { // Service 0x03-20 (视口点阵/DPI 布局)
  uint32 type = 1;          // 0
  uint32 msg_id = 2;        // 7
  ScreenLayout layout = 3;
}

message ScreenLayout {
  uint32 base_id = 1;       // 8
  repeated RegionDPI regions = 2; // Region 4, 11, 6, 5, 8, 7, 1, 266
}

message TaskManagerSetup { // Service 0x0C-20 (挂件管理使能)
  uint32 type = 1;          // 2
  uint32 msg_id = 2;        // 9
  TaskState state = 4;      // Tag 1=1, Tag 2=0
}

message EventTriggerSetup { // Service 0x30-20 (物理事件监听器使能)
  uint32 type = 1;          // 1
  uint32 msg_id = 2;        // 11
  EventListener listener = 3; // Tag 1=1, Tag 2=0
}

message InputDeviceSetup { // Service 0x0D-20 (交互输入设备注册)
  uint32 type = 1;          // 0
  uint32 msg_id = 2;        // 5
}

message TouchpadInterruptSetup { // Service 0x1F-20 (🚨 Touchpad 触控板滑动中断使能)
  uint32 type = 1;          // 0
  uint32 msg_id = 2;        // 8
  TouchpadEnable enable = 3; // Tag 1=1 (使能触控板中断)
}

message PowerSleepSetup { // Service 0x10-20 (屏幕功耗/休眠/亮度策略)
  uint32 type = 1;          // 1
  uint32 msg_id = 2;        // 12
  PowerPolicy policy = 3;   // Tag 1=4 (唤醒并保持高亮模式)
}

message DisplayPowerWakeSetup { // Service 0x04-20 (MicroLED 光学引擎总线电源唤醒)
  uint32 type = 1;          // 1
  uint32 msg_id = 2;        // 35
  PowerWake wake = 3;       // Tag 5=1 (唤醒 MicroLED 光学总线电源)
}
```

---

## 6. 全量 15 大业务子系统物理协议明细拆解

### 6.1 提词器子系统 (`proto_teleprompter_ext.dart` / Service 0x06-20)
- **命令方法集**：
  - `startTeleprompter`：发送 `TeleprompterStart` (`08 01 10 msg 1A 02 08 01`) 激活提词前台。
  - `stopTeleprompter`：发送 `08 01 10 msg 1A 02 08 00` 退出提词器，重置视口。
  - `pauseTeleprompter` / `resumeTeleprompter`：暂停与恢复滚动。
  - `sendTeleprompterFileList`：下发包含 `script_id` 与 `title` 的讲稿列表元数据。
  - `sendTeleprompterPageData`：按页下发 UTF-8 文本（每页 10 行，前附 `\n` 后附 ` \n`）。
  - `sendTeleprompterScrollSyncEvent`：下发 `pageLine = 0` 执行视口平滑归位。
  - `sendTeleprompterAISyncEvent`：语音触发模式下的行滚动基准对齐。
  - `sendTeleprompterHearBeat`：维持提词显存活力的 5s 心跳帧。

---

## 7. 推送提示词黑屏/无反应 5 大根因诊断与排查解决方案

根据官方 App 反编译逻辑与 BLE 抓包物理调试，推送提示词后眼镜无反应有以下 5 个核心原因及解决方案：

### 1️⃣ 关键点一：显示前台容器切换 (App Window Container Switch)
- **根因**：G2 眼镜开机后处于 **Dashboard 主屏（时钟挂件视图）**。OS 窗口管理器不会自动将数据弹屏。
- **解决方案**：在下发文本前，必须首先下发 `TeleprompterStart` (`08 01 10 msg 1A 02 08 01`) 或 `createStartUpPageContainer`。这会通知 OS Window Manager *“将当前活跃视口从主屏切为提词前台容器”*。

### 2️⃣ 关键点二：Session 5401 鉴权 ACK 应答锁死
- **根因**：固件收到提词数据前要求 BLE 处于“已鉴权 (Authenticated)”状态。
- **解决方案**：前置 7 帧 Auth 序列必须通过 `5401` 下发，并监听到固件在 Notify 通道（`5402`）回发 `0x40` / `0xA4` 等 ACK 帧。未完成鉴权的会话将被固件安全模块丢弃。

### 3️⃣ 关键点三：CCCD 描述符 Notify 订阅使能 (`0x2902` 写入 `0x0100`)
- **根因**：G2 窗口管理器要回发 `OS_RESPONSE_CREATE_STARTUP_PAGE_PACKET` 响应。若 iOS 端未为 Notify 特征使能 `setNotifyValue(true)`，固件会卡死在等待握手状态。
- **解决方案**：在 BLE 发现特征后，为包含 `.notify` 属性的所有特征值执行订阅使能。

### 4️⃣ 关键点四：按需正文切片与页数下发 (澄清社区早期 14 页补满误区) 🆕
- **澄清误区**：社区早期误以为官方固件要求强制补满 14 页（140 行）。根据 `bt3.pklg` 物理抓包与真机验证，**官方 App 是按实际文本量下发页数（如 4 页/Page 0~3）**，固件也可正常渲染。
- **物理规范**：`TeleprompterContent` 按需下发实际页数（Page 0..N-1），每页包含最多 10 行 UTF-8 文本；`TeleprompterComplete` 中的 `total_pages` 与 `total_lines` 填入实际下发的页数与行数即可，无需填充假空行。
- **当前代码实现策略**：虽然固件接受按需下发，但当前代码 `G2ProtocolEncoder.formatTextToPages(targetPageCount: 14)` 采用**保守的 14 页补满策略**——短文本不足 14 页时自动填充空白页，以确保在各种固件版本下的最大兼容性。详见 §16.1 代码对齐说明。
- **渲染基准**：显示排版基准为 `display_width = 59` (全屏模式)，每行最多 28 汉字。

### 5️⃣ 关键点五：Render Commit 渲染提交信号 (`0x80-00` Type 14)
- **机制**：G2 MCU 为单会话不可覆写设计——内容只能在会话初始化阶段批量灌入，灌入完成后通过 `SyncMessage` (`0x80-00` Type 14) 发出渲染提交信号，MCU 收到后将已接收的全部 Page 数据一次性渲染至 MicroLED 屏上。
- **⚠️ 勘误**：早期分析曾将此包描述为"双缓冲翻转"(framebuffer flip)，但实测与官方 APP 抓包 (§23) 证实 MCU 不支持在活跃 Session 内直接覆写或热替换文本内容——不存在"预填充后台 Buffer 再翻转"的能力。切换文本的唯一路径是完整的 Session 销毁→重建闭环 (§23.2)。

---

## 8. 已验证失败的数据流逻辑与反模式归档 (Anti-Pattern Matrix)

| 实验编号 | 数据流尝试路径 | 固件物理响应行为 | 黑屏根因诊断 |
| :--- | :--- | :--- | :--- |
| **Trial A** | **全量走 5401 通道**<br>(Auth $\rightarrow$ 5401<br>Teleprompter $\rightarrow$ 5401<br>Sync $\rightarrow$ 5401) | 固件回发 ACK (`Seq=0x40`, `0xA4`, `0x17`, `0x73`, `0xD7`)，传输层确认成功。 | **黑屏**。5401 仅为 Dashboard/主屏挂件通道，虽然固件 BLE 传输层返回 ACK，但 G2 Window Manager 未将内容渲染进提词视口。 |
| **Trial B** | **全量走 0001/7401/6401**<br>(Auth $\rightarrow$ 0001<br>Teleprompter $\rightarrow$ 7401<br>Sync $\rightarrow$ 6401) | 0001 完全无 ACK 应答；7401 完全无应答；6401 原样 Loopback 回传 `AA 21 1E...` 帧。 | **黑屏**。0001 无法接收 Auth 报文导致会话未建立鉴权，G2 固件安全机制拒收后续 7401/6401 指令。 |
| **Trial C** | **混合通道**<br>(Auth $\rightarrow$ 5401 获得 ACK<br>Teleprompter $\rightarrow$ 7401<br>Sync $\rightarrow$ 6401) | 5401 返回 Auth ACK (`Seq=0x40`, `0xA4`, `0x73`, `0xD7`)；7401 发送成功但无 ACK；6401 回传 Loopback 帧。 | **黑屏**。7401 特征值下发后 MicroLED 无显示，说明 7401 需要预先写入 0x2902 Descriptor 开启 Notify 订阅，或 7401 非直写特征。 |

---

## 9. 自动化单元测试与物理断言规范

所有 Protobuf 封包与物理 BLE 帧必须通过严格的本地自动化单元测试：
1. **CRC16 校验测试**：验证 `addCRC` 生成的 CRC16 校验码与官方 C++ 模块输出 100% 一致。
2. **Protobuf 规则断言**：断言封包输出绝对不包含非法的 WireType（如 `0x06`），每个 Tag 头必须匹配 Protobuf Spec。
3. **物理 Sequence 递增测试**：长 Payload 切片时，断言分片帧数组中 `seq` 严格平滑自增。
4. **14 页缓冲补满与行数正确性测试**：断言 `formatTextToPages()` 输出 `pages.count >= 14`（短文本自动补满 14 页 Buffer 槽位），且每页精确包含 10 行。`totalLines` 等于实际 wrapped 行数（含补满空白行）。

---
*修订时间：2026-07-29*  
*分析员：Antigravity Agent Team*

---

## 10. 官方 APP iOS BLE 抓包协议分析 (2026-07-28)

> 使用 Apple PacketLogger 抓取官方 Even G2 APP（iOS 端）与眼镜的实时 BLE 通讯数据 (`bt.pklg`)，提取全部 69 个 G2 协议帧的精确参数。

### 10.1 BLE 传输层实测参数

| 参数 | macOS (bleak) | iOS (CoreBluetooth) | 说明 |
| :--- | :--- | :--- | :--- |
| **协商 MTU** | **247 bytes** | **≥512 bytes** | macOS 单次写入上限 244 字节 |
| **子包 chunk 上限** | 232 bytes | 232 bytes | 官方 APP 每子包 chunk = 232 bytes（总包大小 240 = 8 header + 232 chunk） |
| **多包分片** | 需要（payload > 232b） | 需要（payload > 232b） | 官方 APP pktTot=3~4（实测最大 4），pktSer 从 1 递增 |

### 10.2 官方 APP 完整发送序列（69 帧）

```
阶段 1：鉴权与系统级 Setup 物理初始化序列 (seq 1~15) 🆕 (2026-08-02 精确修订)
──────────────────────────────────────────────────────────────────────────────────
seq  1: Auth/Capability (0x80-00)     ← [20B] AA 21 01 0C 01 01 80 00 08 04 10 01 1A 04 08 01 10 03 2B 26
seq  2: Auth/TimeSync   (0x80-20)     ← [18B] AA 21 02 0A 01 01 80 20 08 05 10 02 22 02 08 01 8A 25
seq  3: Auth/UnixTime   (0x80-20)     ← [26B] AA 21 03 12 01 01 80 20 08 80 01 10 03 82 08 08 08 8A 92 BB...
seq  4: Auth/Capability (0x80-00)     ← [20B] AA 21 04 0C 01 01 80 00 08 04 10 04 1A 04 08 01 10 03 8C 5F

--- 以下为官方提词前必发 7 包基础设施 Setup 配置 (缺失将导致 Touchpad 触控不可用) ---
seq  5: 07-20 (Dashboard Setup)       ← [22B] AA 21 0A 0E 01 01 07 20 08 0A 10 0A 6A 06 08 00 10 50 20 00 4E 15 (语言/基线)
seq  6: 03-20 (Screen & DPI Layout)   ← [67B] AA 21 07 3B 01 01 03 20 08 00 10 07 1A 33... (视口 8 区域分辨率/点阵)
seq  7: 0C-20 (Task Manager Setup)    ← [20B] AA 21 09 0C 01 01 0C 20 08 02 10 09 22 04 08 01 10 00 A3 FD (挂件管理)
seq  8: 30-20 (Event Trigger Setup)   ← [20B] AA 21 0B 0C 01 01 30 20 08 01 10 0B 1A 04 08 01 10 00 CA 92 (物理监听器)
seq  9: 0D-20 (Input Device Register) ← [14B] AA 21 05 06 01 01 0D 20 08 00 10 05 D5 52 (交互设备注册)
seq 10: 09-20 (Device Settings Setup)  ← [28B] AA 21 06 14 01 01 09 20 08 01 10 06 1A 0C 4A 0A 08 00 10 00 18 00...
seq 11: 1F-20 (Touchpad Interrupt)    ← [18B] AA 21 08 0A 01 01 1F 20 08 00 10 08 1A 02 08 01 A9 B3 (🚨 触控板滑动中断使能)
seq 12: 10-20 (Power & Sleep Control) ← [18B] AA 21 0C 0A 01 01 10 20 08 01 10 0C 1A 02 08 04 6B D2 (功耗与亮度策略)
seq 13: 09-20 (App Focus Lock #1)     ← [18B] AA 21 0D 0A 01 01 09 20 08 02 10 0D 22 02 08 01 37 59 (焦点强行一次锁死)
seq 14: 09-20 (App Focus Lock #2)     ← [18B] AA 21 0F 0A 01 01 09 20 08 02 10 0F 22 02 08 01 B4 1D (焦点强行二次锁死)
seq 15: 01-20 (Pipeline Layout Ready) ← [26B] AA 21 10 12 01 01 01 20 08 02 10 10 22 0A 1A 08 12 06 12 04 08 00 10 00 (画布渲染流水线就绪帧)
seq 16: 06-20 (TeleprompterInit)      ← [45B] AA 21 1B 25 01 01 06 20... (提词画卷参数初始化)
seq 17: 01-20 (System Layout Config)  ← [39B] AA 21 11 1F 01 01 01 20... (UI 视口结构确认)
seq 18: 01-20 (System Layout Config)  ← [28B] AA 21 13 14 01 01 01 20... (UI 视口结构确认)
...

### 10.2 官方 APP 100% 全量 172 个 ATT 物理事件与 CCCD 使能明细 🆕 (2026-08-02 物理全量对齐)

根据 `bt3.pklg` 的二进制解调，官方 APP 在下发 `AA 21` 协议包之前，必须首先在 ATT 底层向 **5 大 CCCD 描述符句柄** 写入使能控制位。

#### 物理事件总览：
- **总下发事件数**：172 个 ATT Write 事件（包含 9 次 CCCD 描述符使能 + 163 包 AA 21 数据帧）
- **物理写句柄映射 (Handle Map)**：
  - `Handle 0x0845` -> `5402 CCCD` (写入 `01 00` 开启 Notify)
  - `Handle 0x0825` -> `5403 CCCD` (写入 `01 00` 开启 Notify)
  - `Handle 0x0865` -> `5404 CCCD` (写入 `01 00` 开启 Notify)
  - `Handle 0x0885` -> `5405 CCCD` (写入 `01 00` 开启 Notify)
  - `Handle 0x0013` -> `2A4D CCCD` (**写入 `02 00` 开启 Indicate 确认订阅！**)
  - `Handle 0x0842` -> `5401 Write` (写入 `AA 21` 数据 Payload)

#### 前 15 个底层 ATT 物理事件顺序明细：

| 事件序号 | 物理 Handle | ATT Opcode | 载荷长度 | HEX 数据与物理语义 |
| :--- | :--- | :--- | :--- | :--- |
| **Event # 1** | `0x0845` | `WriteReq (0x12)` | 2B | `01 00` (开启 5402 CCCD Notify #1) |
| **Event # 2** | `0x0825` | `WriteReq (0x12)` | 2B | `01 00` (开启 5403 CCCD Notify #1) |
| **Event # 3** | `0x0865` | `WriteReq (0x12)` | 2B | `01 00` (开启 5404 CCCD Notify #1) |
| **Event # 4** | **`0x0013`** | `WriteReq (0x12)` | 2B | **`02 00` (🚨 开启 2A4D CCCD Indicate 确认！)** |
| **Event # 5** | `0x0885` | `WriteReq (0x12)` | 2B | `01 00` (开启 5405 CCCD Notify #1) |
| **Event # 6** | `0x0842` | `WriteCmd (0x52)` | 20B | `AA 21 01 0C 01 01 80 00...` (Auth Capability) |
| **Event # 7** | `0x0842` | `WriteCmd (0x52)` | 18B | `AA 21 02 0A 01 01 80 20...` (Auth TimeSync) |
| **Event # 8** | `0x0842` | `WriteCmd (0x52)` | 26B | `AA 21 03 12 01 01 80 20...` (Auth UnixTime) |
| **Event # 9** | `0x0845` | `WriteReq (0x12)` | 2B | `01 00` (二次确认 5402 CCCD Notify #2) |
| **Event #10** | `0x0825` | `WriteReq (0x12)` | 2B | `01 00` (二次确认 5403 CCCD Notify #2) |
| **Event #11** | `0x0865` | `WriteReq (0x12)` | 2B | `01 00` (二次确认 5404 CCCD Notify #2) |
| **Event #12** | `0x0885` | `WriteReq (0x12)` | 2B | `01 00` (二次确认 5405 CCCD Notify #2) |
| **Event #13** | `0x0842` | `WriteCmd (0x52)` | 20B | `AA 21 04 0C 01 01 80 00...` (Auth Session Ready) |
| **Event #14** | `0x0842` | `WriteCmd (0x52)` | 22B | `AA 21 0A 0E 01 01 07 20...` (Dashboard Setup) |
| **Event #15** | `0x0842` | `WriteCmd (0x52)` | 67B | `AA 21 07 3B 01 01 03 20...` (Screen Geometry Setup) |

```text
⏱️ 三大 Timing 物理下发法则：
1. 基础设施 Setup 阶段 (seq 1~18): 包间强制留出 250ms ~ 300ms 安全窗口 (平均 +270ms)，确保 MCU 寄存器写入。
2. 同一 Page 多包切片 (Pkt #19~22): 采用 12ms ~ 13ms 极速 Burst 下发，利用 BLE 链路 MTU 高速连续吐包。
3. 文本页间切换 (Page N -> Page N+1): 暂停 770ms ~ 800ms，等待前台 HUD 画布卷轴重构。
```

#### 前 25 包物理下发时间线明细表：

| 序号 | 物理 Service | Seq ID | 相对时间戳 | 包间间隔 (Delta) | 官方 App 下发动作与物理语义 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| Pkt # 1 | **`0x80-00`** | `0x01` | 0.0 ms | Baseline | Auth Capability (会话能力协商) |
| Pkt # 2 | **`0x80-20`** | `0x01` | 358.0 ms | **+358.0 ms** | Auth TimeSync (时间戳同步) |
| Pkt # 3 | **`0x80-20`** | `0x01` | 627.0 ms | **+269.0 ms** | Auth UnixTime (Unix 绝对时间) |
| Pkt # 4 | **`0x80-00`** | `0x01` | 1224.0 ms | **+597.0 ms** | Auth Session Ready (鉴权就绪) |
| Pkt # 5 | **`0x07-20`** | `0x01` | 1390.0 ms | **+166.0 ms** | Dashboard Setup (语言/基线) |
| Pkt # 6 | **`0x03-20`** | `0x01` | 1892.0 ms | **+502.0 ms** | Screen Geometry (视口 8 区域 DPI 点阵) |
| Pkt # 7 | **`0x0C-20`** | `0x01` | 2164.0 ms | **+272.0 ms** | Task Manager Setup (挂件管理) |
| Pkt # 8 | **`0x30-20`** | `0x01` | 2432.0 ms | **+268.0 ms** | Event Trigger Setup (物理事件监听器) |
| Pkt # 9 | **`0x0D-20`** | `0x01` | 2741.0 ms | **+309.0 ms** | Input Device Register (交互设备注册) |
| Pkt #10 | **`0x09-20`** | `0x01` | 2972.0 ms | **+231.0 ms** | Device Settings Setup (全局设置) |
| Pkt #11 | **`0x1F-20`** | `0x01` | 3333.0 ms | **+361.0 ms** | **Touchpad Interrupt (🚨 触控板滑动使能)** |
| Pkt #12 | **`0x10-20`** | `0x01` | 3604.0 ms | **+271.0 ms** | Power & Sleep Control (功耗与亮度策略) |
| Pkt #13 | **`0x09-20`** | `0x01` | 3875.0 ms | **+271.0 ms** | App Focus Lock #1 (焦点一次锁死) |
| Pkt #14 | **`0x09-20`** | `0x01` | 4144.0 ms | **+269.0 ms** | App Focus Lock #2 (焦点二次锁死) |
| Pkt #15 | **`0x01-20`** | `0x01` | 4415.0 ms | **+271.0 ms** | Pipeline Layout Ready (画布就绪帧) |
| Pkt #16 | **`0x06-20`** | `0x01` | 4683.0 ms | **+268.0 ms** | TeleprompterInit (提词参数初始化) |
| Pkt #17 | **`0x01-20`** | `0x01` | 5068.0 ms | **+385.0 ms** | System Layout Config (UI 结构确认) |
| Pkt #18 | **`0x01-20`** | `0x01` | 5314.0 ms | **+246.0 ms** | System Layout Config (UI 结构确认) |
| Pkt #19 | **`0x06-20`** | `0x01` | 5494.0 ms | **+180.0 ms** | Page 0 Slice 1 (首页文本分片 1) |
| Pkt #20 | **`0x06-20`** | `0x02` | 5507.0 ms | ⚡ **+13.0 ms** | Page 0 Slice 2 (首页 Burst 连续发) |
| Pkt #21 | **`0x06-20`** | `0x03` | 5519.0 ms | ⚡ **+12.0 ms** | Page 0 Slice 3 (首页 Burst 连续发) |
| Pkt #22 | **`0x06-20`** | `0x04` | 5532.0 ms | ⚡ **+13.0 ms** | Page 0 Slice 4 (首页 Burst 连续发) |
| Pkt #23 | **`0x06-20`** | `0x01` | 6306.0 ms | 🐢 **+774.0 ms** | Page 1 Slice 1 (暂停 774ms 后发 Page 1) |
| Pkt #24 | **`0x06-20`** | `0x02` | 6319.0 ms | ⚡ **+13.0 ms** | Page 1 Slice 2 (次页 Burst 连续发) |
| Pkt #25 | **`0x06-20`** | `0x03` | 6333.0 ms | ⚡ **+14.0 ms** | Page 1 Slice 3 (次页 Burst 连续发) |

阶段 2：Display Config 与提词器初始化 (seq 23~36)
──────────────────────────────────────────────────
seq 23:    0120 (预备配置)
seq 24:    Display Config (0x0E20) ①       ← 全零 Region 布局
seq 25-26: 0120 (预备配置 ×2)
seq 27:    Display Config (0x0E20) ②       ← 重发
seq 28:    8120 (显示触发)
seq 29-30: 2020 (Commit)
seq 31-32: Display Config (0x0E20) ③④     ← 再重发 2 次
seq 33-34: Auth/Capability (0x8000)        ← Sync 触发
seq 35:    0120 (预备)
seq 36:    0120 (预备)

阶段 3：提词器会话 (seq 37~68)
────────────────────────────────
seq 37:    Teleprompter INIT (0x0620)      ← 含关键参数 (display_width=59, render_mode=9)
seq 38-67: Teleprompter CONTENT ×9 页      ← 正文多包分片 (pktTot=3~4) + 0x09-20 前台切页
seq 68:    Teleprompter State (type=4, state=4) ← 🚨 物理退出/关闭提词器指令 (重放推屏时切勿下发!)
```

### 10.3 Teleprompter Init 精确参数对比（官方抓包 vs 原始第三方 vs 当前重构版）

官方 Init 原始 hex：
```
080110271a1d08011219 0800 1000 1800 203b 28c904 30b704 38a918 4000 4801 5009 5800
```

解码对照表：

| Protobuf Field | Tag | 官方 APP 抓包原生值 | 原始第三方开源版<br>(even-g2 早期社区版) | 当前项目 teleprompter.py<br>(实测重构版) | 语义推断与排版效果 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **field 1** | `08` | **0** | 1 | **0** | 渲染引擎模式选择器 (0=默认全屏) |
| **field 2** | `10` | 0 | 0 | 0 | 保留字段 |
| **field 3** | `18` | 0 | 0 | 0 | 保留字段 |
| **field 4 (display_width)** | `20` | **59** | 644 | **59** | **全屏模式标志** (59=开启全屏 28 汉字排版，非 644 居中框) |
| **field 5 (content_height)** | `28` | **585** (`0xC9 0x04`) | 动态 | **585** (`0xC9 0x04`) | 画卷总高度 |
| **field 6 (line_height)** | `30` | **567** (`0xB7 0x04`) | 230 | **567** (`0xB7 0x04`) | 视口行高 |
| **field 7 (viewport)** | `38` | **3113** (`0xA9 0x18`) | 1294 | **3113** (`0xA9 0x18`) | 视口总高度 |
| **field 8 (font_size)** | `40` | **0** | 5 | **0** | 字号与渲染缩放 (0=标准系统字号) |
| **field 9 (scroll_mode)** | `48` | **1** | 0 | **1** | 滚动模式 (0=手动, 1=AI 模式) |
| **field 10 (render_mode)** | `50` | **9** | ❌ (缺失) | **9** | 全屏视口渲染模式标志 |
| **field 11** | `58` | **0** | ❌ (缺失) | **0** | 扩展标志 |

### 10.4 Display Config 精确参数

官方 Display Config 原始 hex（145 bytes payload）：
```
0802 10XX 228A01
  0801                                                    # enabled = 1
  1215 0802 10904E 1D00000000 2500000000 2800 3000 3800   # Region 2: param1=10000, w=0.0, h=0.0
  1215 0803 10AC02 1D00000000 2500000000 2800 3000 3800   # Region 3: param1=300,   w=0.0, h=0.0
  1214 0804 1000   1D00000000 2500000000 2800 3000 3800   # Region 4: param1=0,     w=0.0, h=0.0
  1214 0805 1000   1D00000000 2500000000 2800 3000 3800   # Region 5: param1=0,     w=0.0, h=0.0
  1214 0806 1000   1D00000000 2500000000 2800 3000 3800   # Region 6: param1=0,     w=0.0, h=0.0
  1214 0809 1000   1D00000000 2500000000 2800 3000 3800   # Region 9: param1=0,     w=0.0, h=0.0  🆕
  1800                                                    # field 3 = 0
```

**关键差异**：
- 官方：**所有 Region 的 width/height 均为 0.0**（float 零值），含 field 7 (`38 00`)，包含 **Region 9**
- 第三方：Region 1/2 的 width=644.0, height=200.0，无 field 7，无 Region 9

### 10.5 内容页多包分片传输格式 🆕 (2026-07-29 修正)

> ⚠️ **重要修正**：原版本 §10.5 关于多包 CRC 的描述有误。经 bt.pklg 逐字节验证，多包子包**不含**帧级 CRC；CRC 以 Payload 级方式追加在 Protobuf 消息末尾，包含在分包数据流中。

官方 APP 对每个超过 232 字节的 Protobuf payload 使用多包分片（最大 pktTot=4）：

```
┌──────────────────────────── 逻辑内容页 ───────────────────────────────────┐
│                                                                            │
│  Protobuf Payload (N bytes) + CRC16 (2 bytes)                              │
│  ┌─────────────────────────────────────────────────────────┬──────┐        │
│  │ 08 03 10 XX 2A ... (Protobuf 消息体)                    │ CRC  │        │
│  └───────────────┬──────────────┬──────────────┬───────────┴──────┘        │
│                  ▼              ▼              ▼                            │
│  子包1 (pktSer=1/4)    子包2 (2/4)     子包3 (3/4)     子包4 (4/4)        │
│  ┌──────────────────┐ ┌──────────────┐ ┌──────────────┐ ┌────────────┐     │
│  │ AA 21 seq E8     │ │ AA 21 seq E8 │ │ AA 21 seq E8 │ │ AA 21 seq  │     │
│  │ 04 01 06 20      │ │ 04 02 06 20  │ │ 04 03 06 20  │ │ 04 04 06 20│     │
│  │ [232B chunk]     │ │ [232B chunk] │ │ [232B chunk] │ │ [余量+CRC] │     │
│  └──────────────────┘ └──────────────┘ └──────────────┘ └────────────┘     │
│   BLE write: 240B       240B            240B             8+余量 bytes      │
│   全部 < MTU 244 ✓      < 244 ✓         < 244 ✓          < 244 ✓          │
└────────────────────────────────────────────────────────────────────────────┘
```

**协议要点：**
- **seq 不变**：同一逻辑页的所有子包共用相同 seq
- **pktTot/pktSer**：pktTot=总子包数（实测最大 4），pktSer 从 1 递增
- **Len 字段**：`chunk_size`（**不加 2**，与单包不同）
- **子包 CRC**：**无**（子包不含任何帧级 CRC）
- **Payload 级 CRC**：CRC-16/CCITT(init=0xFFFF) 对完整 Protobuf 消息计算，追加在消息末尾 2 字节，**包含在最后一个子包的 chunk 中**
- **实测子包 chunk**：固定 232 bytes（末尾子包为余量 + 2 字节 CRC）
- **pktTot 上限**：实测最大 4 子包（4 × 232 = 928 字节 max payload + 2 字节 CRC）

**验证数据（9/9 全部匹配）：**

| seq | pktTot | Payload (bytes) | Trailing 2B | CRC-16/CCITT | Match |
| :--- | :--- | :--- | :--- | :--- | :--- |
| 0x26 | 4 | 733 | `ae bb` | 0xBBAE | ✅ |
| 0x27 | 3 | 623 | `73 3a` | 0x3A73 | ✅ |
| 0x28 | 4 | 713 | `49 69` | 0x6949 | ✅ |
| 0x29 | 4 | 778 | `8f e3` | 0xE38F | ✅ |
| 0x2A | 3 | 579 | `43 96` | 0x9643 | ✅ |
| 0x2B | 3 | 551 | `07 6c` | 0x6C07 | ✅ |
| 0x2C | 3 | 609 | `a6 11` | 0x11A6 | ✅ |
| 0x2D | 3 | 592 | `90 30` | 0x3090 | ✅ |
| 0x2E | 3 | 660 | `f4 88` | 0x88F4 | ✅ |

### 10.6 内容页文本格式（实测样本）

从官方 APP 抓包提取的第一页实际文本：

```
\n各位领导、各位老师，大家上午好！
今天我们召开《人机协同程序设计》课程全校统一数智化教学集
体备课研讨会，主要目的是为了贯彻落实教务处...
```

- **每行约 28 个中文字**（含标点）
- **每页 10 行**（`line_count = 0x0A`）
- **行以 `\n` (0x0A) 分隔**
- **文本格式**：直接 10 行内容，**不**前置 `\n`（前置 `\n` 会浪费 1 个行位导致空行间隙）

### 10.7 物理实测验证结论

> ✅ **验证一 (2026-07-28)**：全屏排版参数破解
> - 通过将 `TeleprompterInit` 参数修改为官方抓包参数：`display_width = 59`, `font_size = 0`, `render_mode = 9` (Field 10), `line_height = 567`, `viewport_height = 3113`
> - 物理眼镜镜片成功从默认 11 字居中缩略框**解封并切入全屏顶格排版模式**，物理实测**第一行完美完整显示了 28 个中文字符**！

> ✅ **验证二 (2026-07-29)**：CRC 双层校验机制破解
> - **发现**：多包子包**无帧级 CRC**，Len = chunk_size（非 chunk+2）；Protobuf payload 末尾追加 **Payload 级 CRC-16/CCITT** 2 字节，包含在分包数据流中
> - **验证**：官方 bt.pklg 9/9 多包页面 CRC 全部匹配；缺少此 CRC 的自构造 payload 固件静默丢弃导致黑屏
> - **实测**：添加 Payload 级 CRC 后，通过 macOS bleak 发送自构造多包内容页，**眼镜每行满屏显示约 28 个汉字** ✅

> ✅ **验证三 (2026-07-30)**：无间隙 10 行完美显示
> - **根因**：前置 `\n` 创建空行 0 占据了 10 个视口行位之一，导致：(1) 每 9 行出现 1 行空白间隙；(2) 第 10 行内容被推出视口，仅显示 1px
> - **解决**：**移除前置 `\n`**，直接发送 10 行内容文本 + `line_count=10`。视口本身完整容纳 10 行，无需前置空行
> - **约束**：`line_count` 必须等于 `text.count('\n') + 1`（文本实际行数），否则固件黑屏
> - **实测**：**10 行全部完整显示，无间隙、无裁剪**，每行 28 汉字，页间过渡无缝 ✅

---

## 16. 双向滚动与位置同步实测突破归档 (2026-08-02 100% 完整实测版) 🆕

### 16.1 屏显上电与 Content Buffer 特性
- **页数下发规则 (2026-08-09 实测修正)**：经 `multiprompts.pklg` 物理抓包与 Push ×3 连续真机验证，G2 固件**不强制要求 14 页补满**——按实际有效页数下发（如 4 页文本仅发 Page 0~3）固件也可正常渲染。详见 §19.3。但**当前代码实现采用保守的 14 页补满策略** (`G2ProtocolEncoder.formatTextToPages(targetPageCount: 14)`)，短文本不足 14 页时自动填充空白页，以确保在各种固件版本下的最大兼容性。
- **Content Buffer 特性**：此 Buffer 为 Session 级别的一次性数据接收区，非可热替换的显存缓冲区。一旦 Render Commit (`0x80-00`) 后进入活跃 Session，内容不可覆写 (§23.1)。切换文本的唯一路径是完整的 Session 销毁→重建闭环 (§23.2)。

### 16.2 触控板激活与 `Svc 0x01-20` 前台活跃心跳锁 (关键突破)
- **底层阻断机制**：在 BLE 物理连接正常且能收到 `6402` (PCM 语音流) 的情况下，若滑动镜腿完全收不到 `5402` (`0x06-01`) 的 Notify，是因为眼镜处于系统主菜单/语音交互态，固件未将 Touchpad 事件分发给提词应用。
- **前台焦点锁 (`Svc 0x01-20`)**：
  在 `0x09-20` (Route Switch) 之后，必须跟随下发一包 **`Svc 0x01-20` 前台活跃心跳锁**：
  `AA 21 [Seq] 12 01 01 01 20 08 02 10 [MsgId] 22 0A 1A 08 12 06 12 04 08 01 [CRC]`
  下发后将强行锁定固件的 UI Focus Route，唤醒镜腿 Touchpad 中断并派发至 `0x06-01` 提词监听通道。

### 16.3 Protobuf `Tag 0x52` 与 `Tag 0x5A` 物理双通道分工与 1:1 视口对齐
- **`Tag 0x52` (消息 Type 164 `A4 01`) — 屏显静止/渲染 Telemetry 心跳**：
  $$\text{Payload} = \text{52 02 08 [Line]}$$
  在用户没有任何物理滑动操作时，眼镜固件仍会定期主动上发该数据包，向 APP 广播当前 MicroLED 屏幕物理对齐停留的行号 `Line`（作为 rendering 同步心跳）。
- **`Tag 0x5A` (消息 Type 165 `A5 01`) — 镜腿 Touchpad 物理手势中断**：
  $$\text{Payload} = \underbrace{\text{5A}}_{\text{Tag 11}} \ \underbrace{\text{04}}_{\text{Length 4}} \ \underbrace{\text{08 \ \text{[Code]}}}_{\text{Field 1: 手势 Raw Code (1,2,3,4)}} \ \underbrace{\text{10 \ \text{[Line]}}}_{\text{Field 2: 视口物理行号}}$$
  仅在用户手指物理触摸、按压或滑动镜腿的瞬间爆发上报。
- **1:1 绝对物理行号公式**：
  抓包序列与真机测试证实：`52 02 08 [Line]` 与 `5A 04 08 [Code] 10 [Line]` 末尾字节代表物理递增的连续行号序列 `[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]`：
  $$\text{App 视口对齐行号 (currentLine)} = \text{rawLine}$$
  *(⚠️ 警告：切勿套用 `page * 10` 公式，否则滑动 1 行会导致界面产生 10 倍放大跳跃错位)*。

### 16.4 交互稳定性保护
- **下行覆盖保护**：手势滑动期间**切勿反向向眼镜下发 `Type=3 Content` 页面覆盖包**，避免打乱固件显存流水线引发 MicroLED 关屏保护。

---

## 17. 突破性发现：眼镜向 APP 实时回传文本位置信息协议全解密 (2026-08-02 最新成果) 🆕

经过对官方抓包 `tests/bt2.pklg` 的逐帧透视解密以及反编译 Core 逻辑 (`_handlePageAndLineInfoFromOS`) 的深入追踪，我们彻底破译了眼镜主动向手机 APP 回传当前滚动/滑动文本位置信息的全套通信协议。

### 17.1 物理 GATT 通道与 Notify 使能规范

| 属性 | 物理参数与格式 |
| :--- | :--- |
| **监听 Service ID** | `0x06-01` (`svchi = 0x06`, `svclo = 0x01`) |
| **物理 ATT Handle** | `0x0844`（Notify 接收通道） |
| **物理 Characteristic UUID** | `00002760-08c2-11e1-9073-0e8ac72e5402` |
| **必须的前置操作** | 向 `0x2902` Descriptor 写入 `0x0100` 开启 Notify 订阅使能 |

> ⚠️ **关键根因 1**：若客户端仅开启了 `0x5402` 的 Notify 订阅，或未为 `0x0844` 开启 CCCD 使能，操作系统蓝牙栈将直接丢弃眼镜回发的行位置 Notification 帧！

### 17.2 位置通知报文物理帧结构与 Protobuf Schema

眼镜在镜腿 Touchpad 滑动、匀速滚屏或 AI 跟随滚屏时，每次视口行号发生变动，均会向 APP 发送一帧 `Service 0x0601` 数据包：

### 17.3 动画停止锁定与硬件待命 ACK 报文 (新增) 🆕

在位置心跳（`52 02 08 [Line]`）广播完毕后，眼镜固件会依次吐出两包动作收尾确认包：

1. **画面滚动停止锁定包 (`Type 161` / `0xA1 0x01`)**：
   - **Service**: `0x06-01`
   - **HEX 样本**: `AA 12 AE 0B 01 01 06 01 08 A1 01 10 1B 3A 02 08 04 F8 59`
   - **Protobuf 含义**: `Tag 1 = 161 (0xA1 0x01)`, `Tag 7 = 3A 02 08 04` (`Status Code = 4`)。代表 MicroLED 画面滚动画面的位移计算完毕，视口像素物理锁死停留。
   
2. **显示芯片待命确认包 (`Service 0x0D-01`)**：
   - **Service**: `0x0D-01` (**System Control & Power Management Service**)
   - **HEX 样本**: `AA 12 B4 06 01 01 0D 01 08 01 1A 00 8B DA`
   - **Protobuf 含义**: `Tag 1 = 1` (`08 01`), `Tag 3 = empty` (`1A 00`)。代表眼镜物理显示引擎在画面锁定后，芯片降低功耗切入 Hardware Idle 低功耗待命状态。

```
8-Byte Header:
┌────────┬────────┬────────┬────────┬────────┬────────┬────────┬────────┐
│ Magic  │  Type  │  Seq   │  Len   │  Pkt   │  Pkt   │  Svc   │  Svc   │
│  0xAA  │  0x12  │   ID   │  0x0B  │  0x01  │  0x01  │  0x06  │  0x01  │
└────────┴────────┴────────┴────────┴────────┴────────┴────────┴────────┘
```

**Protobuf Schema 结构：**

```protobuf
syntax = "proto3";
package even.g2;

// Service 0x06-01: G2 -> Phone 实时位置与滚动状态通知
message TeleprompterPositionNotification {
  uint32 event_type = 1;      // 恒为 165 (0xA5)，代表位置/行号变更事件
  uint32 msg_id = 2;          // 消息序列号 (如 94 / 0x5E)
  TeleprompterEventData event_data = 11; // Field 11 (Tag 0x5A)
}

message TeleprompterEventData {
  uint32 current_line = 2;    // Tag 2 (0x10): 当前眼镜屏幕聚焦的实际行号 (0-indexed 整数: 0, 1, 2, 3, 4...)
}
```

### 17.3 抓包数据实测对齐与解密对照表

下表为从官方 APP BLE 抓包 `tests/bt2.pklg` 中提取的眼镜实时滑动上报真实数据帧：

| 时间戳 (s) | 抓包 Payload (Hex) | Protobuf 解码结构 | 上报滚动行位置 |
| :--- | :--- | :--- | :--- |
| `1785413632.187` | `08a501105e5a00` | `{1: 165, 2: 94, 11: {}}` | `Line 0` (初始重置) |
| `1785413632.277` | `08a501105e5a021001` | `{1: 165, 2: 94, 11: {2: 1}}` | **`Line 1`** |
| `1785413632.337` | `08a501105e5a021002` | `{1: 165, 2: 94, 11: {2: 2}}` | **`Line 2`** |
| `1785413632.519` | `08a501105e5a021003` | `{1: 165, 2: 94, 11: {2: 3}}` | **`Line 3`** |
| `1785413632.909` | `08a501105e5a021004` | `{1: 165, 2: 94, 11: {2: 4}}` | **`Line 4`** |

### 17.4 APP 端数据处理逻辑与换算算子

APP 接收到该 Notification 报文后的解调处理链如下：

1. **数据包识别**：校验 Header `magic == 0xAA`，`type == 0x12`，`svc == 0x0601`。
2. **提取 Protobuf 字段**：读取 Field 1 为 `165`，接着解包 Field 11 得到 `event_data.current_line`。
3. **计算绝对行号与页码**：
   - 绝对行号：$\text{currentLine} = \text{event\_data.current\_line}$
   - 所在页码：$\text{pageId} = \lfloor \text{currentLine} / 10 \rfloor$
   - 页内相对行号：$\text{rawLine} = \text{currentLine} \pmod{10}$
4. **状态同步**：调起 `_handlePageAndLineInfoFromOS` 更新 UI 视口高亮行与定位进度条，保持 APP 界面与眼镜 HUD 屏幕的 100% 实时同步。

---

### 17.5 无法获取文本位置信息的 3 大排查方案 checklist

若第三方 App 始终无法获取眼镜发出的位置信息，请按以下顺序排查：

- [ ] **Check 1: CCCD 0x2902 描述符物理使能 (防系统缺报文)**  
  在 UUID `00002760-08c2-11e1-9073-0e8ac72e5402` (`5402` 通道) 上，除调用 iOS `setNotifyValue(true, for: characteristic)` 外，**必须在发现 `0x2902` 描述符后显式向物理 ATT Handle `0x0013` 写入 `Data([0x02, 0x00])` (ENABLE INDICATION)**，对齐官方抓包包 #28，防止 CoreBluetooth 系统未自动下发使能帧。
- [ ] **Check 2: Service ID 匹配规则**  
  确认接收端未过滤 `Service 0x06-01` 数据包（注意：位置通知数据包的 Service ID 是 `0x0601`，而非发文本时的 `0x0620`）。
- [ ] **Check 3: Protobuf Field 11 嵌套解析**  
  确认数据解析器能正确拆解 Tag 11 嵌套消息（`0x5A`），取其中的 Tag 2 (`0x10`) 作为 `current_line`，而非在顶层查找。

---

### 17.6 最新实测抓包 `tests/bt3.pklg` 物理数据全解析 (包含打开 APP 到手势滑动的全过程) 🆕

在对最新的官方 App 物理抓包文件 [tests/bt3.pklg](file:///Users/l.ylive.cn/OneDrive/smart-glass/tests/bt3.pklg)（共 608 个 ACL 报文）解析中，提取到了完整的三大类 `Service 0x06-01` 触控/位置 Notify 事件包：

#### 1. 三大类 Notify 事件类型表 (Event Type / Tag 1)

| Event Type | Hex Tag | 协议含义 | Protobuf 内部 payload 结构 |
| :--- | :--- | :--- | :--- |
| **`Type 164`** | `0xA4` | **页面加截确认 / 页码切换** | Tag 10 (`0x52`): `{ Tag 1 (0x08): page_number }` |


### 6.2 激活眼镜回传文本位置信息的物理流水线与操作规范 🆕 (2026-08-02 专项归纳)

眼镜向 `5402` 信道推送到手机 `Tag 0x5A`（实时滑动手势 `Type 165`）或 `Tag 0x52`（切页/换行位置变更）数据的前提，是手机端必须按顺序完成以下 **5 步物理激活流水线**：

```mermaid
sequenceDiagram
    autonumber
    participant Phone as 📱 iOS Gateway
    participant BLE as 📡 BLE Channel 5401/5402
    participant G2 as 👓 G2 Glass MCU

    Phone->>BLE: 1. 写入 0x2902 CCCD 描述符 (setNotifyValue = true)
    BLE-->>G2: 激活 5402 Notify 硬件物理通道
    Phone->>BLE: 2. 下发 Auth 鉴权 1~7 帧 (0x80-00 / 0x80-20)
    BLE-->>G2: 会话已鉴权 (Session Authenticated)
    Phone->>BLE: 3. 下发 Setup 基础设施 (0x1F-20 中断使能 + 0x30-20 事件监听)
    BLE-->>G2: 触控板 (Touchpad) 硬件中断路由器就绪
    Phone->>BLE: 4. 下发 App 聚焦指令 (0x09-20 target=1)
    BLE-->>G2: 窗口管理器绑定当前 Touchpad 焦点至 HUD 前台
    Phone->>BLE: 5. 下发 TeleprompterInit (0x06-20 render_mode=9, scroll_mode=1)
    BLE-->>G2: 初始化提词画卷视口
### 6.2 Touchpad 触控板滑动通知回传物理规范 (Tag 0x5A / Tag 0x52)

根据 `tests/bt3.pklg` 抓包解调，真正的 Touchpad 触控滑动与行号位置回传具有极其严格的物理格式：

#### 物理上报特征：
- **物理通道**：GATT Characteristic `00002760-08c2-11e1-9073-0e8ac72e6402` (`5402` 通道)
- **帧头特征**：必须以 **`AA 12`** 协议头部开头
- **服务编号**：必须为 **`Service 0x06-01`** (提词器位置/手势服务)
- **数据帧长度**：**19 字节 ~ 21 字节**
- **核心 Payload 字段**：
  - `Tag 0x5A` (Type 165): Touchpad 实时滑动手势 (例如: `AA 12 ... 08 A5 01 10 32 5A 04 08 01 10 03`)
  - `Tag 0x52` (Type 164): 页面加载/行位置变更 (例如: `AA 12 ... 08 A4 01 10 1C 52 00`)
  - `Tag 0x72` (Type 167): 边界换页请求 (例如: `AA 12 ... 08 A7 01 10 31 72 02 10 06`)

1. **GATT 层 CCCD 订阅**：在 CoreBluetooth 发现 `5402` 特征后，执行 `peripheral.setNotifyValue(true, for: char5402)`，打开硬件 Notify 通道。
2. **会话鉴权 ACK**：下发 7 包 Auth 帧，确保 G2 Window Manager 的安全策略解除对后续控制指令的封锁。
3. **触控中断路由使能**：下发 **`Service 0x1F-20`** (`AA 21 08 0A 01 01 1F 20 08 00 10 08 1A 02 08 01 A9 B3`) 与 **`Service 0x30-20`** (`AA 21 0B 0C 01 01 30 20...`)，激活底层触控板物理中断。
4. **前台应用焦点绑定**：下发 **`Service 0x09-20`** (`AA 21 15 0A 01 01 09 20 08 02 10 17 22 02 08 01...`)，将触控中断事件路由至当前提词前台容器。
```

#### 🎯 激活位置回传的 5 大关键物理要素：

1. **GATT 层 CCCD 订阅**：在 CoreBluetooth 发现 `5402` 特征后，执行 `peripheral.setNotifyValue(true, for: char5402)`，打开硬件 Notify 通道。
2. **会话鉴权 ACK**：下发 7 包 Auth 帧，确保 G2 Window Manager 的安全策略解除对后续控制指令的封锁。
3. **触控中断路由使能**：下发 **`Service 0x1F-20`** (`AA 21 08 0A 01 01 1F 20 08 00 10 08 1A 02 08 01 A9 B3`) 与 **`Service 0x30-20`** (`AA 21 0B 0C 01 01 30 20...`)，激活底层触控板物理中断。
4. **前台应用焦点绑定**：下发 **`Service 0x09-20`** (`AA 21 15 0A 01 01 09 20 08 02 10 17 22 02 08 01...`)，将触控中断事件路由至当前提词前台容器。
5. **视口模式参数**：在下发 `TeleprompterInit` (`0x06-20`) 时，指定 `render_mode = 9`（全屏模式）且 `scroll_mode = 1`（AI/交互滚动模式）。

#### 6.3 `tests/bt3.pklg` 核心滑动事件抓包片断物理明细

```text
📍 [包 #105] G2->Phone (Rx) | Svc: 0x06-01 | Frame: AA 12 6E 09 01 01 06 01 08 A4 01 10 1C 52 00 C3 6A
   => Type 164 (0xA4) 页面加载确认，当前为 Page 0

📍 [包 #357] G2->Phone (Rx) | Svc: 0x06-01 | Frame: AA 12 53 0D 01 01 06 01 08 A5 01 10 23 5A 02 10 01 FB DB
   => Type 165 (0xA5) 镜腿 Touchpad 滑动手势，定位到 Page 0 的 Line 1

📍 [包 #419] G2->Phone (Rx) | Svc: 0x06-01 | Frame: AA 12 1D 0D 01 01 06 01 08 A5 01 10 34 5A 04 08 01 10 03 67 D9
   => Type 165 (0xA5) 镜腿 Touchpad 滑动手势，定位到 Page 1 的 Line 3

📍 [包 #458] G2->Phone (Rx) | Svc: 0x06-01 | Frame: AA 12 4D 0B 01 01 06 01 08 A7 01 10 35 72 02 10 08 26 BE
   => Type 167 (0xA7) 滑动触及页末，请求装载 Page 8
```

#### 3. 初始连接使能 CCCD 物理句柄
在 `bt3.pklg` 包 #28 中，官方 APP 在初始化阶段显式向 **ATT Handle `0x0013`** (即 `5402` 特征的 CCCD 描述符) 写入了 **`0x0002` (ENABLE INDICATION / NOTIFICATION)**，拉通了物理 Notify 数据管道。

---

## 18. 基于逆向工程规范的 iOS App 物理协议与业务单元测试用例全集 (XCTest & Mock Specs) 🆕

为确保开发中的 iOS Gateway App 与 Even G2 物理硬件及官方协议 100% 兼容，基于前述逆向拆解与协议解密结论，制定以下 5 大核心模块的单元与集成测试用例：

### 18.1 模块 1：CRC16 校验与 8-Byte Header 帧编码测试 (`G2ProtocolEncoderTests`)

#### 用例 TC-BLE-001：单包 8-Byte Header 结构断言
- **测试目的**：验证单包数据下发时的 Header 格式、Sequence 自增及 Len 计算正确性。
- **输入数据**：`seq = 0x08`, `service_hi = 0x06`, `service_lo = 0x20`, `payload = [0x08, 0x01]` (2 字节)
- **断言条件**：
  1. `header[0] == 0xAA` (Magic)
  2. `header[1] == 0x21` (Command Type)
  3. `header[2] == 0x08` (Sequence ID)
  4. `header[3] == 0x04` (`payload.count + 2` 字节)
  5. `header[4] == 0x01` (`pktTot == 1`)
  6. `header[5] == 0x01` (`pktSer == 1`)
  7. `header[6..7] == [0x06, 0x20]` (Service ID)

#### 用例 TC-BLE-002：单包 CRC16-CCITT 校验码追加断言
- **测试目的**：验证单包模式下只对 Payload 计算 CRC16，并以 Little-Endian 追加于帧末尾。
- **输入 Payload**：`[0x08, 0x01, 0x10, 0x14]`
- **预期输出末尾 2 字节**：匹配 `crc16_ccitt([0x08, 0x01, 0x10, 0x14], init: 0xFFFF)` 的 Little-Endian 字节序。

#### 用例 TC-BLE-003：多包切片 Payload-level CRC16 断言
- **测试目的**：验证当 Payload 超过 232 字节时，启用多包切片规则：子包单包不含帧级 CRC，且全量 Protobuf CRC16 追加在消息末尾。
- **输入 Payload**：500 字节的 Protobuf 文本数据。
- **断言条件**：
  1. 生成 3 个子包（`pktTot == 3`），各子包 `pktSer` 分别为 1, 2, 3。
  2. 子包 1 与子包 2 的 `Len` 字段恰好为 `232` (`0xE8`)。
  3. 最后一个子包末尾包含原始 Payload 计算所得的 2 字节 CRC-16/CCITT。

---

### 18.2 模块 2：TeleprompterInit 与 DisplayConfig 精确参数校验测试

#### 用例 TC-CFG-001：TeleprompterInit 官方全屏排版参数校验
- **测试目的**：防止代码错误回退到社区早期 644/230 视口模式，确保使用官方实测解封参数。
- **输入构建**：调用 `G2ProtocolEncoder.buildTeleprompterInit()`
- **断言条件**：
  1. Field 4 (`display_width`) 必须为 **`59`**（非 644/267）。
  2. Field 6 (`line_height`) 必须为 **`567`** (`0xB7 0x04`)。
  3. Field 7 (`viewport_height`) 必须为 **`3113`** (`0xA9 0x18`)。
  4. Field 8 (`font_size`) 必须为 **`0`**。
  5. Field 10 (`render_mode`) 必须为 **`9`**。

#### 用例 TC-CFG-002：DisplayConfig 物理 Region 0-9 边界校验
- **测试目的**：验证屏幕布局配置包含 Region 9 且 Region 参数均被置零。
- **断言条件**：
  1. 编码输出必须包含 Region 2, 3, 4, 5, 6, 9 的定义。
  2. 所有 Region 的 `width` 与 `height` float 值均等于 `0.0f`。

---

### 18.3 模块 3：14 页缓冲补满与 28 汉字自动换行测试 (`G2ProtocolEncoderTests`)

> ⚠️ **代码对齐说明 (2026-08-09)**：虽然 §19.3 官方抓包证实固件接受按需下发，但当前代码实现 `G2ProtocolEncoder.formatTextToPages(targetPageCount: 14)` 采用保守的 14 页补满策略以确保最大兼容性。以下测试断言与**代码实现**对齐。

#### 用例 TC-TXT-001：28 中文字符（56 CJK 宽度）单行截断测试
- **测试目的**：验证单行文本在超过 28 个中文字符时自动执行无破坏换行。
- **输入文本**：`"今天我们召开《人机协同程序设计》课程全校统一数智化教学集体备课研讨会"` (35 字)
- **断言条件**：
  1. 拆分出的第一行恰好包含 28 个中文字符。
  2. 剩余 7 个字符自动移至第二行。

#### 用例 TC-TXT-002：文本前置 `\n` 空行剥离断言
- **测试目的**：防止首行附带 `\n` 浪费视口 10 行之一的位置。
- **输入文本**：`"\nhello world"`
- **断言条件**：格式化后的首页内容不得包含前置 `\n`，`line_count` 恰好等于 `text.components(separatedBy: "\n").count`。

#### 用例 TC-TXT-003：14 页缓冲补满测试
- **测试目的**：验证短文本（如仅 1 页）下发时，`G2ProtocolEncoder.formatTextToPages()` 自动填充空白页补满至 14 页 Buffer 槽位。
- **输入文本**：仅包含 5 行内容的短正文（1 页）。
- **断言条件**：`formatTextToPages()` 输出的数组长度 `pages.count >= 14`，每页精确包含 10 行（以 `\n` 分隔），且首页首行不为空。

---

### 18.4 模块 4：眼镜位置通知解调与页码/行号换算测试 (`BLEPositionNotificationTests`)

#### 用例 TC-NOTIFY-001：0x2902 CCCD Notify 订阅使能验证
- **测试目的**：验证蓝牙连接成功后对 Notify 特征值 `00002760-08c2-11e1-9073-0e8ac72e5402` 执行订阅。
- **Mock 环境**：传入 Mock `CBPeripheral`
- **断言条件**：
  1. 必须调用 `setNotifyValue(true, for: characteristic)`。
  2. 特征值 UUID 必须等于 `0x5402` (监听通道)。

#### 用例 TC-NOTIFY-002：Type 165 (0xA5) 位置 Notification 解析测试
- **测试目的**：验证收到眼镜发出的 `0x0601` Notify 帧时，能提取 Tag 11 里的 `current_line`。
- **模拟接收 Raw Hex**：`AA 12 47 0B 01 01 06 01 08 A5 01 10 5E 5A 02 10 03 64 D7`
- **断言条件**：
  1. 解密解析出 `event_type == 165`。
  2. 解析出 `current_line == 3`。

#### 用例 TC-NOTIFY-003：_handlePageAndLineInfoFromOS 行号与页码计算断言
- **测试目的**：验证绝对行号到 App UI 页码与行高亮卡片定位的计算逻辑。
- **输入行号**：`current_line = 23`
- **断言条件**：
  1. 计算出的页码 `pageId == 2` ($\lfloor 23 / 10 \rfloor$)。
  2. 页内相对行号 `rawLine == 3` ($23 \pmod{10}$)。
  3. UI 控制器激活的滑动卡片索引为 23。

---

### 18.5 模块 5：Apple Watch 手势防抖与设备控制测试 (`WatchGestureTests`)

#### 用例 TC-WATCH-001：CoreMotion 手腕甩动与 Double Tap 1.5s 防抖窗口测试
- **测试目的**：防止手腕快速晃动导致连发多次切页。
- **输入序列**：在 0.2s 内连续触发 3 次手腕甩动手势事件。
- **断言条件**：
  1. 仅第 1 次手势成功向 BLE 队列发出 `PAGE_CONTROL(action: NEXT)` 指令。
  2. 后续 2 次手势被防抖定时器拦截丢弃。
  3. 手表端仅在第 1 次产生 `.click` 触觉震动反馈。

#### 用例 TC-WATCH-002：HUD 显存休眠/唤醒指令响应测试
- **测试目的**：验证在 Watch 点击 `👁️` 控件发送 `SLEEP_HUD` 指令时，BLE 侧及时下发屏显休眠帧。
- **输入 Action**：`SLEEP_HUD`
- **断言条件**：下发 `TeleprompterState(state: 4)` 停能屏显或下发 Display Sleep 特征帧，更新本地 HUD 激活状态标记 `isHUDActive == false`。

---

## 19. 物理真相解密：Even Realities G2 固件状态机与触控中断路由器激活 (2026-08-02 最新成果) 🆕

在对最新的官方 App 物理抓包文件 [tests/bt3.pklg](file:///Users/l.ylive.cn/OneDrive/smart-glass/tests/bt3.pklg) 的逐字节差分提取中，我们彻底澄清了 G2 固件内部的完整状态迁移机制，并破译了镜腿 Touchpad 触控板硬件中断路由器的激活协议。

### 19.1 G2 固件全生命周期状态机 (State Diagram)

```mermaid
stateDiagram-v2
    [*] --> BLE_Disconnected : 硬件静置 / 广播模式

    state "1. 蓝牙物理连接阶段" as Stage1 {
        BLE_Disconnected --> GATT_Services_Discovered : CoreBluetooth 连接成功
        GATT_Services_Discovered --> GATT_CCCD_Subscribed : 使能 5402/6402 Notify 特征通道
    }

    state "2. 链路鉴权与就绪阶段" as Stage2 {
        GATT_CCCD_Subscribed --> Auth_Handshake : 手机下发 Tx 80-00 / 80-20 (Auth 1~7 帧)
        Auth_Handshake --> Auth_Session_Ready : 眼镜回吐 Rx 80-00 / 80-01 (Ack 确认)
    }

    state "3. 硬件总线与应用路由切换阶段" as Stage3 {
        Auth_Session_Ready --> System_Router_Registered : Tx 07-20 / 03-20 / 0C-20 (全局布局与视口 DPI 注册)
        System_Router_Registered --> Event_Input_Registered : Tx 0D-20 / 30-20 (输入设备注册 & 物理事件监听器使能)
        Event_Input_Registered --> App_Focus_Activated : Tx 09-20 / 1F-20 / 10-20 (切换前台 App, 激活 Touchpad 触控中断与功耗策略)
        App_Focus_Activated --> Hardware_Bus_Ready : 眼镜回吐 Rx 09-00 / 10-00 (硬件中断就绪)
    }

    state "4. 画面渲染与视口初始化阶段" as Stage4 {
        Hardware_Bus_Ready --> Display_Memory_Allocated : Tx 0E-20 (DisplayConfig 显存分配)
        Display_Memory_Allocated --> MicroLED_Bus_Power_On : Tx 04-20 (Display Wake 唤醒 MicroLED 光学总线电源)
        MicroLED_Bus_Power_On --> Teleprompter_Engine_Init : Tx 06-20 (TeleprompterInit, 0x48 0x01)
        Teleprompter_Engine_Init --> Touchpad_Router_Mounted : Tx 81-20 / 20-20 (Display Trigger 物理显示触发 & 显存 Commit 提交)
    }

    state "5. 全屏提词与交互主循环" as Stage5 {
        Touchpad_Router_Mounted --> Active_Teleprompter_Rendering : Tx 06-20 (Content Slices, type=3) + 80-00 Sync
        
        state Active_Teleprompter_Rendering {
            [*] --> Page_View_Displaying : 视口对齐当前 Page / Line
            
            state "触控与位置双向交互" as TouchInteraction {
                Page_View_Displaying --> Realtime_Scroll : 镜腿滑动 (Touchpad Slide)
                Realtime_Scroll --> Gesture_Notification : 眼镜向上推屏 Rx 06-01 (Type 165 Scroll)
                Gesture_Notification --> Viewport_Line_Updated : 手机更新当前焦点 Line
                
                Page_View_Displaying --> Page_Boundary_Trigger : 翻页触底 (Boundary Touch)
                Page_Boundary_Trigger --> Page_Switch_Notification : 眼镜向上推屏 Rx 06-01 (Type 167 Boundary)
                Page_Switch_Notification --> Next_Slice_Fetched : 手机按需下发下一页 Slice
                
                Viewport_Line_Updated --> Bidirectional_Sync : 手机反馈 Tx 06-20 (Type 5 Position Sync)
                Bidirectional_Sync --> Page_View_Displaying
            }
        }
    }

    state "6. 模式退出与状态复位" as Stage6 {
        Active_Teleprompter_Rendering --> Teleprompter_Session_Reset : 手机下发 Tx 06-20 (type=4, state=4)
        Teleprompter_Session_Reset --> System_Router_Registered : 卸载 HUD 界面，退回仪表盘主菜单
    }

    BLE_Disconnected --> [*]
```

---

### 19.2 关键硬件突破：Service `0x09-20` 前台应用聚焦与触控中断激活协议

在物理抓包 `OfficialRawPkts.swift` [Pkt 21, 22] 中，解密出官方 APP 下发的核心底层中断激活指令：

```text
[Pkt 21] Seq: 0x15 | Service: 0x09-20 | Hex: aa21150a010109200802101722020801c31b
[Pkt 22] Seq: 0x16 | Service: 0x09-20 | Hex: aa21160a0101092008021018220208013a7e
```

- **物理 Service ID**：`0x09-20`（`svchi = 0x09`, `svclo = 0x20`）
- **Protobuf Payload 结构**：
  ```protobuf
  // Service 0x09-20: App Focus & Touchpad Interrupt Router Switch
  message AppFocusControl {
    uint32 type = 1;       // Tag 1 (0x08): 恒为 2
    uint32 msg_id = 2;     // Tag 2 (0x10): 递增消息 ID
    AppTarget target = 4;  // Tag 4 (0x22): { Tag 1 (0x08): 1 (表示前台聚焦并绑定触控板) }
  }
  ```
- **硬件作用机制**：在 Auth 鉴权完成后，若不发送 `0x09-20`，眼镜 MCU 的 Touchpad 触控板硬件中断总线将处于关断状态。唯有下发 `0x09-20` 之后，镜腿手势滑动的物理中断信号才会被正确分配给当前前台应用，进而触发 `Service 0x06-01` (`5402` 通道) 的手势 Notification 上报。

### 19.3 讲稿文本分包下发物理规范

对 `bt3.pklg` 全包中 11 包 Content Page（`Pkt #0576 ~ #1352`）的 Protobuf 解析证实了官方 APP 的真实下发规则：

1. **按需下发真实有效页数**：官方 APP 严格根据讲稿内容实际切割出的有效页数进行下发（如抓包 `bt3.pklg` 中长文本切出 11 页，则下发 `Page 0 ~ Page 10` 共 11 包；若短文本切出 4 页，则仅下发 `Page 0 ~ Page 3` 共 4 包）。
2. **拒绝强行空页补齐**：当讲稿实际内容发送完毕后，官方 APP **绝对不会强行填充全空假页面（`\n\n\n...`）去补满 14 页**。
3. **数据包 Service 认定**：下发讲稿 Content 页面时，使用物理抓包验证的 **`Service 0x06-20` (type=3)**，绝不可与系统布局包 `0x01-20` (type=2) 混淆。

> ⚠️ **代码实现差异说明 (2026-08-09)**：以上 3 条规则描述的是**官方 APP 的物理抓包行为**。当前我方代码实现 `G2ProtocolEncoder.formatTextToPages(targetPageCount: 14)` 采用**保守的 14 页补满策略**——短文本自动填充空白页至 14 页 Buffer 槽位。两种策略在固件端均可正常工作（§16.1 真机验证），代码端选择补满是为确保最大兼容性。

---

## 20. 1:1 官方物理发包引擎与 Touchpad 镜腿手势通道解析规范 (2026-08-02 确凿核验版) 🆕

本章总结了对 `bt2.pklg` / `bt3.pklg` / `test2.pklg` 全部物理抓包逐帧分析与物理 iPhone/G2 眼镜调试验证出的权威底层结论。

### 20.1 物理发包机制：一问一答 Lock-Step 步进协议与 120ms Pacing 保护 (Lock-Step Ack-Driven Pacing)
1. **传输层停顿等待与 120ms 发包硬隔离**：
   - 官方 App 并非高频连续盲发。在物理信道上，App 发出 1 包 `Tx` 后，在 BLE 信道上停顿 170ms~260ms **等待眼镜固件在 `5402` 回传 `Rx ACK` (Svc 80-00 / 80-01)**；
   - 收到 ACK 确认后，App 延迟 80ms~120ms 再下发下一包 `Tx`；
   - **🚨 显像芯片死锁黑屏根因**：盲目机械按 20ms~30ms 连续高频连发会导致 G2 蓝牙接收 Buffer 溢出与 MicroLED 显像芯片死锁，引发显像投影灯泡保护性熄灭（黑屏）。必须引入不少于 `120ms` 的物理发包硬隔离保护 (`lastBt3SendTime`)！
2. **250ms 超时保底引擎 (Ack-with-Timeout)**：
   - 实现端应采用 ACK 驱动 + 120ms 间隔保护 + 250ms 超时保底下发，既保证 100% 匹配官方物理节奏，又防止丢包导致流程卡死。

### 20.2 提词器硬件触控激活关键序列 (Pkts 40 & 41)
在下发完正文预加载数据（Page 0~3，即前 39 包）后，必须紧接着下发 2 包关键的硬件路由使能帧：
- **Pkt 40 (Service `0x04-20`)**：`AA 21 23 10 01 01 04 20 08 01 10 23 1A 08 08 00 10 00 18 00 28 01 4E CE` (通知固件挂载 HUD 视口渲染容器)
- **Pkt 41 (Service `0x09-20`)**：`AA 21 24 22 01 01 09 20 08 01 10 24 1A 1A 52 18 0A 06 08 00 10 00 18 00 0A 06 08 00 10 01 18 00 0A 06 08 00 10 02 18 00 89 5E` (包含 3 个 `0A 06 08 00 10 0x` 路由表，**将 0/1/2 三号 Touchpad 手势路由强制绑定并聚焦到提词前台**)。

### 20.3 Touchpad 触控切页 Notify 物理二进制结构
当用户滑动镜腿时，G2 固件在 `5402` 特征值上传回的切页 Notification 物理字节为：
```
Pkt Hex: AA 12 [Seq] [Len] 01 01 06 01 08 A4 01 10 1C 52 02 08 [PageNum] [CRC16]
```
### 20.5 提词器前置 Setup 6 包信令映射表 (2026-08-09 真机验证版)

在完成基础 4 包 Auth 鉴权后、正式下发 `0x06-20` TeleprompterInit 之前，必须按顺序下发以下 **6 包**系统 Setup 信令（原 bt3.pklg 中为 11 包，经真机验证精简为 6 包最小可用集）：

| 顺序 | Service ID | 代码函数 | 物理作用与含义 | 状态 |
| :--- | :--- | :--- | :--- | :--- |
| **Pkt 5** | `Service 07-20` | `buildOfficialSetupSequence[1]` | 建立全局 Viewport 视口容器 | ✅ 必须 |
| **Pkt 6** | `Service 03-20` | `buildOfficialSetupSequence[2]` | 配置系统级 Layout 画布参数 (8 区域 DPI 点阵) | ✅ 必须 |
| **Pkt 7** | `Service 0C-20` | `buildOfficialSetupSequence[3]` | 激活 Display 显示通道配置 | ✅ 必须 |
| ~~Pkt 8~~ | ~~`Service 30-20`~~ | ~~已注释跳过~~ | ~~系统模式切换~~ | 🚫 **禁止发送** (触发 Session Terminated 黑屏) |
| **Pkt 8** | `Service 0D-20` | `buildOfficialSetupSequence[4]` | 状态同步指示 | ✅ 必须 |
| **Pkt 9** | `Service 09-20` | `buildOfficialSetupSequence[5]` | Touchpad Listener 触控监听注册 | ✅ 必须 |
| **Pkt 10** | `Service 1F-20` | `buildOfficialSetupSequence[6]` | Focus State 焦点状态绑定 (`1A 02 08 01`) | ✅ 必须 |

> 🚨 **【关键禁令 1】** `Service 0x30-20` (Event Trigger Setup) **绝对禁止在提词推屏序列中发送**！发送会导致 MCU 主动抛出 `0D-01 Session Terminated`，瞬间销毁整个画布并黑屏。

> 🚨 **【关键禁令 2】** Setup 序列中**绝对禁止包含 `22 02 08 01`**（Dashboard 0x01 切主页指令）！否则在下发正文前会将显存视口强行切回桌面黑屏。

**官方 bt3.pklg 中存在但当前实现已验证可省略的包** (不影响 Push ×3 真机验证)：
- `0x10-20` Power & Sleep Control (功耗策略)
- `0x09-20` App Focus Lock ×2 (焦点锁定)
- `0x01-20` Pipeline Layout Ready (画布就绪帧)

### 20.6 官方 Native 二进制 `libapp.so` 原生符号验证与 1:1 行号映射更正 (2026-08-03)

通过提取官方应用 `libapp.so` 中的 Dart AOT 原生编译符号与实机物理验证，确定了官方 App 处理提词器位置与手势的绝对底层依据：

1. **底层状态控制器**：
   - 官方 App 内部通过 `_TeleprompterBaseV2.currentLine` 记录并维护全局当前绝对行号。
2. **手势事件处理方法**：
   - 当接收到 G2 智能眼镜发回的 Notify 时，官方 Dart 引擎调用的原生解调入口函数名为 **`handlePageScrollEvent`**。
3. **物理 1:1 绝对行号映射（实测更正）**：
   - `handlePageScrollEvent` 上报的 `Tag 0x52` (视口渲染对齐)、`Tag 0x5A` (触控板滑动) 和 `Tag 0x72` (触及页界) 中的 `PageNum` / `Line` 字段**本身就是从 0 开始计数的绝对行号索引 (`Line 0`, `Line 1`, `Line 2`...)**。
   - **绝对禁止乘以 10**！乘以 10 会导致滑动 1 行在 App UI 上放大跳跃 10 行。

---

## 21. v2.0.0 大版本物理协议实测修正与归档 (2026-08-03) 🆕

经过物理 iPhone + G2 智能眼镜真机联调，v2.0.0 版本完成了对底层 BLE 协议的全面修正与实测验证：

### 21.1 核心修复突破列表
1. **MicroLED 物理显像点亮**：
   - 物理补齐 `0C-20` 供电与 `30-20` 光机点灯；
   - 剔除 `22 02 08 01` (Dashboard 0x01 切主页)，锁定 `0x52` 提词前台视口；
   - 结果：白色/绿色提词文本在眼镜 MicroLED 镜片上 100% 成功点亮与显示。
2. **发包节奏与 120ms 间隔保护**：
   - 引入 `lastBt3SendTime` 保护，强制发包间隔不少于 `120ms`；
   - 结果：消灭高频连发引发的 G2 蓝牙 RX Buffer 溢出与 MicroLED 显像芯片死锁黑屏。
3. **1:1 视口跟随与行号精准换算**：
   - 废除 `* 10` 错误逻辑，直接将遥测 Page 0 映射为 Line 0，Page 2 映射为 Line 2；
   - 结果：App 控制台与 UI 视口卡片 100% 实时平滑跟随镜腿滑动位置。
4. **眼镜主动退出物理解析**：
   - 解析 `Service 0D-01` (`1A 00` Session Terminated) 与 `01-01` (`08 03` 镜腿长按手势)；
   - 结果：App 毫秒级捕获眼镜端主动退出，更新 `isTeleprompterSessionActive = false`。

---

## 22. 官方 APP 手机端滑动信令与主动退出流程权威解调 (基于 app-control.pklg 2026-08-03) 🆕

本章总结了对官方 APP 与 G2 眼镜真实交互抓包 `app-control.pklg`（130 包全量 GATT 帧）的物理解调结论：

### 22.1 官方 APP 手机端主动滑动信令：`Service 0x06-20 Type 165 (08 A5 01)`
抓包彻底澄清了第三方发包无响应的物理根因：**官方 APP 手机端拖拽滑动时，下发的并非 Type 5 (`08 05`)，而是 Type 165 (`08 A5 01`)**！

**物理 Packet 结构**：
```text
AA 21 [Seq] [Len] 01 01 06 20 08 A5 01 10 [MsgId] 5A 04 08 [Page] 10 [Line] [CRC16]
```
- **Service ID**：`0x06-20` (提词器数据服务)
- **Type 编码**：`08 A5 01` (Protobuf Varint 编码的 `Type 165`)
- **Tag 11 (`0x5A`) 负载**：`5A 04 08 [Page] 10 [Line]`
  - `08 [Page]` ➔ 页码索引（`Line / 10`）
  - `10 [Line]` ➔ 页内相对行号（`Line % 10`）

**抓包物理帧验证记录**（`app-control.pklg` Pkts #065 ~ #119）：
- `Pkt #065`: `08 A5 01 10 35 5A 04 08 00 10 08` ➔ 手机驱动眼镜定位至 Page 0, Line 8
- `Pkt #071`: `08 A5 01 10 37 5A 04 08 01 10 09` ➔ 手机驱动眼镜定位至 Page 1, Line 9
- `Pkt #080`: `08 A5 01 10 3A 5A 04 08 03 10 02` ➔ 手机驱动眼镜定位至 Page 3, Line 2
- `Pkt #090`: `08 A5 01 10 3D 5A 04 08 04 10 04` ➔ 手机驱动眼镜定位至 Page 4, Line 4
- `Pkt #096`: `08 A5 01 10 3F 5A 04 08 05 10 03` ➔ 手机驱动眼镜定位至 Page 5, Line 3
- `Pkt #103`: `08 A5 01 10 41 5A 04 08 06 10 04` ➔ 手机驱动眼镜定位至 Page 6, Line 4
- `Pkt #109`: `08 A5 01 10 43 5A 04 08 07 10 09` ➔ 手机驱动眼镜定位至 Page 7, Line 9
- `Pkt #119`: `08 A5 01 10 47 5A 04 08 08 10 05` ➔ 手机驱动眼镜定位至 Page 8, Line 5

### 22.2 官方 APP 主动退出提词模式全套 4 步信令序列
抓包归档了官方 APP 用户点击“退出提词”时，手机与眼镜间的标准 4 步优雅退出握手（Pkts #126 ~ #130）：

1. **Step 1 (App ➔ Glass, Pkt #126)**：
   App 发送 `Service 0x06-20 Type 1 (state=4)` 提词前台会话释放报文：
   `AA 21 [Seq] 0B 01 01 06 20 08 01 10 [MsgId] 1A 02 08 04 [CRC16]`
2. **Step 2 (Glass ➔ App, Pkt #127)**：
   眼镜 MCU 回复 `Service 0x06-00 ACK` 确认包：
   `AA 12 [Seq] 09 01 01 06 00 08 A6 01 10 [MsgId] 62 00 [CRC16]`
3. **Step 3 (App ➔ Glass, Pkt #128) — ⚠️ 关键触发帧**：
   App 发送 `Service 0x80-00 Render Commit` 报文（切回 Dashboard 界面）：
   `AA 21 [Seq] 08 01 01 80 00 08 0E 10 [MsgId] 6A 00 [CRC16]`
   > 🚨 **`0x80-00` 在退出序列中的关键作用**：此帧并非可选操作——它是触发 MCU 执行物理 Session 注销并回发 `0D-01 Session Terminated` 的**必要因果条件**。若 Step 1 发送 `state=4` 后不跟随 `0x80-00` Render Commit，MCU 将保持半关闭状态，不回发 `0D-01`，导致后续热重推流程无法收到 Session Terminated 确认而卡死。当前代码实现中 Step 1 与 Step 3 之间间隔 100ms (`BLEManager.sendExitTeleprompterMode()`)。
4. **Step 4 (Glass ➔ App, Pkt #130)**：
   眼镜 MCU 主动上报 `Service 0D-01` 状态解除通知：
   `AA 12 [Seq] 06 01 01 0D 01 08 01 1A 00 [CRC16]`
   ➔ 提词前台物理会话彻底注销，光机切回 Dashboard 桌面。

---

## 23. 官方连续推送文本 (Multi-Prompts Push) 与 Session 优雅销毁闭环 (基于 multiprompts.pklg 2026-08-04) 🆕

本章解密了在提词会话处于活跃状态时，官方 APP 如何处理用户连续推送新文本/切换讲稿的协议细节：

### 23.1 物理抓包事实证明：G2 MCU 不支持在活跃 Session 内直接覆写文本
经 `multiprompts.pklg` 185 包蓝牙 GATT 数据分析证实：**官方 Even AI APP 也无法做到在不销毁当前会话的情况下直接覆写新文本**。
当用户在官方 APP 中点按新文本推送时，官方 APP 绝不强行覆写，而是严格遵循 **“优雅销毁旧 Session ➔ 等待 MCU 物理注销 ➔ 冷启动全新 Session”** 闭环：

### 23.2 连续推送全套 3 阶段信令闭环

```text
阶段 1：旧会话优雅销毁 (App ➔ Glass)
────────────────────────────────────────────────────────────────
AA 21 41 0A 01 01 06 20 08 01 10 41 1A 02 08 04 [CRC16]
└─ Service 0x06-20 Type 4 State 4 (发送退出/释放会话指令)

阶段 2：等待眼镜 MCU 销毁确认 (Glass ➔ App) + 3s 超时保底
────────────────────────────────────────────────────────────────
AA 12 60 06 01 01 0D 01 08 01 1A 00 [CRC16]
└─ Service 0x0D-01 Session Terminated Notify (眼镜物理注销完成)

⏱️ 3s 超时保底机制 (BLEManager.rePushTimeoutWorkItem)：
   若发送 state=4 + 0x80-00 后 3 秒内未收到 0D-01 Session Terminated
   确认，代码将强制重置 Session 状态并自动触发冷启动重推，
   防止因 BLE 丢包或 MCU 异常导致重推流程永久卡死。

阶段 3：收到 0D-01 确认后全新推流 (App ➔ Glass)
────────────────────────────────────────────────────────────────
（经 multiprompts.pklg 抓包证实：已建立的 BLE 连接无须重发 Auth 7 包及 0x30-20 系统模式重置包，直接切入 0x06-20 提词层）：
1. Teleprompter Init (0x06-20 Type 1, 动态递增 MsgId)
2. Pages Data (0x06-20 Type 3 Page 0 ~ N-1, 每页动态递增 MsgId)
   当前代码实现: 短文本自动补满至 14 页 (Page 0 ~ 13)
3. HUD Mount (0x04-20) & Touchpad Router (0x09-20)
4. Render Commit (0x80-00 提交渲染)
5. ScrollSync Line 0 (0x06-20 Type 165 视口终点对齐)
```

### 23.3 避坑指南：连续发包常见死锁与黑屏根因

1. **强行在活跃 Session 下发 0x30-20 / Setup 信令**：
   - 现象：MicroLED 光机瞬间**黑屏**；
   - 根因：在 BLE 链路已握手就绪时重复下发 `0x30-20 System Mode`，导致 MCU 将物理模式强制复位。
   - 正确做法：必须先等待 `0x0D-01 Session Terminated` 确认，收到确认后跳过 Auth/Setup，直接发送 `0x06-20 TeleprompterInit` 进行新讲稿初始化。
2. **重推时漏重置 `isPushingText` 标记**：
   - 现象：不关蓝牙无法第二次推送；
   - 根因：首次发包完成后 `isPushingText` 锁未复位，后续推送全部被 `if isPushingText { return }` 拦截抛弃。
3. **BLE Sequence 序列号倒退 (Rollback)**：
   - 现象：推送第二篇讲稿时眼镜显示 `Session Terminated`；
   - 根因：固件校验发现新包 Seq 小于上一包 Seq，触发底层断开防护。
   - ⚠️ 补充：经 §23.2 验证，MCU 收到 `0x0D-01 Session Terminated` 后会重置 Seq 计数器，因此重推时从 Seq=1 重新开始是安全的（官方 APP 的 Auth 7 包即从 Seq=1 起始）。

---

## 24. 无状态硬件探针 (Stateless Probe) 与 Service Lo 响应位协议解调规范 🆕 (2026-08-08 成果)

为了摆脱客户端对本地内存标记 (`hasAuthBeenDoneForCurrentConnection`) 的脆弱依赖，实现 100% 物理层驱动的无状态推屏，必须通过 `Service 0x0D-20` 物理探针主动解调 Glasses MCU 的真实硬件状态。

### 24.1 8-Byte Header 中 `Service Lo` 响应方向位物理定义

在 G2 智能眼镜 8-Byte BLE Header (`AA 12 ... SvcHi SvcLo`) 中，`Service Lo` 字节严格规定了通信双向路由的方向属性：

| Service Lo (HEX) | 位掩码定义 | 协议路由含义 | 典型报文示例 |
| :--- | :--- | :--- | :--- |
| **`0x20`** | `0b0010_0000` | 📱 **Phone ➔ 👓 Glasses 请求/下发帧 (Request)** | `0x0D-20` (探针/配置), `0x06-20` (提词), `0x30-20` (模式) |
| **`0x00`** | `0b0000_0000` | 👓 **Glasses ➔ 📱 Phone 即时物理响应 (Direct Response / ACK)** | **`0x0D-00`** (`AA 12 ... 0D 00 10 05 1A 02 08 01`), `0x09-00` |
| **`0x01`** | `0b0000_0001` | 👓 **Glasses ➔ 📱 Phone 异步事件广播 (Async Notify)** | **`0x0D-01`** (Session Terminated), `0x06-01` (触控行号) |

### 24.2 无状态探针 (Stateless Probe) 物理交互图

```mermaid
sequenceDiagram
    autonumber
    participant App as 📱 Gateway App (Stateless Engine)
    participant BLE as 📡 BLE Channel 5401 / 5402
    participant MCU as 👓 G2 Glass MCU

    App->>BLE: 1. 下发 0x0D-20 物理探针包 (Status Query)
    BLE-->>MCU: AA 21 00 08 01 01 0D 20 08 00 10 05 42 3E
    
    alt 物理鉴权有效 (Auth Active)
        MCU-->>BLE: 2a. 10ms 极速返回 0x0D-00 Direct ACK
        Note over BLE: AA 12 30 08 01 01 0D 00 10 05 1A 02 08 01
        BLE-->>App: 3a. 探针捕获 0x0D-00 (含有 1A 02 08 01) -> 判定鉴权尚在
        App->>BLE: 4a. 跳过 Auth 7 包，直接下发 Setup (7包) + Init + Pages + Commit
        BLE-->>MCU: 画面瞬间正常上电点亮 ⚡
    else 物理未鉴权 / 冷启动 / 从休眠唤醒 (Auth Invalid)
        MCU-->>BLE: 2b. 返回 0x0D-00 (1A 00 / 无有效 Segment) 或超时
        BLE-->>App: 3b. 探针判定硬件处在冷启动/鉴权失效态
        App->>BLE: 4b. 自动插入 Auth (7包) + Setup (7包) + Init + Pages + Commit
        BLE-->>MCU: 重新握手鉴权并上电点亮 ⚡
    end
```

### 24.3 避坑核心：匹配拦截器必须兼容 `SLo == 0x00` 与 `SLo == 0x01`
若探针解调拦截器仅限定 `sLo == 0x01`，则 MCU 返回的物理确认包 `0x0D-00` 会被拦截器遗漏抛弃，引发 300ms 假超时并强行误发 Auth 7 包造成黑屏。必须使拦截条件覆盖 `(sLo == 0x00 || sLo == 0x01)`。

---

## 25. 官方 APP 按需下发机制深度解密：为何无需 14 页补满 (基于 multiprompts.pklg × bt3.pklg × bt.pklg 三组抓包交叉验证 2026-08-09) 🆕

通过对 3 组官方 BLE 抓包（`multiprompts.pklg` 2 次推送、`bt3.pklg` 11 页长文本、`bt.pklg` 4 页文本）与我方 `session.log` 的逐字节 Protobuf 反序列化对比，揭示了官方 APP 无需 14 页补满即可正常工作的完整协议机制。

### 25.1 关键差异一：TeleprompterInit `field_4` / `field_5` 在热重推时动态填入实际页数与行数

交叉验证 3 个抓包后发现，TeleprompterInit 内层 `TeleprompterConfig` 消息的 `field_4` 和 `field_5` 在不同场景下填入**不同值**：

| 抓包文件 | 场景 | field_4 | field_5 | 实际页数 | 实际总行数 |
| :--- | :--- | ---: | ---: | ---: | ---: |
| `bt.pklg` | 首次冷启动 (4 页) | **59** | **585** | 4 | ~40 |
| `bt3.pklg` | 首次冷启动 (11 页长文) | **59** | **585** | 11 | ~110 |
| `multiprompts.pklg` Push #1 | 热重推 (2 页短文) | **2** | **13** | 2 | 13 (=10+3) |
| `multiprompts.pklg` Push #2 | 热重推 (2 页短文) | **2** | **13** | 2 | 13 |
| 我方代码 | 所有推送 (固定) | **59** | **585** | 14 | 140 |

**关键洞察**：
- 冷启动时 `field_4=59`, `field_5=585` 为默认值（可能是 `display_width` / `max_chars_per_page` 的全屏参数含义）
- **热重推时**，官方 APP 将 `field_4` 改写为**实际总页数** (2)，`field_5` 改写为**实际总行数** (13)——这精确匹配了 2 页内容 (Page 0=10 行 + Page 1=3 行)
- 我方代码始终固定为 `59`/`585`，固件无法从 Init 中获知实际内容量

**Protobuf 原始字节对比**：
```text
官方热重推 Init 内层:
  08 00 10 00 18 00 20 02 28 0D 30 B7 04 38 A9 18 40 00 48 01 50 09 58 00
                    ^^^^^ ^^^^^
                    f4=2  f5=13  (实际页数/行数)

我方 Init 内层:
  08 00 10 00 18 00 20 3B 28 C9 04 30 B7 04 38 A9 18 40 00 48 01 50 09 58 00
                    ^^^^^ ^^^^^^^^
                    f4=59 f5=585  (固定默认值)
```

### 25.2 关键差异二：我方完全缺少 `TeleprompterComplete` (type=255) 终止帧

官方 APP 在所有 Content Page 发送完毕后，会发送一个 **`type=255`** 帧（推测为 `TeleprompterComplete`），显式告知固件 MCU "内容传输结束"：

**`multiprompts.pklg` Push #1 的 type=255 帧**：
```text
Payload: 08 FF 01 10 39 6A 04 08 00 10 04
  field 1 (type)   = 255
  field 2 (msg_id) = 57
  field 13 (data)  = { sub_field_1=0, sub_field_2=4 }
```

**`bt3.pklg` 的 type=255 帧出现 2 次**：
```text
第 1 次: field_13 = { sub_field_1=0, sub_field_2=9 }
第 2 次: field_13 = { sub_field_1=4, sub_field_2=0 }  ← sub_field_1=4 可能标记 state=4 完成
```

> 🚨 **我方代码中完全没有发送 type=255 帧**。这意味着固件缺少一个显式的"传输完成"信号，可能被迫依赖 14 页 Buffer 槽位填满来隐式判断内容边界。

### 25.3 关键差异三：官方发 2 次 Render Commit 并夹带 type=255，我方只发 1 次

**官方 Push #1 完整发包序列** (`multiprompts.pklg`)：
```text
1. TeleprompterInit (type=1, field_4=2, field_5=13)
2. Content Page 0   (type=3, page_index=0, line_count=10)
3. Content Page 1   (type=3, page_index=1, line_count=3)  ← 最后一页仅 3 行
4. ScrollSync ×2    (type=165, 视口对齐 Page 0 Line 4)
5. Render Commit #1 (0x80-00, type=14)
6. TeleprompterComplete (type=255)                        ← 我方缺少
7. Render Commit #2 (0x80-00, type=14)                    ← 第二次 Commit
```

**我方 Push #1 完整发包序列** (`session.log`)：
```text
1.     TeleprompterInit (type=1, field_4=59, field_5=585)
2~15.  Content Page 0~13 (type=3, 全部 line_count=10, 12 页空白补满)
16.    HUD Mount (0x04-20)
17.    Touchpad Router (0x09-20)
18.    Render Commit ×1 (0x80-00, type=14)
19.    ScrollSync ×1 (type=165)
```

### 25.4 附加差异：Content Page 最后一页 `line_count` 字段

| 项目 | 官方 APP | 我方代码 |
| :--- | :--- | :--- |
| 最后一页 `line_count` | **3** (实际文本行数) | **10** (空行补满到 10) |
| 空白补满页 | 不发送 | 发送 12 个 `line_count=10` 的全空页 |

### 25.5 结论：官方 APP 通过 3 层机制告知固件精确内容边界

| 层级 | 机制 | 官方实现 | 我方实现 | 影响 |
| :--- | :--- | :--- | :--- | :--- |
| **Layer 1** | Init `field_4`/`field_5` | 热重推时填入实际页数/行数 | 固定 59/585 | 固件无法预知内容量 |
| **Layer 2** | `type=255` Complete 帧 | Pages 完毕后显式发送 | ❌ 完全缺失 | 固件无法确认传输结束 |
| **Layer 3** | 双 Render Commit | Commit → type=255 → Commit | 仅 1 次 Commit | 渲染提交流程不完整 |

> ⚠️ **当前我方代码采用 14 页补满策略 (`G2ProtocolEncoder.formatTextToPages(targetPageCount: 14)`) 作为兼容性变通方案**——通过填满固件的 14 页 Buffer 隐式标记内容边界。此策略在物理真机测试中确认可正常工作 (§16.1)，但额外传输了 12 页无效空白数据，增加了约 1.5 秒的 BLE 传输延迟。

> 💡 **优化路径**：若要实现官方级别的按需下发（减少 BLE 传输量、降低推屏延迟），需要在代码中补充上述 3 层机制——动态 Init 参数 + type=255 Complete 帧 + 双 Commit 序列。

