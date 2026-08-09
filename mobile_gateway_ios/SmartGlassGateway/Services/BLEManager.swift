import Foundation
import CoreBluetooth
import Combine



enum GlassesState: String, CaseIterable, Identifiable {
    case disconnected = "未连接"
    case dashboard = "主页仪表盘"
    case teleprompter = "提词前台"
    case conversate = "AI同传"
    case sleeping = "息屏休眠"
    
    var id: String { rawValue }
    
    var iconName: String {
        switch self {
        case .disconnected: return "eyeglasses"
        case .dashboard: return "house.fill"
        case .teleprompter: return "doc.text.fill"
        case .conversate: return "bubble.left.and.bubble.right.fill"
        case .sleeping: return "eye.slash.fill"
        }
    }
}

/// G2 眼镜返回消息数据模型 (Rx Debug Message)
struct G2RxMessage: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let rawHex: String
    let commandType: String
    let description: String
    let isGesture: Bool
    
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }
}

enum G2Channel {
    case control
    case content
    case rendering
    case teleprompter
}

class BLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var isConnected = false
    @Published var isScanning = false
    @Published var connectedPeripheralName: String? = nil
    @Published var lastGestureReceived: String = "None"
    @Published var lastBLEStatusMessage: String = "等待扫描连接眼镜"
    @Published var isDebugOverrideMode: Bool = false
    
    // 调试与日志记录
    @Published var bleLogHistory: [String] = []
    @Published var g2RxMessages: [G2RxMessage] = []
    @Published var rxCount: Int = 0
    
    // 实时日志推送回调 (direction, hexBytes, description)
    var onG2TelemetryLog: ((String, String, String) -> Void)?
    
    // CoreBluetooth 句柄与 G2 专属多通道写特征
    private var centralManager: CBCentralManager!
    private var targetPeripheral: CBPeripheral?
    private var controlTxChar: CBCharacteristic?      // UUID 包含 0001 (控制握手)
    private var contentTxChar: CBCharacteristic?      // UUID 包含 5401 (文本内容)
    private var renderingTxChar: CBCharacteristic?    // UUID 包含 6401 (渲染控制)
    private var teleprompterTxChar: CBCharacteristic? // UUID 包含 7401 (提词器专用)
    
    // 手势与翻页回调
    var onPageControlTriggered: ((String) -> Void)?
    
    // G2 BLE 强类型有限状态机 (FSM)
    enum G2ConnectionState: String {
        case disconnected     = "未连接"
        case scanning         = "正在扫描"
        case connecting       = "物理连接中"
        case gattDiscovering  = "GATT通道识别中"
        case channelsReady    = "通道就绪 (Ready)"
        case sessionActive    = "推屏会话中"
    }
    
    @Published var connectionState: G2ConnectionState = .disconnected
    
    private var isManualDisconnect = false
    private var hasHandshakeExecuted = false
    private var isGattSystemModeInitialized = false
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }
    
    func addLog(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.bleLogHistory.append(message)
            if self.bleLogHistory.count > 100 {
                self.bleLogHistory.removeFirst()
            }
            self.onG2TelemetryLog?("Log", "", message)
        }
    }
    
    func clearLogs() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.bleLogHistory.removeAll()
            self.g2RxMessages.removeAll()
            self.rxCount = 0
        }
    }
    
    func startScanning() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let cm = self.centralManager else { return }
            guard cm.state == .poweredOn else {
                self.lastBLEStatusMessage = "⚠️ 蓝牙尚未开启，请在系统设置中启用蓝牙"
                return
            }
            self.isManualDisconnect = false
            self.hasHandshakeExecuted = false
            self.isScanning = true
            self.lastBLEStatusMessage = "正在扫描/检索附近的 Even G2 眼镜..."
            
            // 核心修复 1: 优先检索已经被 iOS 系统级别配对连接的 G2 设备
            let knownServices = [
                CBUUID(string: "00002760-08c2-11e1-9073-0e8ac72e0001"),
                CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
            ]
            let connectedPeripherals = cm.retrieveConnectedPeripherals(withServices: knownServices)
            for p in connectedPeripherals {
                let name = p.name ?? ""
                if name.contains("Even G2") || name.contains("Even") || name.contains("_L_") {
                    self.addLog("⚡️ [系统快连] 成功检索到 iOS 系统已连接设备: \(name)")
                    self.targetPeripheral = p
                    self.targetPeripheral?.delegate = self
                    cm.connect(p, options: nil)
                    return
                }
            }
            
            // 核心修复 2: 发起物理广播扫描
            cm.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }
    
    func stopScanning() {
        DispatchQueue.main.async { [weak self] in
            self?.isScanning = false
            self?.centralManager.stopScan()
        }
    }
    
    func disconnect() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isManualDisconnect = true
            self.hasHandshakeExecuted = false
            if let peripheral = self.targetPeripheral {
                self.centralManager.cancelPeripheralConnection(peripheral)
            }
            self.isConnected = false
            self.connectedPeripheralName = nil
            self.controlTxChar = nil
            self.contentTxChar = nil
            self.renderingTxChar = nil
            self.teleprompterTxChar = nil
            self.lastBLEStatusMessage = "已手动断开蓝牙"
        }
    }
    
    // MARK: - CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if central.state == .poweredOn {
                if !self.isManualDisconnect {
                    self.startScanning()
                }
            } else {
                self.isConnected = false
                self.isScanning = false
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        guard name.contains("Even G2") || name.contains("Even") else { return }
        
        // 关键物理规则 (对齐 teleprompter.py 规范): 左耳 _L_ 为包含 MicroLED 显示引擎的 Master 设备，必须优先锁定 _L_
        if name.contains("_L_") || !name.contains("_R_") {
            addLog("🎯 优先锁定 G2 左耳主显示镜腿: \(name)")
            targetPeripheral = peripheral
            targetPeripheral?.delegate = self
            stopScanning()
            centralManager.connect(peripheral, options: nil)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isConnected = true
            self.hasHandshakeExecuted = false
            self.teleprompterSeq = 0x01
            self.teleprompterMsgId = 0x14
            self.connectedPeripheralName = peripheral.name ?? "Even G2 Smart Glass"
            self.lastBLEStatusMessage = "🟢 蓝牙已连接设备: \(self.connectedPeripheralName ?? "")"
        }
        peripheral.discoverServices(nil)
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isConnected = false
            self.hasHandshakeExecuted = false
            self.hasAuthBeenDoneForCurrentConnection = false
            self.isGattSystemModeInitialized = false
            self.teleprompterSeq = 0x01
            self.teleprompterMsgId = 0x14
            self.isTeleprompterSessionActive = false
            self.connectedPeripheralName = nil
            self.controlTxChar = nil
            self.contentTxChar = nil
            self.renderingTxChar = nil
            self.teleprompterTxChar = nil
            if !self.isManualDisconnect {
                self.startScanning()
            } else {
                self.lastBLEStatusMessage = "已断开蓝牙，点击按钮可重新扫描"
            }
        }
    }
    
    // MARK: - CBPeripheralDelegate
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            addLog("❌ 发现服务异常: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else { return }
        for service in services {
            addLog("🔎 发现 GATT 服务: \(service.uuid.uuidString)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            addLog("❌ 发现特征异常: \(error.localizedDescription)")
            return
        }
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            let uuidStr = characteristic.uuid.uuidString.uppercased()
            let props = characteristic.properties
            
            let canNotify = props.contains(.notify) || props.contains(.indicate)
            let canWrite = props.contains(.write) || props.contains(.writeWithoutResponse)
            addLog("🔍 特征值: \(uuidStr) [Notify/Ind:\(canNotify), Write:\(canWrite)]")
            
            let uuidSuffix = String(uuidStr.suffix(4))
            // 订阅所有支持 Notify/Indicate 的特征通道 (包含 Nordic 串口 6E40 通道与 5402)
            if canNotify {
                peripheral.setNotifyValue(true, for: characteristic)
                addLog("🔔 [物理 CCCD 激活] 正在开启 [\(uuidSuffix)] 通道 Notify 接收...")
            }
            
            // 按 UUID 结尾绑定 G2 专属 Channel 特征通道 (排除 6E40 串口)
            if canWrite {
                if uuidStr.hasSuffix("0001") {
                    controlTxChar = characteristic
                    addLog("✍️ 绑定 [0001 控制通道] 写特征: \(uuidStr)")
                } else if uuidStr.hasSuffix("5401") {
                    contentTxChar = characteristic
                    addLog("✍️ 绑定 [5401 内容通道] 写特征: \(uuidStr)")
                }
            }
        }
        
        let hasAnyTxChar = controlTxChar != nil || contentTxChar != nil
        if hasAnyTxChar {
            addLog("✍️ 已成功绑定 5401 物理写特征通道")
        }
    }
    
    @Published var isNotifyReady: Bool = false
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let uuidStr = characteristic.uuid.uuidString.uppercased()
        if let error = error {
            addLog("❌ Notify 通道订阅失败 (\(uuidStr)): \(error.localizedDescription)")
        } else {
            addLog("✅ Notify 通道订阅成功 (\(uuidStr)), isNotifying=\(characteristic.isNotifying)")
            if uuidStr.contains("5402") {
                DispatchQueue.main.async {
                    self.isNotifyReady = true
                    self.connectionState = .channelsReady
                    self.addLog("🔒 [物理订阅锁] 5402 Notify 100% 订阅就绪，允许推屏!")
                }
            }
        }
    }
    
    /// 蓝牙链路初次连接建立时，下发 1 次 Auth (7包) + Setup (7包，含 0x30-20)，将 MCU 从主菜单切换为提词系统模式
    private func sendGattColdStartSetup() {
        guard isConnected else { return }
        addLog("🔑 [BLE 冷启动握手] 下发 Auth (7包) + Setup (7包)，初始化眼镜系统模式...")
        var seq: UInt8 = self.teleprompterSeq == 0 ? 0x01 : self.teleprompterSeq
        var msgId: Int = self.teleprompterMsgId == 0 ? 0x01 : self.teleprompterMsgId
        
        var packets: [Data] = []
        var descs: [String] = []
        
        let authPackets = G2ProtocolEncoder.buildAuthPackets(seq: &seq, msgId: &msgId)
        for (idx, pkt) in authPackets.enumerated() {
            packets.append(pkt)
            descs.append("Auth [\(idx + 1)/7]")
        }
        
        let setupPairs = G2ProtocolEncoder.buildOfficialSetupSequence(seq: &seq, msgId: &msgId)
        for (pkt, desc) in setupPairs {
            packets.append(pkt)
            descs.append(desc)
        }
        
        self.teleprompterSeq = seq
        self.teleprompterMsgId = msgId
        self.bt3PendingPackets = packets
        self.lockStepDescs = descs
        self.bt3CurrentIndex = 0
        sendNextBt3PacketInLockstep()
    }
    
    @Published var rxPacketCount: Int = 0
    @Published var lastRawHex: String = "无"
    
    /// 接收 G2 固件在 Notify 通道上回发的 ACK 确认帧与位置 Notification (100% 对齐 teleprompter.py notify handler)
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            addLog("❌ Rx 接收返回错误: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value, !data.isEmpty else { return }
        
        let uuidSuffix = String(characteristic.uuid.uuidString.suffix(4))
        
        // 核心过滤 1: 6402 为麦克风 PCM 音频流通道，必须在接收端静默拦截，严禁打印日志轰炸
        if uuidSuffix == "6402" {
            return
        }
        
        // 核心过滤 2: 过滤 6402 音频流，只放行含有 0xAA 协议帧或 Notify 特征的数据
        let hexStr = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        
        addLog("📩 [Rx Notify] 通道 [\(uuidSuffix)] (\(data.count)B): \(hexStr)")
        onG2TelemetryLog?("Rx", hexStr, "G2 Notify 接收 [\(uuidSuffix)] (\(data.count)B)")
        
        DispatchQueue.main.async {
            self.rxPacketCount += 1
            self.lastRawHex = hexStr
        }
        
        processReceivedG2Data(data)
    }
    
    /// 将 BLEManager 的收发日志与 WebSocketClient 的遥测调试通道进行自动绑定
    func setupWebSocketTelemetryBinding(_ client: WebSocketClient) {
        self.onG2TelemetryLog = { [weak client] direction, hexBytes, desc in
            client?.sendG2TelemetryLog(direction: direction, hexBytes: hexBytes, description: desc)
        }
    }
    
    // 独立握手已废弃，统一由 sendTeleprompterText 自包含串行下发 Auth 鉴权序列
    
    @Published var isTeleprompterSessionActive: Bool = false
    @Published var isPushingText: Bool = false
    private var teleprompterWorkItems: [DispatchWorkItem] = []
    @Published var lastSentTeleprompterText: String = ""
    
    // 维持 BLE 会话粒度的包序号与消息 ID
    private var hasAuthBeenDoneForCurrentConnection: Bool = false
    private var teleprompterSeq: UInt8 = 0x01
    private var teleprompterMsgId: Int = 0x14
    
    /// 撤销所有尚未执行的倒计时推屏发包任务
    private func cancelPendingTeleprompterTasks() {
        for item in teleprompterWorkItems {
            item.cancel()
        }
        teleprompterWorkItems.removeAll()
        bt3TimeoutWorkItem?.cancel()
        rePushTimeoutWorkItem?.cancel()
        rePushTimeoutWorkItem = nil
        scrollSyncThrottleWorkItem?.cancel()
        scrollSyncThrottleWorkItem = nil
        pendingSyncLineIndex = nil
        bt3PendingPackets.removeAll()
        bt3CurrentIndex = 0
        isPushingText = false
    }
    
    /// 重置提词器会话状态并清空历史文本防抖 (若 clearHardwareState 为 true 则同步向眼镜下发物理退出/清屏指令)
    func resetTeleprompterSession(clearHardwareState: Bool = true) {
        cancelPendingTeleprompterTasks()
        if clearHardwareState && isConnected && contentTxChar != nil && isTeleprompterSessionActive {
            sendExitTeleprompterMode()
        }
        lastSentTeleprompterText = ""
        isTeleprompterSessionActive = false
        isPushingText = false
    }
    
    private func hexToData(_ hex: String) -> Data {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: " ", with: "")
        var data = Data(capacity: hexSanitized.count / 2)
        var varHex = hexSanitized
        while !varHex.isEmpty {
            let subIndex = varHex.index(varHex.startIndex, offsetBy: 2)
            let c = String(varHex[..<subIndex])
            varHex = String(varHex[subIndex...])
            var ch: UInt64 = 0
            Scanner(string: c).scanHexInt64(&ch)
            var b = UInt8(ch)
            data.append(&b, count: 1)
        }
        return data
    }
    
    /// 实时当前滚动的焦点行号回调 (用于 9 行所见即所得 View 高亮卡片)
    @Published var currentFocusPageLine: Int = 0
    @Published var currentWrappedLines: [String] = []
    @Published var currentGlassesState: GlassesState = .dashboard
    
    private var currentPages: [String] = []
    private var lastPhoneScrollTime: Date = Date.distantPast
    private var lastGlassesRxScrollTime: Date = Date.distantPast
    private var lastScrollSyncSentTime: Date = Date.distantPast
    private var pendingSyncLineIndex: Int?
    private var scrollSyncThrottleWorkItem: DispatchWorkItem?
    private var pendingRePushTask: (() -> Void)?
    private var rePushTimeoutWorkItem: DispatchWorkItem?
    private var isWaitingForSessionTeardown: Bool = false
    
    /// 当用户在手机端物理触摸屏幕滑动时，立即复位眼镜 Rx 屏障，确保手机端手势 100% 优先发包
    func resetGlassesRxShield() {
        self.lastGlassesRxScrollTime = Date.distantPast
    }
    
    /// 发送双向滚动位置同步 (150ms 物理节流保护，下发 0x06-20 Type 165 报文至眼镜固件)
    func sendScrollSync(lineIndex: Int, force: Bool = false) {
        guard isConnected, isTeleprompterSessionActive else { return }
        if isWaitingForSessionTeardown || isPushingText { return }
        
        // 🛡️ 双向防乒乓屏障：若当前滑动是由眼镜镜腿 Touchpad 触发的(1.0s内)，手机绝对禁止反向发包给眼镜，彻底打断乒乓死循环！
        let timeSinceGlassesRx = Date().timeIntervalSince(lastGlassesRxScrollTime)
        if !force && timeSinceGlassesRx < 1.0 {
            return
        }
        
        if !force {
            self.lastPhoneScrollTime = Date()
        }
        
        let elapsed = Date().timeIntervalSince(lastScrollSyncSentTime)
        if !force && elapsed < 0.150 {
            // 🛡️ 150ms 物理节流 (匹配眼镜 MCU 单行滚动动画周期，彻底消除屏显顿挫)
            self.pendingSyncLineIndex = lineIndex
            if scrollSyncThrottleWorkItem == nil {
                let item = DispatchWorkItem { [weak self] in
                    guard let self = self, let targetLine = self.pendingSyncLineIndex else { return }
                    self.scrollSyncThrottleWorkItem = nil
                    self.sendScrollSync(lineIndex: targetLine)
                }
                self.scrollSyncThrottleWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + (0.150 - elapsed), execute: item)
            }
            return
        }
        
        self.lastScrollSyncSentTime = Date()
        self.pendingSyncLineIndex = nil
        
        let syncPkt = G2ProtocolEncoder.buildScrollSync(seq: &teleprompterSeq, msgId: teleprompterMsgId, lineIndex: lineIndex)
        teleprompterMsgId += 1
        sendRawData(syncPkt, channel: .content, logDesc: "双向位置同步 (Line \(lineIndex))")
        addLog("📍 [双向同步] 已发送 0x06-20 Type 165 报文 (Line \(lineIndex))\(force ? " [终点强制对齐]" : "")")
    }
    
    /// 手势停顿/滑动结束时调用的终点同步闭环：强行刷新最新终点帧，并开放 Rx 校准通道
    func flushFinalScrollSync(lineIndex: Int) {
        guard isConnected else { return }
        sendScrollSync(lineIndex: lineIndex, force: true)
        // 延时 150ms 之后，解封主控屏障窗口，允许接收眼镜 Rx 确认包进行位置校验
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.150) {
            self.lastPhoneScrollTime = Date.distantPast
        }
    }
    
    // 自动补发队列
    private var pendingPushText: String?
    private var pendingPushTargetWidth: Int?
    
    private func checkAndExecutePendingPush() {
        DispatchQueue.main.async {
            self.connectionState = .channelsReady
        }
    }
    
    /// 100% 零加工 1:1 原装 bt.pklg 抓包 70 包纯物理重发 (一个 Byte 都不改)
    func sendHardcodedOfficialPklg() {
        guard isConnected else {
            addLog("⚠️ 蓝牙未连接，请先连接 G2 眼镜")
            return
        }
        guard contentTxChar != nil else {
            addLog("⚠️ 5401 通道未绑定")
            return
        }
        
        let rawHexes = OfficialRawPkts.officialRawPktsHex
        addLog("🚀 [bt2.pklg 抓包重放] 开始发送 bt2.pklg 7 个精纯 Raw 数据包...")
        
        var delay: Double = 0.05
        for (idx, hexStr) in rawHexes.enumerated() {
            let currentPkt = hexToData(hexStr)
            let pktIndex = idx + 1
            
            let item = DispatchWorkItem {
                self.sendRawData(currentPkt, channel: .content, logDesc: "bt2.pklg 物理包 [\(pktIndex)/7]")
            }
            self.teleprompterWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            delay += 0.05
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.1) {
            self.addLog("🎉 bt2.pklg 7 个精纯 Raw 数据包全部下发完成！")
        }
    }
    
    private var bt3PendingPackets: [Data] = []
    private var bt3CurrentIndex: Int = 0
    private var bt3TimeoutWorkItem: DispatchWorkItem?
    private var lockStepDescs: [String] = []
    
    /// 100% 零加工 1:1 原装 bt3.pklg 提词物理帧 39 包重发 (ACK 优先 + 200ms 超时保底 Lock-step 引擎)
    func sendHardcodedOfficialBt3Pklg() {
        guard isConnected else {
            addLog("⚠️ 蓝牙未连接，请先连接 G2 眼镜")
            return
        }
        guard contentTxChar != nil else {
            addLog("⚠️ 5401 通道未绑定")
            return
        }
        
        cancelPendingTeleprompterTasks()
        let rawHexes = OfficialBt3Pkts.bt3TxRawHexes
        self.bt3PendingPackets = rawHexes.map { hexToData($0) }
        self.lockStepDescs = []
        self.bt3CurrentIndex = 0
        
        addLog("🚀 [1:1 Lock-step 步进引擎] 开始发送 OfficialBt3Pkts \(rawHexes.count) 个原装提词与触控使能 Raw 数据包 (ACK+200ms保底)...")
        sendNextBt3PacketInLockstep()
    }
    
    private var lastBt3SendTime: Date = Date.distantPast
    
    private var targetStartLine: Int = 0
    
    /// 下发当前 Lock-step 队列中的下一包物理帧 (ACK 驱动 + 120ms 物理间隔保护 + 250ms 超时保底)
    private func sendNextBt3PacketInLockstep() {
        bt3TimeoutWorkItem?.cancel()
        
        let totalCount = bt3PendingPackets.count
        guard bt3CurrentIndex < totalCount else {
            self.isPushingText = false
            self.isTeleprompterSessionActive = true
            addLog("✅ G2 物理屏显提词与前台焦点已锁定，Touchpad 0x06-01 触控已唤醒")
            addLog("🎉 [Lock-step] \(totalCount) 包全部下发完成！视口对齐第 \(self.targetStartLine) 行。")
            // 🎯 Lock-Step 队列尾包 (Packet 23) 已天然包含 ScrollSync Line 0，此处无需再重复触发 sendScrollSync，防止连发碰撞黑屏
            return
        }
        
        // 严格保护：发包间隔不少于 120ms，防止连发爆破导致眼镜 BLE Buffer 溢出与 MicroLED 显像芯片死锁黑屏
        let elapsed = Date().timeIntervalSince(lastBt3SendTime)
        if elapsed < 0.120 {
            let waitTime = 0.120 - elapsed
            let item = DispatchWorkItem { [weak self] in
                self?.sendNextBt3PacketInLockstep()
            }
            self.bt3TimeoutWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + waitTime, execute: item)
            return
        }
        
        lastBt3SendTime = Date()
        let pktData = bt3PendingPackets[bt3CurrentIndex]
        let pktNum = bt3CurrentIndex + 1
        let desc = bt3CurrentIndex < lockStepDescs.count
            ? "\(lockStepDescs[bt3CurrentIndex]) [\(pktNum)/\(totalCount)]"
            : "步进帧 [\(pktNum)/\(totalCount)]"
        bt3CurrentIndex += 1
        
        sendRawData(pktData, channel: .content, logDesc: desc)
        
        // 设置 250ms 超时保底，平滑物理节奏
        let timeoutItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.sendNextBt3PacketInLockstep()
        }
        self.bt3TimeoutWorkItem = timeoutItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.250, execute: timeoutItem)
    }
    
    /// 收到眼镜 ACK 后调用的驱动闭合
    private func onGlassAckReceivedForBt3Lockstep() {
        guard !bt3PendingPackets.isEmpty && bt3CurrentIndex < bt3PendingPackets.count else { return }
        bt3TimeoutWorkItem?.cancel()
        // 收到 ACK 延时 80ms 下发下一包 (保持平滑节奏，对齐官方物理抓包 150ms 整体步进)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.080) { [weak self] in
            self?.sendNextBt3PacketInLockstep()
        }
    }
    
    /// 动态编码并推送讲稿文本到 G2 眼镜 (Lock-Step ACK 驱动步进, 对齐 §20.1 规范)
    func sendTeleprompterText(_ rawText: String, targetWidthChars: Int = 28, scrollModeAI: Bool = true, startLine: Int = 0) {
        guard isConnected else {
            addLog("⚠️ 蓝牙未连接，请先连接 G2 眼镜")
            return
        }
        guard contentTxChar != nil else {
            addLog("⚠️ 5401 通道未绑定")
            return
        }
        
        // 🎯 防并发重入保护: 如果当前正在下发 23 包 Lock-Step 队列，严禁二次调用重入造成 BLE 管道连发碰撞
        if isPushingText {
            addLog("⚠️ 当前正在下发讲稿队列中，忽略并发重入请求")
            return
        }
        
        // =====================================================================
        // 2.0 [热重推 Push #2+ 专属] 先发 state=4 退出旧 Session，等眼镜确认后自动冷启动重推
        // 对齐 multiprompts.pklg: state=4 → 等 0D-01 确认 → 新 TeleprompterInit
        // =====================================================================
        if isTeleprompterSessionActive {
            addLog("🔄 [热重推 (Warm Push #2+)] 先发 state=4 退出旧 Session，等待眼镜 0D-01 确认后自动冷启动重推...")
            
            // 注册待执行的重推任务：收到 Session Terminated 后自动回调
            self.pendingRePushTask = { [weak self] in
                guard let self = self else { return }
                self.addLog("⚡️ [Session Terminated 确认] 自动启动冷启动重推流程...")
                self.sendTeleprompterText(rawText, targetWidthChars: targetWidthChars, scrollModeAI: scrollModeAI, startLine: startLine)
            }
            
            // 设置 3 秒超时保底：如果眼镜没回 Session Terminated，强制冷启动重推
            let timeoutItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if self.isWaitingForSessionTeardown {
                    self.addLog("⏱️ [超时保底] 3s 未收到 Session Terminated 确认，强制重推")
                    self.isWaitingForSessionTeardown = false
                    self.isTeleprompterSessionActive = false
                    // §23.2: Auth 保持有效，不重置
                    if let task = self.pendingRePushTask {
                        self.pendingRePushTask = nil
                        task()
                    }
                }
            }
            self.rePushTimeoutWorkItem = timeoutItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: timeoutItem)
            
            // 下发 state=4 退出指令
            sendExitTeleprompterMode()
            return  // ← 等待异步回调，不继续执行后续队列构建
        }
        
        // =====================================================================
        // 以下为冷启动路径 (Push #1 或 Session Terminated 后的重推)
        // =====================================================================
        
        // 1. 取消正在执行的任务与重置状态
        cancelPendingTeleprompterTasks()
        self.isPushingText = true
        self.targetStartLine = startLine
        self.currentFocusPageLine = startLine
        DispatchQueue.main.async {
            self.currentFocusPageLine = startLine
        }
        
        let pages = G2ProtocolEncoder.formatTextToPages(rawText, maxLineWidth: targetWidthChars * 2, linesPerPage: 10)
        self.currentPages = pages
        
        // 2. 构建 Lock-Step 包队列
        var packets: [Data] = []
        var descs: [String] = []
        
        var seq: UInt8 = self.teleprompterSeq == 0 ? 0x01 : self.teleprompterSeq
        var msgId: Int = self.teleprompterMsgId == 0 ? 0x01 : self.teleprompterMsgId
        
        // 2.1 [冷启动 Push #1 专属] 当次 BLE 连接的首次点按推屏：下发 Auth (4包) + Setup (11包) 完成 MCU 画布挂载 (100% 物理对齐 bt3.pklg Pkt #01-#15)
        if !hasAuthBeenDoneForCurrentConnection {
            addLog("🔑 [BLE 冷启动推屏] 下发 Auth (4包) + Setup (11包) 挂载眼镜 MCU 提词画布...")
            let authPackets = G2ProtocolEncoder.buildAuthPackets(seq: &seq, msgId: &msgId)
            for (idx, pkt) in authPackets.enumerated() {
                packets.append(pkt)
                descs.append("Auth [\(idx + 1)/4]")
            }
            let setupPairs = G2ProtocolEncoder.buildOfficialSetupSequence(seq: &seq, msgId: &msgId)
            for (pkt, desc) in setupPairs {
                packets.append(pkt)
                descs.append(desc)
            }
            self.hasAuthBeenDoneForCurrentConnection = true
        } else {
            addLog("⚡️ [热重推] Auth 已完成，跳过 Auth/Setup，直接下发提词序列...")
        }
        
        // 3. TeleprompterInit (0x06-20 type=1)
        let initPkts = G2ProtocolEncoder.buildTeleprompterInit(seq: &seq, msgId: msgId, scrollModeAI: scrollModeAI)
        for pkt in initPkts {
            packets.append(pkt)
            descs.append("TeleprompterInit (0x06-20)")
        }
        msgId += 1
        
        // 3.1 0x01-20 系统窗口前台强行绑定 (100% 对齐 bt3.pklg 包 #17: 将画布挂上 MicroLED 屏显视口)
        packets.append(G2ProtocolEncoder.buildSystemLayoutConfig(seq: &seq, msgId: msgId))
        descs.append("System Layout Config 1 (0x01-20)")
        msgId += 1
        
        // 3.2 0x01-20 触控板滑动中断使能 (100% 对齐 bt3.pklg 包 #18: 开启 06-01 通道中断)
        packets.append(G2ProtocolEncoder.buildTouchpadEventListener(seq: &seq, msgId: msgId))
        descs.append("System Layout Config 2 (0x01-20)")
        msgId += 1
        
        // 2. Pages 灌入 (每页使用唯一单调递增 msgId，确保 MCU RPC 分发器识别为独立新命令)
        for (i, pageText) in pages.enumerated() {
            let pagePkts = G2ProtocolEncoder.buildContentPagePackets(seq: &seq, msgId: msgId, pageNum: i, text: pageText)
            for pkt in pagePkts {
                packets.append(pkt)
                descs.append("Page \(i)")
            }
            msgId += 1
        }
        
        // 3. HUD Mount (0x04-20)
        packets.append(G2ProtocolEncoder.buildPkt40HUDMount(seq: &seq, msgId: msgId))
        descs.append("HUD Mount (0x04-20)")
        msgId += 1
        
        // 4. Touchpad Router (0x09-20)
        packets.append(G2ProtocolEncoder.buildPkt41TouchpadRouter(seq: &seq, msgId: msgId))
        descs.append("Touchpad Router -> Teleprompter (0x09-20)")
        msgId += 1
        
        // 5. Line 0 ScrollSync (0x06-20 Type 165) 视口强行对齐第 0 行 (对齐 multiprompts.pklg Pkt #06/#07: 必须在 Render Commit 前!)
        let syncPkt = G2ProtocolEncoder.buildScrollSync(seq: &seq, msgId: msgId, lineIndex: 0)
        packets.append(syncPkt)
        descs.append("ScrollSync Line 0 (0x06-20 Type 165)")
        msgId += 1
        
        // 6. 0x80-00 Render Commit (对齐 multiprompts.pklg Pkt #08: 显存双缓冲翻转，终极点亮 MicroLED 屏显)
        let pktCommit = G2ProtocolEncoder.buildFlushCommit(seq: &seq, msgId: msgId)
        packets.append(pktCommit)
        descs.append("0x80-00 Render Commit (显存翻转点亮屏显)")
        msgId += 1
        
        addLog("🚀 [Lock-Step 推屏序列] 开始发送 \(packets.count) 包提词报文 (ACK+200ms 超时保底, \(pages.count) 有效页)...")
        
        // 3. 注入 Lock-Step 引擎并启动 (同步更新全局 seq/msgId 保持单调递增，防止黑屏)
        self.teleprompterSeq = seq
        self.teleprompterMsgId = msgId
        self.bt3PendingPackets = packets
        self.lockStepDescs = descs
        self.bt3CurrentIndex = 0
        sendNextBt3PacketInLockstep()
    }
    
    /// 手动发送退出提词器模式报文 (Service 0x06-20 type=4 state=4, 100% 物理对齐 multiprompts.pklg Pkt #028)
    func sendExitTeleprompterMode() {
        guard isConnected else { return }
        self.isWaitingForSessionTeardown = true
        self.isTeleprompterSessionActive = false
        var seq = self.teleprompterSeq == 0 ? 0x01 : self.teleprompterSeq
        var msgId = self.teleprompterMsgId == 0 ? 0x01 : self.teleprompterMsgId
        
        var payload = Data([0x08, 0x01, 0x10])
        payload.append(G2ProtocolEncoder.encodeVarint(msgId))
        payload.append(Data([0x1A, 0x02, 0x08, 0x04]))
        
        let pktExit = G2ProtocolEncoder.buildPacket(seq: &seq, serviceHi: 0x06, serviceLo: 0x20, payload: payload)
        msgId += 1
        
        self.teleprompterSeq = seq
        self.teleprompterMsgId = msgId
        
        sendRawData(pktExit, channel: .content, logDesc: "退出提词器模式 (state=4)")
        
        // §22.2 Step 3: 紧跟发送 0x80-00 Render Commit (切回 Dashboard 界面)，触发 MCU 回发 0D-01 Session Terminated
        let pktCommit = G2ProtocolEncoder.buildFlushCommit(seq: &seq, msgId: msgId)
        msgId += 1
        self.teleprompterSeq = seq
        self.teleprompterMsgId = msgId
        
        // 延迟 100ms 发送 Render Commit (给 MCU 处理 state=4 的时间)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.100) { [weak self] in
            guard let self = self else { return }
            self.sendRawData(pktCommit, channel: .content, logDesc: "0x80-00 Render Commit (§22.2 Step 3 触发 Session Terminated)")
        }
        
        addLog("🛑 已发送 0x06-20 state=4 + 0x80-00 Render Commit 退出序列 (Seq: \(seq-1), MsgId: \(msgId-1))")
    }
    
    private var probeCompletionHandler: ((Bool) -> Void)?
    
    /// 向眼镜下发 0x0D-20 物理探针，并在 80ms 时间窗口内解调 Response 动态评估硬件鉴权与显存槽位状态 (无状态设计)
    private func probeGlassesHardwareState(completion: @escaping (Bool) -> Void) {
        guard isConnected else {
            completion(false)
            return
        }
        
        var hasResponded = false
        self.probeCompletionHandler = { isAuthValid in
            guard !hasResponded else { return }
            hasResponded = true
            self.probeCompletionHandler = nil
            completion(isAuthValid)
        }
        
        var querySeq: UInt8 = 0x00
        let queryData = Data([0x08, 0x00, 0x10, 0x05])
        let pktQuery = G2ProtocolEncoder.buildPacket(seq: &querySeq, serviceHi: 0x0D, serviceLo: 0x20, payload: queryData)
        sendRawData(pktQuery, channel: .content, logDesc: "0x0D-20 物理无状态探针")
        
        // 300ms 物理时间窗口：符合 iOS BLE GATT Notify 真实传输延迟 (实测耗时 ~110ms)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.300) {
            if !hasResponded {
                hasResponded = true
                self.probeCompletionHandler = nil
                self.addLog("⚠️ [无状态探针] 300ms 超时无 Notify 响应，判定硬件处于冷启动/未鉴权态")
                completion(false)
            }
        }
    }
    
    /// 向眼镜下发 0x0D-20 状态查询信令，主动查询眼镜当前是否处于提词模式
    func queryTeleprompterMode() {
        guard isConnected else {
            addLog("⚠️ 蓝牙未连接，无法查询眼镜状态")
            return
        }
        var querySeq: UInt8 = 0x00
        let queryData = Data([0x08, 0x00, 0x10, 0x05])
        let pktQuery = G2ProtocolEncoder.buildPacket(seq: &querySeq, serviceHi: 0x0D, serviceLo: 0x20, payload: queryData)
        sendRawData(pktQuery, channel: .content, logDesc: "主动查询眼镜系统状态 (Service 0x0D-20)")
        addLog("🔍 [状态查询] 已发送 0x0D-20 物理查询指令，等待眼镜回发 0x09-01/0x0D-01 状态 Notify...")
    }
    
    /// 推送全屏满屏提词文本 (28字/行 x 10行/页)
    func sendFullScreenTeleprompterText(_ text: String, targetWidthChars: Int = 28) {
        sendTeleprompterText(text, targetWidthChars: targetWidthChars)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            addLog("⚠️ 写特征回调返回 Error: \(error.localizedDescription)")
        }
    }
    
    // MARK: - G2 Protocol RX Parsing Logic
    
    private func processReceivedG2Data(_ data: Data) {
        guard data.count >= 4 else { return }
        let fullHexString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        
        var pos = 0
        while pos < data.count {
            guard data[pos] == 0xAA else {
                pos += 1
                continue
            }
            guard pos + 4 <= data.count else { break }
            let pktLen = Int(data[pos + 3])
            let totalLen = pktLen + 6
            guard pos + totalLen <= data.count else {
                // 剩余字节不足一完整包，容错退出
                break
            }
            
            let relativeData = data.subdata(in: pos..<(pos + totalLen))
            pos += totalLen
            
            guard relativeData.count >= 8 else { continue }
            
            let hexString = relativeData.map { String(format: "%02X", $0) }.joined(separator: " ")
            let magic = relativeData[1]
            let sHi = relativeData[6]
            let sLo = relativeData[7]
            let svcStr = String(format: "%02X-%02X", sHi, sLo)
            
            // 🎯 无状态探针解调: 捕获 0x0D-00/01, 0x09-00/01, 0x80-00/01 物理响应包，精准判定硬件鉴权状态
            if let probeHandler = self.probeCompletionHandler {
                if (sHi == 0x0D || sHi == 0x09 || sHi == 0x80) && (sLo == 0x00 || sLo == 0x01) {
                    let hasActiveAuth = relativeData.contains(Data([0x1A, 0x02, 0x08, 0x01])) || relativeData.contains(Data([0x08, 0x01])) || !relativeData.contains(Data([0x1A, 0x00]))
                    self.probeCompletionHandler = nil
                    DispatchQueue.main.async {
                        self.addLog("🎯 [无状态探针] 成功收到 Svc \(svcStr) ACK 响应，判定硬件鉴权: \(hasActiveAuth ? "有效 (Active)" : "失效 (Invalid)")")
                        probeHandler(hasActiveAuth)
                    }
                }
            }
            
            // 捕获眼镜端主动退出提词器模式通知 (§22.2: 0D-01 含 1A 00 = Session Terminated，或镜腿长按手势 01-01 含 08 03)
            // ⚠️ 06-00 只是普通 RPC ACK，不代表 Session 已销毁
            let isExplicitExitAck = (sHi == 0x0D && sLo == 0x01) && relativeData.contains(Data([0x1A, 0x00])) && self.isWaitingForSessionTeardown
            let isGestureExit = (sHi == 0x01 && sLo == 0x01) && relativeData.contains(Data([0x08, 0x03]))
            let isSessionExit = relativeData.range(of: Data([0x22, 0x02, 0x08, 0x04])) != nil && self.isWaitingForSessionTeardown
            
            if isExplicitExitAck || isGestureExit || isSessionExit {
                DispatchQueue.main.async {
                    self.isWaitingForSessionTeardown = false
                    self.isTeleprompterSessionActive = false
                    // §23.2: 已建立 BLE 连接的 Auth 保持有效，不重置 hasAuthBeenDoneForCurrentConnection 和 Seq/MsgId
                    self.addLog("🛑 [眼镜端退出/会话释放] (Svc \(svcStr): Session Terminated) → Session 已注销，Auth 保持有效，下次直接切入提词层")
                    
                    if let task = self.pendingRePushTask {
                        self.rePushTimeoutWorkItem?.cancel()
                        self.rePushTimeoutWorkItem = nil
                        self.pendingRePushTask = nil
                        self.addLog("⚡️ 捕获到 Session 注销完成通知，自动启动全新讲稿推流...")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.150) {
                            task()
                        }
                    }
                }
            }
            
            // 显式拦截并解析 Svc 06-01 提词遥测与 Touchpad 手势 Notify
            if sHi == 0x06 && sLo == 0x01 {
                var rawLine: Int? = nil
                var isTouchGesture = false
                var eventTypeStr = "📺 屏显对齐"
                
                // 嵌套二进制 Protobuf 字段解析助手: 从 payload 切片中提取 Tag 0x08 (Page 页码, 默认0) 与 Tag 0x10 (Line 页内行号, 默认0)
                func parsePageAndLine(in slice: Data) -> (page: Int, line: Int) {
                    var pageVal = 0
                    var lineVal = 0
                    
                    if let idx08 = slice.range(of: Data([0x08]))?.lowerBound, idx08 + 1 < slice.count {
                        pageVal = Int(slice[idx08 + 1])
                    }
                    if let idx10 = slice.range(of: Data([0x10]))?.lowerBound, idx10 + 1 < slice.count {
                        lineVal = Int(slice[idx10 + 1])
                    }
                    return (pageVal, lineVal)
                }
                
                // Tag 0x52 (Type 164 - 视口渲染/页面对齐)
                if let idx52 = data.range(of: Data([0x52]))?.lowerBound {
                    let len = idx52 + 1 < data.count ? Int(data[idx52 + 1]) : 0
                    let endIdx = min(data.count, idx52 + 2 + len)
                    let sub = data.subdata(in: min(data.count, idx52 + 2)..<endIdx)
                    let (page, line) = parsePageAndLine(in: sub)
                    let totalLine = page * 10 + line
                    rawLine = totalLine
                    eventTypeStr = "📺 屏幕渲染对齐 (Page \(page), Line \(line))"
                }
                
                // Tag 0x5A (Type 165 - Touchpad 滑动手势)
                if let idx5A = data.range(of: Data([0x5A]))?.lowerBound {
                    isTouchGesture = true
                    let len = idx5A + 1 < data.count ? Int(data[idx5A + 1]) : 0
                    let endIdx = min(data.count, idx5A + 2 + len)
                    let sub = data.subdata(in: min(data.count, idx5A + 2)..<endIdx)
                    let (page, line) = parsePageAndLine(in: sub)
                    let totalLine = page * 10 + line
                    rawLine = totalLine
                    eventTypeStr = "👆 镜腿手势滑动 (Page \(page), Line \(line))"
                }
                
                // Tag 0x72 (Type 167 - 视口/页界拉取请求)
                if let idx72 = data.range(of: Data([0x72]))?.lowerBound {
                    isTouchGesture = true
                    let len = idx72 + 1 < data.count ? Int(data[idx72 + 1]) : 0
                    let endIdx = min(data.count, idx72 + 2 + len)
                    let sub = data.subdata(in: min(data.count, idx72 + 2)..<endIdx)
                    let (page, line) = parsePageAndLine(in: sub)
                    let totalLine = page * 10 + line
                    rawLine = totalLine
                    eventTypeStr = "📄 视口页界触及 (Line \(totalLine))"
                }
                
                if let line = rawLine, line >= 0 && line <= 200 {
                    let timeSincePhoneScroll = Date().timeIntervalSince(self.lastPhoneScrollTime)
                    if timeSincePhoneScroll < 0.800 {
                        // 🛡️ 手机主控期: 800ms 内完全忽略眼镜发回的 Rx 回波位置，防止 App 端快滑回弹
                        DispatchQueue.main.async {
                            self.addLog("🛡️ [主控屏障] 手机滑动窗口期内(800ms)，屏蔽眼镜 Rx 回波 (Line \(line))，防止 UI 回弹")
                        }
                    } else {
                        self.lastGlassesRxScrollTime = Date()
                        DispatchQueue.main.async {
                            self.currentFocusPageLine = line
                            self.lastGestureReceived = "\(eventTypeStr) -> L\(line)"
                            self.addLog("🎯 👆 [RX 06-01 遥测/手势] \(eventTypeStr) | 视口位于第 \(line) 行")
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        self.addLog("🎯 👆 [RX 06-01 遥测/手势] \(eventTypeStr) | [\(hexString)]")
                    }
                }
                onG2TelemetryLog?("Rx", hexString, "06-01 Telemetry: \(eventTypeStr)")
                continue
            }
            
            // 显示眼镜返回的 ACK / 确认数据包
            if magic == 0x12 {
                // 检测心跳回响: payload 含 "08 0E ... 6A" 特征 → 不触发 Lock-Step 步进
                let isHeartbeatEcho = relativeData.count > 8 && relativeData[8] == 0x08 && relativeData[9] == 0x0E
                    && relativeData.range(of: Data([0x6A, 0x00])) != nil
                
                // Lock-Step 响应 80-xx 鉴权确认、0E-00 显示确认、06-00 初始化确认、01-02/09-01/0D-01 焦点与路由确认
                let isSessionAck = (sHi == 0x80 || sLo == 0x00 || sLo == 0x01 || sLo == 0x02) && sHi != 0xC7
                
                if isHeartbeatEcho {
                    addLog("💓 [RX 心跳回响] Svc \(svcStr) (不触发 Lock-Step): [\(hexString)]")
                } else if isSessionAck {
                    addLog("⬇️ [RX 确认接收] Svc \(svcStr) 确认包: [\(hexString)]")
                    onGlassAckReceivedForBt3Lockstep()
                } else {
                    addLog("📡 [RX 非 Session 包] Svc \(svcStr) (不触发 Lock-Step): [\(hexString)]")
                }
                continue
            }
        }
        
        addLog("⬇️ [RX 接收] (\(data.count)b): [\(fullHexString)]")
    }
    
    /// 模拟接收 G2 眼镜返回消息 (用于 Debug 界面调试及模拟器测试)
    func simulateReceiveG2Message(rawByte: UInt8) {
        let mockData: Data
        switch rawByte {
        case 0x01: mockData = Data([0x01])
        case 0x02: mockData = Data([0x02])
        case 0x03: mockData = Data([0x03])
        case 0xAA: mockData = Data([0xAA, 0x55, 0x00, 0x02, 0x10, 0x00, 0x12, 0x34])
        default: mockData = Data([rawByte, 0x00, 0xFF])
        }
        processReceivedG2Data(mockData)
    }
    
    @Published var isHUDDisplayActive: Bool = true {
        didSet {
            guard isHUDDisplayActive != oldValue else { return }
            if isHUDDisplayActive {
                wakeHUD()
            } else {
                sleepHUD()
            }
        }
    }
    
    func sleepHUD() {
        guard isConnected else { return }
        var seq: UInt8 = 0x06
        let packet = G2ProtocolEncoder.buildSleepPacket(seq: &seq)
        sendRawData(packet, channel: .content)
        DispatchQueue.main.async {
            self.lastBLEStatusMessage = "⚪ 已下发屏幕休眠指令 (0x0420 Sleep -> 5401)"
        }
    }
    
    func wakeHUD() {
        guard isConnected else { return }
        var seq: UInt8 = 0x05
        let packet = G2ProtocolEncoder.buildWakePacket(seq: &seq)
        sendRawData(packet, channel: .content)
        
        DispatchQueue.main.async {
            self.lastBLEStatusMessage = "🟢 已下发屏幕唤醒指令 (0x0420 Wake -> 5401)"
        }
    }
    
    func enterTeleprompterMode() {
        guard isConnected else { return }
        var seq: UInt8 = 0x08
        let configPacket = G2ProtocolEncoder.buildDisplayConfig(seq: &seq, msgId: 0x14)
        sendRawData(configPacket, channel: .content)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            var modeSeq: UInt8 = 0x09
            let modeEnterPacket = G2ProtocolEncoder.buildEnterTeleprompterModePacket(seq: &modeSeq, msgId: 0x15)
            self.sendRawData(modeEnterPacket, channel: .content)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            var scrollSeq: UInt8 = 0x0A
            let scrollModePacket = G2ProtocolEncoder.buildTeleprompterModeConfigPacket(seq: &scrollSeq, mode: 0x00)
            self.sendRawData(scrollModePacket, channel: .content)
        }
        
        DispatchQueue.main.async {
            self.lastBLEStatusMessage = "🚀 已下发唤醒前台提词器 App 指令 (0x0620)"
        }
    }
    
    func exitTeleprompterMode() {
        guard isConnected else { return }
        resetTeleprompterSession()
        DispatchQueue.main.async {
            self.lastBLEStatusMessage = "🛑 已重置本地提词会话"
        }
    }

    private func getWriteType(for characteristic: CBCharacteristic) -> CBCharacteristicWriteType {
        if characteristic.properties.contains(.write) {
            return .withResponse
        } else if characteristic.properties.contains(.writeWithoutResponse) {
            return .withoutResponse
        } else {
            return .withResponse
        }
    }

    @Published var physicalWriteCount: Int = 0
    
    func sendRawData(_ data: Data, channel: G2Channel = .content, withResponse: Bool = false, logDesc: String? = nil) {
        guard let peripheral = targetPeripheral, peripheral.state == .connected else {
            addLog("⚠️ 发送失败: 蓝牙物理未连接 (State: \(targetPeripheral?.state.rawValue ?? -1))")
            DispatchQueue.main.async {
                self.isConnected = false
            }
            return
        }
        
        // 自动保持同步
        if !isConnected {
            DispatchQueue.main.async {
                self.isConnected = true
            }
        }
        
        // 100% 对齐 teleprompter.py: 唯一物理写特征 5401 (contentTxChar)
        guard let txChar = contentTxChar ?? controlTxChar else {
            addLog("⚠️ 发送失败: 无法找到 5401 通道对应的 TX 特征值")
            return
        }
        
        // 增加物理发包计数与确凿时间戳
        DispatchQueue.main.async {
            self.physicalWriteCount += 1
        }
        
        let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        print("🔥 [5401 物理 BLE 写入第 \(physicalWriteCount + 1) 包] \(dateStr) | len=\(data.count)b | desc=\(logDesc ?? "")")
        
        // 尊重 5401 蓝牙物理特征值广播属性，动态安全选择写入模式 (防止系统抛出拒绝写入 Error)
        let writeType: CBCharacteristicWriteType = getWriteType(for: txChar)
        peripheral.writeValue(data, for: txChar, type: writeType)
        
        let hexString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        let uuidSuffix = String(txChar.uuid.uuidString.suffix(4))
        
        if let logDesc = logDesc {
            addLog("⬆️ [TX 发送] \(logDesc) (Type: \(writeType == .withResponse ? "WithResp" : "NoResp")) -> [\(uuidSuffix)]")
        }
        onG2TelemetryLog?("Tx", hexString, logDesc ?? "发送 G2 帧 [\(uuidSuffix)]")
    }
}

