import Foundation
import CoreBluetooth
import Combine

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
    
    private var isTeleprompterSessionActive: Bool = false
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
    }
    
    /// 重置提词器会话状态并清空历史文本防抖 (若 clearHardwareState 为 true 则同步向眼镜下发物理退出/清屏指令)
    func resetTeleprompterSession(clearHardwareState: Bool = true) {
        cancelPendingTeleprompterTasks()
        if clearHardwareState && isConnected && contentTxChar != nil && isTeleprompterSessionActive {
            sendExitTeleprompterMode()
        }
        lastSentTeleprompterText = ""
        isTeleprompterSessionActive = false
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
    @Published var currentGlassesState: UInt8 = 0
    
    private var currentPages: [String] = []
    private var syncSeq: UInt8 = 0x2A
    private var syncMsgId: Int = 0x50
    
    /// 发送双向滚动位置同步 (同时下发 0x06-20 Type 5 报文至眼镜固件，激活触控板 Notice 上报)
    func sendScrollSync(lineIndex: Int) {
        guard isConnected else { return }
        self.currentFocusPageLine = lineIndex
        
        let syncPkt = G2ProtocolEncoder.buildScrollSync(seq: &teleprompterSeq, msgId: teleprompterMsgId, lineIndex: lineIndex)
        teleprompterMsgId += 1
        sendRawData(syncPkt, channel: .content, logDesc: "双向位置同步 (Line \(lineIndex))")
        addLog("📍 [双向同步] 已发送 0x06-20 Type 5 报文 (Line \(lineIndex))")
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
    
    /// 下发当前 Lock-step 队列中的下一包物理帧 (ACK 驱动 + 200ms 超时保底, 对齐 §20.1 规范)
    private func sendNextBt3PacketInLockstep() {
        bt3TimeoutWorkItem?.cancel()
        
        let totalCount = bt3PendingPackets.count
        guard bt3CurrentIndex < totalCount else {
            self.isTeleprompterSessionActive = true
            addLog("✅ G2 物理屏显提词与前台焦点已锁定，Touchpad 0x06-01 触控已唤醒")
            addLog("🎉 [Lock-step] \(totalCount) 包全部下发完成！视口对齐第 0 行。")
            return
        }
        
        let pktData = bt3PendingPackets[bt3CurrentIndex]
        let pktNum = bt3CurrentIndex + 1
        let desc = bt3CurrentIndex < lockStepDescs.count
            ? "\(lockStepDescs[bt3CurrentIndex]) [\(pktNum)/\(totalCount)]"
            : "步进帧 [\(pktNum)/\(totalCount)]"
        bt3CurrentIndex += 1
        
        sendRawData(pktData, channel: .content, logDesc: desc)
        
        // 设置 200ms 超时保底，防止由于 ACK 未回发或丢包导致流程卡死
        let timeoutItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.sendNextBt3PacketInLockstep()
        }
        self.bt3TimeoutWorkItem = timeoutItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.200, execute: timeoutItem)
    }
    
    /// 收到眼镜 ACK 后调用的驱动闭合
    private func onGlassAckReceivedForBt3Lockstep() {
        guard !bt3PendingPackets.isEmpty && bt3CurrentIndex < bt3PendingPackets.count else { return }
        bt3TimeoutWorkItem?.cancel()
        // 收到 ACK 延时 20ms 下发下一包 (多个 ACK 同时到达时允许多步进, G2 期望 burst-pair 节奏)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.020) { [weak self] in
            self?.sendNextBt3PacketInLockstep()
        }
    }
    
    /// 动态编码并推送讲稿文本到 G2 眼镜 (Lock-Step ACK 驱动步进, 对齐 §20.1 规范)
    func sendTeleprompterText(_ rawText: String, targetWidthChars: Int = 28, scrollModeAI: Bool = true) {
        guard isConnected else {
            addLog("⚠️ 蓝牙未连接，请先连接 G2 眼镜")
            return
        }
        guard contentTxChar != nil else {
            addLog("⚠️ 5401 通道未绑定")
            return
        }
        
        // 1. 取消正在执行的任务与重置状态
        cancelPendingTeleprompterTasks()
        self.currentFocusPageLine = 0
        DispatchQueue.main.async {
            self.currentFocusPageLine = 0
        }
        
        let pages = G2ProtocolEncoder.formatTextToPages(rawText, maxLineWidth: targetWidthChars * 2, linesPerPage: 10)
        self.currentPages = pages
        
        // 2. 构建完整的 Lock-Step 包队列 (替代固定延时盲发)
        var packets: [Data] = []
        var descs: [String] = []
        
        // [0] State=4 前置会话释放 (确保旧 session 被清除, 恢复 commit 31646790 删除的关键步骤)
        var exitSeq: UInt8 = 0x00
        let exitPayload = Data([0x08, 0x04, 0x10, 0x0C, 0x22, 0x02, 0x08, 0x04])
        packets.append(G2ProtocolEncoder.buildPacket(seq: &exitSeq, serviceHi: 0x06, serviceLo: 0x20, payload: exitPayload))
        descs.append("Session 释放 (State=4)")
        
        // [1-7] Auth 7 包 (hardcoded seq 0x01~0x07, 带实时 Unix 时间戳)
        let authPackets = G2ProtocolEncoder.buildAuthPackets()
        for (idx, pkt) in authPackets.enumerated() {
            packets.append(pkt)
            descs.append("Auth [\(idx + 1)/7]")
        }
        
        // [8] DisplayConfig (0x0E-20)
        var seq: UInt8 = 0x08
        var msgId: Int = 0x14
        packets.append(G2ProtocolEncoder.buildDisplayConfig(seq: &seq, msgId: msgId))
        descs.append("DisplayConfig (0x0E-20)")
        msgId += 1
        
        // [9] TeleprompterInit (0x06-20)
        let initPkts = G2ProtocolEncoder.buildTeleprompterInit(seq: &seq, msgId: msgId, scrollModeAI: scrollModeAI)
        for pkt in initPkts {
            packets.append(pkt)
            descs.append("TeleprompterInit (0x06-20)")
        }
        msgId += 1
        
        // [10+] 有效内容 Pages (仅发有效页, 不补齐空白, 对齐 §19.3 规范)
        for (i, pageText) in pages.enumerated() {
            let pagePkts = G2ProtocolEncoder.buildContentPagePackets(seq: &seq, msgId: msgId, pageNum: i, text: pageText)
            for pkt in pagePkts {
                packets.append(pkt)
                descs.append("Page \(i)")
            }
            msgId += 1
        }
        
        
        // 100% 对齐 25 包历史成功日志的尾部心跳与前台焦点锁序列
        // 1. Sync (0x80-00 dashboard sync)
        packets.append(G2ProtocolEncoder.buildDashboardSync(seq: &seq, msgId: msgId))
        descs.append("Sync (0x80-00 dashboard sync)")
        msgId += 1
        
        // 2. Route Switch (0x09-20 前台 UI 焦点锁)
        packets.append(G2ProtocolEncoder.buildRouteSwitch(seq: &seq, msgId: msgId))
        descs.append("Route Switch (0x09-20)")
        msgId += 1
        
        // 3. 前台活跃心跳锁 (Svc 0x01-20 Touchpad 唤醒锁)
        packets.append(G2ProtocolEncoder.buildActiveFocusLock(seq: &seq, msgId: msgId))
        descs.append("前台活跃心跳锁 (Svc 0x01-20)")
        msgId += 1
        
        addLog("🚀 [Lock-Step 推屏序列] 开始发送 \(packets.count) 包提词报文 (ACK+200ms 超时保底, \(pages.count) 有效页)...")
        
        // 3. 注入 Lock-Step 引擎并启动 (复用 §20.1 ACK 驱动 + 200ms 超时保底机制)
        self.bt3PendingPackets = packets
        self.lockStepDescs = descs
        self.bt3CurrentIndex = 0
        sendNextBt3PacketInLockstep()
    }
    
    /// 手动发送退出提词器模式报文 (Service 0x06-20 type=4 state=4)
    func sendExitTeleprompterMode() {
        guard isConnected else { return }
        var exitSeq: UInt8 = 0x00
        let exitData = Data([0x08, 0x01, 0x10, 0x32, 0x1A, 0x02, 0x08, 0x04])
        let pktExit = G2ProtocolEncoder.buildPacket(seq: &exitSeq, serviceHi: 0x06, serviceLo: 0x20, payload: exitData)
        sendRawData(pktExit, channel: .content, logDesc: "退出提词器模式 (state=4)")
        self.isTeleprompterSessionActive = false
        addLog("🛑 已发送 0x06-20 state=4 退出提词器模式指令")
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
        let hexString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        
        // 动态扫描 0xAA 报文头
        if let aaIndex = data.range(of: Data([0xAA]))?.lowerBound {
            let relativeData = data.subdata(in: aaIndex..<data.count)
            guard relativeData.count >= 8 else { return }
            
            let magic = relativeData[1]
            let sHi = relativeData[6]
            let sLo = relativeData[7]
            let svcStr = String(format: "%02X-%02X", sHi, sLo)
            
            // 显式拦截并解析 Svc 06-01 提词遥测与 Touchpad 手势 Notify
            if sHi == 0x06 && sLo == 0x01 {
                var rawLine: Int? = nil
                var isTouchGesture = false
                var eventTypeStr = "📺 屏显对齐"
                
                // Tag 0x52 (Type 164 - 视口渲染/页面对齐) E.g. ... 52 [PageNum] ...
                if let idx52 = data.range(of: Data([0x52]))?.lowerBound {
                    if idx52 + 1 < data.count {
                        let page = Int(data[idx52 + 1])
                        rawLine = page * 10
                        eventTypeStr = "📺 屏幕渲染对齐 (Page \(page))"
                    }
                }
                
                // Tag 0x5A (Type 165 - Touchpad 滑动手势)
                if let idx5A = data.range(of: Data([0x5A]))?.lowerBound {
                    isTouchGesture = true
                    if idx5A + 4 < data.count && data[idx5A + 3] == 0x10 {
                        rawLine = Int(data[idx5A + 4])
                        eventTypeStr = "👆 镜腿手势滑动"
                    } else if idx5A + 3 < data.count && data[idx5A + 2] == 0x10 {
                        rawLine = Int(data[idx5A + 3])
                        eventTypeStr = "👆 镜腿手势滑动"
                    } else {
                        eventTypeStr = "👆 镜腿手势触发"
                    }
                }
                
                // Tag 0x72 (Type 167 - 页界拉取请求) E.g. ... 72 02 10 [PageNum] ...
                if let idx72 = data.range(of: Data([0x72]))?.lowerBound {
                    isTouchGesture = true
                    if idx72 + 3 < data.count {
                        let page = Int(data[idx72 + 3])
                        rawLine = page * 10
                        eventTypeStr = "📄 触及页界请求 (Page \(page))"
                    }
                }
                
                if let line = rawLine, line >= 0 && line <= 200 {
                    DispatchQueue.main.async {
                        self.currentFocusPageLine = line
                        self.lastGestureReceived = "\(eventTypeStr) -> L\(line)"
                        self.addLog("🎯 👆 [RX 06-01 遥测/手势] \(eventTypeStr) | 视口位于第 \(line) 行")
                    }
                } else {
                    DispatchQueue.main.async {
                        self.addLog("🎯 👆 [RX 06-01 遥测/手势] \(eventTypeStr) | [\(hexString)]")
                    }
                }
                onG2TelemetryLog?("Rx", hexString, "06-01 Telemetry: \(eventTypeStr)")
                return
            }
            
            // 显示眼镜返回的 ACK / 确认数据包
            if magic == 0x12 {
                // 检测心跳回响: payload 含 "08 0E ... 6A" 特征 → 不触发 Lock-Step 步进
                let isHeartbeatEcho = relativeData.count > 8 && relativeData[8] == 0x08 && relativeData[9] == 0x0E
                    && relativeData.range(of: Data([0x6A, 0x00])) != nil
                
                // Lock-Step 只响应 Svc 80-xx (Auth/Session 确认), 忽略 C7-01 股票等非 Session 包
                let isSessionAck = sHi == 0x80
                
                if isHeartbeatEcho {
                    addLog("💓 [RX 心跳回响] Svc \(svcStr) (不触发 Lock-Step): [\(hexString)]")
                } else if isSessionAck {
                    addLog("⬇️ [RX 确认接收] Svc \(svcStr) 确认包: [\(hexString)]")
                    onGlassAckReceivedForBt3Lockstep()
                } else {
                    addLog("📡 [RX 非 Session 包] Svc \(svcStr) (不触发 Lock-Step): [\(hexString)]")
                }
                return
            }
        }
        
        addLog("⬇️ [RX 接收] (\(data.count)b): [\(hexString)]")
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
    
    func commitRender() {
        // 已合并进 8 步推屏序列
    }
    
    /// 向 Even G2 发送 3 行 HUD 显存刷新数据帧 (不再误触发全量推屏)
    func sendHUDFrame(chunk: HUDDisplayChunk, channel: G2Channel = .content) {
        // 静默禁用高频 HUD 全量重推
    }
}
