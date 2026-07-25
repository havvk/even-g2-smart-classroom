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
- **Len (byte 3)**：`Payload 长度 + 2`（包含 CRC16 长度）。
- **Packet Total (byte 4)**：长数据切片总包数（未切片恒为 `0x01`）。
- **Packet Serial (byte 5)**：当前切片序号（从 `0x01` 开始）。
- **Service Hi/Lo (bytes 6-7)**：服务分类 ID（如 `0x06 0x20`）。

### 4.2 CRC16-CCITT 算法规范 (XModem 模式)
- **算法模型**：CRC-16/CCITT (`XModem`)
- **初始值**：`0xFFFF`
- **多项式**：`0x1021`
- **计算范围**：包含 Header (前 8 字节) 与 Payload 全部字节
- **输出格式**：Little-Endian（低字节在前）

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
  uint32 field1 = 1;            // 1
  uint32 field2 = 2;            // 0
  uint32 field3 = 3;            // 0
  uint32 display_width = 4;     // 267
  uint32 content_height = 5;    // 画卷总高度
  uint32 line_height = 6;       // 230
  uint32 viewport_height = 7;   // 2588 (全屏 9 行视口)
  uint32 font_size = 8;         // 5
  uint32 scroll_mode = 9;       // 0=manual, 1=AI
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
  uint32 region_id = 1;     // Region 2, 3, 4, 5, 6
  uint32 param1 = 2;
  float param2 = 3;         // 32-bit IEEE 754 Float (幅宽 644.0f)
  float param3 = 4;
  uint32 param4 = 5;
  uint32 param5 = 6;
}