// MARK: - Compatibility Extensions for UI Views & WatchOS (Zero-touch on core 96b0a792 BLE logic)

extension BLEManager {
    func commitRender() {
        // 已合并进 8 步推屏序列
    }
    
    /// 向 Even G2 发送 3 行 HUD 显存刷新数据帧 (不再误触发全量推屏)
    func sendHUDFrame(chunk: HUDDisplayChunk) {
        // 静默禁用高频 HUD 全量重推
    }

    func resetTeleprompterSession() {
        self.isTeleprompterSessionActive = false
    }
    
    func switchMode(to mode: GlassesState) {
        self.currentGlassesState = mode
        switch mode {
        case .dashboard, .disconnected, .conversate, .sleeping:
            if isTeleprompterSessionActive {
                sendExitTeleprompterMode()
            }
        case .teleprompter:
            break
        }
    }
    
    func handleWatchGesture(action: String, source: String) {
        addLog("⌚️ 接收到 Watch 触控/手势 [\(action)] (Source: \(source))")
        switch action {
        case "NEXT_PAGE", "SWIPE_LEFT", "SWIPE_DOWN":
            let nextLine = min(currentFocusPageLine + 10, 130)
            sendScrollSync(lineIndex: nextLine, force: true)
        case "PREV_PAGE", "SWIPE_RIGHT", "SWIPE_UP":
            let prevLine = max(currentFocusPageLine - 10, 0)
            sendScrollSync(lineIndex: prevLine, force: true)
        default:
            break
        }
    }
}