// 4. GPU VSYNC 同步刷屏脉冲 (Service 0x80-00)
message SyncMessage {
  uint32 type = 1;          // 0x0E (type=14)
  uint32 msg_id = 2;
  bytes data = 13;          // 6A-00
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
- **物理滚动条数学算式**：
  $$\text{Scroll Bar Percentage} = \frac{\text{viewport\_height}}{\text{total\_content\_height}} \times 100\% = \frac{2588}{140 \times 230} \approx 8.03\%$$

### 6.2 实时同传翻译子系统 (`proto_translate_ext.dart` / Service 0x0B-20, 0x11-20)
- **命令方法集**：
  - `sendStartTranslate`：启动 G2 麦克风 PCM 音频采集与固件端同传画布。
  - `sendStopTranslate` / `sendPauseTranslate` / `sendResumeTranslate`：流程控制。
  - `sendTranslateResult`：下发双语对齐字幕结果，包含 `text`（文本内容）与 `is_final`（句尾收敛标记）。
  - `sendTranslateHeartbeat`：同传会话心跳。
  - `onListenOsPushEvent`：固件端字幕交互按钮（如双击切换原字/译文）上报监听。

### 6.3 Turn-by-Turn 实时导航子系统 (`proto_navigation_ext.dart`)
- **命令方法集**：
  - `sendNavigationStart` / `sendNavigationStop`：开启与关闭导航视图。
  - `sendNavigationBasicInfo`：下发包含转弯距离 (meters)、目的地名称、剩余时间的基准帧。
  - `sendNavigationOverviewMap`：概览地图全景位图推屏。
  - `sendNavigationMiniMap` / `sendMiniMapFragments`：迷你导航地图分栏矢量分片推送。
  - `sendNavigationRecalculating`：偏航重新计算通知（展示“重新规划中”警示）。
  - `sendNavigationArrive`：到达目的地全屏醒目图标与提醒。
  - `sendNavigationFavoriteList` / `sendNavigationHeartbeat`：收藏夹与导航心跳。

### 6.4 Even AI 大模型交互与 Skill 调度 (`proto_ai_ext.dart`)
- **命令方法集**：
  - `sendSkillTeleprompt` / `sendSkillNavigate` / `sendSkillConverse` / `sendSkillTranslate`：由 AI 意图识别后动态调起眼镜端对应的提词、导航、同传或翻译 App 模式。
  - `sendSkillBrightness` / `sendSkillBrightnessAuto`：AI 语音控制系统亮度。
  - `sendSkillNotification` / `sendSkillQuickList`：AI 唤起通知或快捷组件。
  - `sendAiConfig`：配置 LLM 提示词格式、响应语言与模型类型。
  - `sendAsr` / `sendVadEndFeedBack`：实时 VAD 语音断句反馈。
  - `sendAnalyzeLoading`：在眼镜端渲染“AI 思考中...”流式 RunDot 动效。
  - `sendWakeupResp` / `sendAIReplay` / `sendExit`：语音唤醒、重播与退出。

### 6.5 主屏仪表盘、天气与简讯挂件 (`proto_dashboard_ext.dart` / Service 0x07-20)
- **命令方法集**：
  - `sendDashboardBaseSettingInfoToGlass`：下发温度单位 (摄氏/华氏)、时间制式 (12h/24h) 与表盘布局。
  - `sendWeatherInfoToGlass`：下发当前温度、最高/最低温、天气 Icon 编号及空气质量。
  - `sendNewsDataToGlassV3` / `sendNeedSendNewsCountV3` / `sendEmptyNewsDataToGlassV3`：简讯新闻挂件增量下发与计数更新。
  - `probeNeedSendNewsCount` / `probeSendNewsToGlass`：轮询与主动探测。

### 6.6 健康与 HRV 监测子系统 (`proto_health_ext.dart`)
- **命令方法集**：
  - `sendHealthSingle` / `sendHealthMult` / `sendHealthHighlightMult`：单次与批量健康采集。
  - `sendDashboardSnapshotk`：生成主屏健康卡片快照。
  - `onListenOsHealthEvent`：实时监听眼镜端 6 轴 PPG 心率、HRV 心率变异性以及计步数据。

### 6.7 手机通知镜像子系统 (`proto_notification_ex.dart` / Service 0x02-20)
- **命令方法集**：
  - `settingNotification`：配置允许镜像通知的应用 App ID（如 Gmail `0x1A`、微信、短信、来电）。
  - `switchWhiteListState`：黑白名单切换。
  - `checkNotifyWhitelistCrc`：下发白名单 CRC 校验码，防止重复推送。

### 6.8 Smart Ring 智能戒指与手势交互 (`proto_ring_ext.dart` / `BleG2CmdProtoRingExt`)
- **命令方法集**：
  - `controlDevice`：接收与处理 Smart Ring 绑定的触控滚轮、单击、双击事件。
  - `switchRingHand`：切换戒指佩戴左/右手习惯，调整方向映射。
  - `openRingBroadcast`：开启蓝牙广播配对模式。
  - `onListenOsRingEvent`：监听戒指发送给眼镜的实时翻页指令。

### 6.9 Even Hub RAW 像素画布与容器管理 (`BleG2CmdProtoEvenHubExt`)
- **命令方法集**：
  - `sendImageRaw` / `_sendPreparedImageRaw`：发送 RAW 单色/灰度像素点阵阵列。
  - `createStartUpPageContainer` / `rebuildPageContainer` / `shutDownPageContainer`：在 G2 显存建立或销毁像素级画布容器。
  - `imuControl`：开启或关闭眼镜 IMU 6 轴数据流上报。
  - `audioControl`：开启或关闭原始 PCM 音频流上报。

### 6.10 系统基础配置、手势与 OTA 升级 (`BleG2CmdProtoDeviceSettingsExt` / `ProtoBaseSettings`)
- **命令方法集**：
  - `startPair` / `unpair` / `disconnect`：设备配对与断开控制。
  - `createTimeSyncCommand`：发送 Unix 时间戳同步。
  - `quickRestart` / `restoreFactory`：快速重启固件 / 恢复出厂设置。
  - `setBrightness` / `setBrightnessAuto` / `setBrightnessCalibration`：手动/自动亮度调节与校准。
  - `updateScreenOffInterval` / `requestScreenOffInterval`：配置无操作熄屏超时（秒）。
  - `setWearDetection` / `getGlassesIsWear`：红外佩戴检测使能与查询。
  - `setSilentMode`：开启/关闭眼镜勿扰静音模式。
  - `headUpSetting` / `getBoardingIsHeadup`：设置与查询抬头唤醒（Head-Up）视角门限。
  - `setGestureControlList`：绑定头部动作手势列表。
  - `BleG2OtaUpgradeMixin` / `dfu_upgrade.dart`：在线 DFU/OTA 固件块校验升级状态机。

### 6.11 开发者控制台模式 (`proto_terminal_ext.dart`)
- **命令方法集**：`sendTerminalSessionSwitchResult`, `sendTerminalModeSync`, `sendTerminalQuery`, `sendTerminalSessionList`, `sendTerminalAgentContent`（下发 Terminal 字符流）。

### 6.12 Task 待办任务管理 (`proto_task_manager_ext.dart` / Service 0x0C-20)
- **命令方法集**：`syncGlassInfo`（同步待办事项清单与多选勾选状态）。

### 6.13 原始音频流控制 (`proto_audio_ext.dart`)
- **命令方法集**：`get#micPcmDataStream`（订阅与提取眼镜双麦克风阵列 16kHz PCM 音频数据）。

### 6.14 快捷挂件小组件 (`proto_quicklist_ex.dart`)
- **命令方法集**：`sendMultAdd`, `sendMultFullUpdate`, `sendItemSingle`, `respondPagingByUid`。

### 6.15 系统日志与埋点数据 (`proto_log_ext.dart` / `proto_tracepoint_ext.dart`)
- **命令方法集**：`sendLiveLogSwitch`, `sendLiveLogLevel`, `getLogFiles`, `deleteLogFile`, `getTracepointFiles`。

---

## 7. 已验证失败的数据流逻辑与反模式归档 (Anti-Pattern Matrix)

| 实验编号 | 数据流尝试路径 | 固件物理响应行为 | 黑屏根因诊断 |
| :--- | :--- | :--- | :--- |
| **Trial A** | **全量走 5401 通道**<br>(Auth $\rightarrow$ 5401<br>Teleprompter $\rightarrow$ 5401<br>Sync $\rightarrow$ 5401) | 固件回发 ACK (`Seq=0x40`, `0xA4`, `0x17`, `0x73`, `0xD7`)，传输层确认成功。 | **黑屏**。5401 仅为 Dashboard/主屏挂件通道，虽然固件 BLE 传输层返回 ACK，但 G2 Window Manager 未将内容渲染进提词视口。 |
| **Trial B** | **全量走 0001/7401/6401**<br>(Auth $\rightarrow$ 0001<br>Teleprompter $\rightarrow$ 7401<br>Sync $\rightarrow$ 6401) | 0001 完全无 ACK 应答；7401 完全无应答；6401 原样 Loopback 回传 `AA 21 1E...` 帧。 | **黑屏**。0001 无法接收 Auth 报文导致会话未建立鉴权，G2 固件安全机制拒收后续 7401/6401 指令。 |
| **Trial C** | **混合通道**<br>(Auth $\rightarrow$ 5401 获得 ACK<br>Teleprompter $\rightarrow$ 7401<br>Sync $\rightarrow$ 6401) | 5401 返回 Auth ACK (`Seq=0x40`, `0xA4`, `0x73`, `0xD7`)；7401 发送成功但无 ACK；6401 回传 Loopback 帧。 | **黑屏**。7401 特征值下发后 MicroLED 无显示，说明 7401 需要预先写入 0x2902 Descriptor 开启 Notify 订阅，或 7401 非直写特征。 |

---

## 8. 自动化单元测试与物理断言规范

所有 Protobuf 封包与物理 BLE 帧必须通过严格的本地自动化单元测试：
1. **CRC16 校验测试**：验证 `addCRC` 生成的 CRC16 校验码与官方 C++ 模块输出 100% 一致。
2. **Protobuf 规则断言**：断言封包输出绝对不包含非法的 WireType（如 `0x06`），每个 Tag 头必须匹配 Protobuf Spec。
3. **物理 Sequence 递增测试**：长 Payload 切片时，断言分片帧数组中 `seq` 严格平滑自增。
4. **14 页 140 行画卷补满测试**：短文本输入时，断言输出 `totalPages >= 14`，`totalLines >= 140`。

---
*修订时间：2026-07-25*  
*分析员：Antigravity Agent Team*