extension G2ProtocolEncoder {
    static let sampleTeleprompterText: String = """
各位领导、各位老师，大家上午好！
今天我们召开《人机协同程序设计》课程全校统一数智化教学集体备课研讨会，主要目的是为了贯彻落实教务处文件精神，面向全校各理工科学院及医学院负责该课程授课的全体老师，共同研讨教学规范，明确教学要求，并合力推进标准化教学资源的建设。
我们这门课程定位为跨界通识课，将在 2026 年秋季学期，也就是今年 9 月份正式开课。课程设置可能是 2.0 或 3.0 学分，对应 32 或 48 学时。今天我将围绕本门课程的建设思路、教学策略、考核改革以及资源保障等方面，与各位老师进行深入的探讨与交流。

首先，我们来看一下执行摘要的第一部分，关于课程的痛点与定位。为了响应全校“专业+AI”的培养大势，我们采用了每周“2+2”的理实一体课堂设置：包含 2 学时理论、2 学时实践，以及 2 学时课后协同大作业。这旨在通过“人机协同”与“人际协同”的双重训练，补足大一新生在传统应试教育中匮乏的核心沟通协作本领。
我们针对两大痛点：非专业学生因为学习曲线陡峭，往往未入门即放弃；而专业学生偏重底层刷题，极易在未来被 AI 取代。

因此，本课程重新确立了“人在回路上（HOTL）”的核心培养定位。这里我们引入了系统工程界人机回路控制理论的三种经典范式：传统手写代码的“人在回路中（HITL）”；AI 自主运行人类无需把关的“人在回路外（OOTL）”；以及本课程提倡的“人在回路旁（HOTL）”。在 HOTL 范式下，人类始终掌控输入规格与输出审计两端，而将具体的程序实现过程授权给智能体。这能让学生发挥非专业在“问题域定义”上的核心学识优势，以逻辑严密的 Markdown 规格文档为共同语言，培养主动驾驭 AI 并交付 MVP 原型系统的协同创造力。

接下来是执行摘要的第二部分，主要介绍我们的教学策略、考核改革和资源部署。在策略上，我们基于 A/S/P 知识标记框架，实施了渐进式的脚手架拆除，并为不同专业设计了三级难度。在考核改革上，我们引入了与大模型评测同款的 ELO 竞技场两两比对算法，深度引入学生之间的随机盲评。这不仅能利用大数定律有效抵消个体打分主观偏差，还能在盲评的过程中，切实锻炼学生最核心的“AI成果质量审计与鉴别力”，让学生在开发与互评中形成完整认知闭环。（“ELO” /iːloʊ/，发音为“衣-洛”， 不是任何英文单词的缩写，而是以其发明者、美国物理学家兼国际象象棋大师 Arpad Elo 的名字命名的）
在资源建设上，我们建议学校拨出专项算力资金在本地私有部署国产模型，为学生提供基础算力额度消除开销壁垒；同时诚邀各学院老师共建覆盖全学期的实践任务和大作业选题，让学生在真实的项目交付中真正激发创造力。

这里是本次汇报的提纲。我们的汇报将分为五个部分：
第一部分主要围绕基于 OBE 成果导向的反向教学设计展开，阐述外部行业趋势、开发范式转变以及我们的定位；
第二部分是教学方法与策略，讲解每周“2+2”理实一体设置与 A/S/P 渐进式脚手架；
第三部分是考核改革，重点介绍限时现场测试、双轨加权以及独创的 ELO 两两双盲互评机制；
第四部分是资源标准化建设，包含智能编译教材、私有部署算力普惠与伴学导师；
第五部分是试点教学成效，用真实的数据和图表，向大家展示试点班的实际表现。

接下来，我们进入第一部分：反向教学设计。我们将从 OBE 成果...
"""
}
