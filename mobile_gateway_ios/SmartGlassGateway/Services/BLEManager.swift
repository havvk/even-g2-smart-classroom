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
            self.lastBLEStatusMessage = "正在扫描附近的 Even G2 眼镜..."
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
            
            // 开启 Notify 接收通道
            if canNotify {
                peripheral.setNotifyValue(true, for: characteristic)
                addLog("🔔 已开启 Notify/Indicate 接收通道: \(uuidStr)")
            }
            
            // 按 UUID 结尾绑定 G2 专属 Channel 特征通道 (排除 6E40 串口)
            if canWrite {
                if uuidStr.contains("0001") {
                    controlTxChar = characteristic
                    addLog("✍️ 绑定 [0001 控制通道] 写特征: \(uuidStr)")
                } else if uuidStr.contains("5401") {
                    contentTxChar = characteristic
                    addLog("✍️ 绑定 [5401 内容通道] 写特征: \(uuidStr)")
                } else if uuidStr.contains("6401") {
                    renderingTxChar = characteristic
                    addLog("✍️ 绑定 [6401 渲染通道] 写特征: \(uuidStr)")
                } else if uuidStr.contains("7401") {
                    teleprompterTxChar = characteristic
                    addLog("✍️ 绑定 [7401 提词器通道] 写特征: \(uuidStr)")
                }
            }
        }
        
        // 当获取到了任意有效 G2 写特征且尚未执行握手时，预留通道
        let hasAnyTxChar = controlTxChar != nil || contentTxChar != nil || teleprompterTxChar != nil
        if hasAnyTxChar {
            addLog("✍️ 已成功识别并绑定 G2 物理写特征通道")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let uuidStr = characteristic.uuid.uuidString.uppercased()
        if let error = error {
            addLog("❌ Notify 通道订阅失败 (\(uuidStr)): \(error.localizedDescription)")
        } else {
            addLog("✅ Notify 通道订阅成功 (\(uuidStr)), isNotifying=\(characteristic.isNotifying)")
            if uuidStr.contains("5402") || uuidStr.contains("0002") {
                checkAndExecutePendingPush()
            }
        }
    }
    
    // 独立握手已废弃，统一由 sendTeleprompterText 自包含串行下发 Auth 鉴权序列
    
    private var isTeleprompterSessionActive: Bool = false
    private var teleprompterWorkItems: [DispatchWorkItem] = []
    @Published var lastSentTeleprompterText: String = ""
    
    /// 撤销所有尚未执行的倒计时推屏发包任务
    private func cancelPendingTeleprompterTasks() {
        for item in teleprompterWorkItems {
            item.cancel()
        }
        teleprompterWorkItems.removeAll()
    }
    
    /// 重置提词器会话状态并清空历史文本防抖
    func resetTeleprompterSession() {
        cancelPendingTeleprompterTasks()
        lastSentTeleprompterText = ""
        isTeleprompterSessionActive = false
    }
    
    /// 实时当前滚动的焦点行号回调 (用于 9 行所见即所得 View 高亮卡片)
    @Published var currentFocusPageLine: Int = 0
    @Published var currentWrappedLines: [String] = []
    
    /// 发送双向滚动同步报文 (App 向 Glasses 下发焦点行号)
    func sendScrollSync(pageLine: Int) {
        guard isConnected else { return }
        self.currentFocusPageLine = pageLine
        let packet = G2ProtocolEncoder.buildScrollSync(seq: 0x2A, msgId: 0x50, pageLine: pageLine)
        sendRawData(packet, channel: .content)
    }
    
    // 自动补发队列
    private var pendingPushText: String?
    private var pendingPushTargetWidth: Int?
    
    private func checkAndExecutePendingPush() {
        DispatchQueue.main.async {
            self.connectionState = .channelsReady
        }
        guard let text = pendingPushText else { return }
        let width = pendingPushTargetWidth ?? 28
        pendingPushText = nil
        pendingPushTargetWidth = nil
        addLog("🚀 [FSM: channelsReady] G2 5401 物理通道已绑定就绪，自动唤醒下发队列中的推屏请求！")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.sendTeleprompterText(text, targetWidthChars: width)
        }
    }
    
    /// 推送全屏提词文本 (28 汉字 x 10 行全屏模式)
    func sendTeleprompterText(_ rawText: String, targetWidthChars: Int = 28) {
        guard isConnected else {
            addLog("⏳ [FSM: disconnected] 蓝牙未连接，已自动启动 BLE 扫描并拉起连接，推屏请求已存入待处理队列...")
            pendingPushText = rawText
            pendingPushTargetWidth = targetWidthChars
            startScanning()
            return
        }
        guard contentTxChar != nil else {
            addLog("⏳ [FSM: gattDiscovering] G2 5401 通道就绪中，推屏请求已放入待处理队列，绑定后自动下发...")
            pendingPushText = rawText
            pendingPushTargetWidth = targetWidthChars
            return
        }
        
        lastSentTeleprompterText = rawText
        
        // 关键防护: 如果当前正在密集发包中，则忽略重复击打防抖
        guard !isTeleprompterSessionActive else {
            addLog("⚠️ 提词推屏任务进行中，自动忽略并发击打")
            return
        }
        
        cancelPendingTeleprompterTasks()
        isTeleprompterSessionActive = true
        
        // 1. 动态排版格式化 (单页 10 行全屏，幅宽 28 汉字)
        let linesPerPage = 10
        let (pages, wrappedLines, _) = G2ProtocolEncoder.formatTextToPages(rawText, maxCharsPerLine: targetWidthChars, linesPerPage: linesPerPage)
        self.currentWrappedLines = wrappedLines
        
        let totalLines = max(140, pages.count * linesPerPage)
        addLog("📜 准备推屏: 文本切分为 \(pages.count) 页 (\(linesPerPage)行/页, 幅宽\(targetWidthChars)字), 画布总行数 \(totalLines) 行")
        
        var delay: Double = 0.2
        
        let scheduleTask = { (delayInSeconds: Double, action: @escaping () -> Void) in
            let item = DispatchWorkItem {
                action()
            }
            self.teleprompterWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delayInSeconds, execute: item)
        }
        
        // =========================================================================
        // 阶段 1: 前置链路与 G2 OS 窗口准备动作 (Preparation Sequence)
        // =========================================================================
        
        // 1. Session Auth (7 帧鉴权: 5401)
        addLog("🔐 [步骤 1/5] 执行 Session 安全鉴权 (7 帧 Auth)")
        let authPackets = G2ProtocolEncoder.buildAuthPackets()
        for pkt in authPackets {
            let currentPkt = pkt
            scheduleTask(delay) {
                self.sendRawData(currentPkt, channel: .content, logDesc: "Auth 鉴权包")
            }
            delay += 0.1
        }
        delay += 0.5 // Auth 完成后沉淀 0.5s
        
        var seq: UInt8 = 0x08
        var msgId: Int = 0x14
        
        // 2. DisplayWake (0x04-20) - 物理点亮 MicroLED 显示引擎总线供电 (5401)
        let wakePacket = G2ProtocolEncoder.buildWakePacket(seq: seq, msgId: msgId)
        seq &+= 1; msgId += 1
        scheduleTask(delay) {
            self.addLog("🟢 [步骤 2/5] 点亮 MicroLED 屏幕物理电源 (DisplayWake)")
            self.sendRawData(wakePacket, channel: .content, logDesc: "DisplayWake 电源唤醒")
        }
        delay += 0.3
        
        // 3. DisplayConfig (0x0E-20) - 物理屏显校准 Hex 数据
        let configPacket = G2ProtocolEncoder.buildDisplayConfig(seq: seq, msgId: msgId)
        seq &+= 1; msgId += 1
        scheduleTask(delay) {
            self.addLog("⚙️ [步骤 3/5] 配置物理视口 (官方 DisplayConfig 106 字节校准包)")
            self.sendRawData(configPacket, channel: .content, logDesc: "DisplayConfig 幅宽配置")
        }
        delay += 0.3
        
        // 4. TeleprompterInit (0x06-20 type=1) - 激活提词器前台 App (644px 全宽)
        let initPacket = G2ProtocolEncoder.buildTeleprompterInit(seq: seq, msgId: msgId, totalLines: totalLines, manualMode: true)
        seq &+= 1; msgId += 1
        scheduleTask(delay) {
            self.addLog("🎬 [步骤 4/4] 初始化提词器画布 (140 行显存, 自动拉起前台)")
            self.sendRawData(initPacket, channel: .content, logDesc: "TeleprompterInit 画布初始化")
        }
        delay += 0.5
        
        // =========================================================================
        // 阶段 2: 官方标准 14 页正文分批下发与 GPU VSYNC 物理刷屏
        // =========================================================================
        
        // 6. Send Content Pages 0-9 (5401)
        let firstBatchCount = min(10, pages.count)
        for i in 0..<firstBatchCount {
            let pageMsg = msgId
            let pageText = pages[i]
            let packets = G2ProtocolEncoder.buildContentPagePackets(seq: &seq, msgId: pageMsg, pageNum: i, text: pageText, lineCount: linesPerPage)
            msgId += 1
            let pageIndex = i
            let pagePackets = packets
            scheduleTask(delay) {
                let previewStr = pageText.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                let displayPreview = previewStr.isEmpty ? "(空白填充页)" : "「\(previewStr.prefix(12))...」"
                self.addLog("📝 推送正文第 \(pageIndex + 1)/\(pages.count) 页 (\(pagePackets.count)分包): \(displayPreview)")
                for pkt in pagePackets {
                    self.sendRawData(pkt, channel: .content, logDesc: "正文页 \(pageIndex + 1)")
                }
            }
            delay += 0.1
        }
        
        // 7. Mid-Stream Marker 255 (5401)
        let markerPacket = G2ProtocolEncoder.buildMarker(seq: seq, msgId: msgId)
        seq &+= 1; msgId += 1
        scheduleTask(delay) {
            self.sendRawData(markerPacket, channel: .content, logDesc: "Mid-stream Marker 255")
        }
        delay += 0.1
        
        // 8. Send Content Pages 10-11 (5401)
        if pages.count > 10 {
            let secondBatchCount = min(12, pages.count)
            for i in 10..<secondBatchCount {
                let pageMsg = msgId
                let pageText = pages[i]
                let packets = G2ProtocolEncoder.buildContentPagePackets(seq: &seq, msgId: pageMsg, pageNum: i, text: pageText, lineCount: linesPerPage)
                msgId += 1
                let pageIndex = i
                let pagePackets = packets
                scheduleTask(delay) {
                    self.addLog("📝 推送正文第 \(pageIndex + 1)/\(pages.count) 页 (空白填充)")
                    for pkt in pagePackets {
                        self.sendRawData(pkt, channel: .content, logDesc: "正文页 \(pageIndex + 1)")
                    }
                }
                delay += 0.1
            }
        }
        
        // 9. GPU VSYNC Sync Trigger (Service 0x80-00 type=14 -> 5401) -- 触发物理刷屏！
        let syncPacket = G2ProtocolEncoder.buildSync(seq: seq, msgId: msgId)
        seq &+= 1; msgId += 1
        scheduleTask(delay) {
            self.addLog("✨ 触发 MicroLED 显示芯片 VSYNC 刷屏 (Buffer 翻转)")
            self.sendRawData(syncPacket, channel: .content, logDesc: "GPU VSYNC 刷屏脉冲")
        }
        delay += 0.1
        
        // 10. Send Remaining Content Pages 12-13 (5401)
        if pages.count > 12 {
            for i in 12..<pages.count {
                let pageMsg = msgId
                let pageText = pages[i]
                let packets = G2ProtocolEncoder.buildContentPagePackets(seq: &seq, msgId: pageMsg, pageNum: i, text: pageText, lineCount: linesPerPage)
                msgId += 1
                let pageIndex = i
                let pagePackets = packets
                scheduleTask(delay) {
                    for pkt in pagePackets {
                        self.sendRawData(pkt, channel: .content, logDesc: "正文页 \(pageIndex + 1)")
                    }
                }
                delay += 0.1
            }
        }
        
        scheduleTask(delay) {
            self.isTeleprompterSessionActive = false
            self.addLog("🎉 提词全套准备与 14 页正文推屏成功完成！")
        }
    }
    
    /// 推送全屏满屏提词文本 (11字/行 契合 G2 光学屏宽自然折行模式)
    func sendFullScreenTeleprompterText(_ text: String, targetWidthChars: Int = 11) {
        resetTeleprompterSession()
        sendTeleprompterText(text, targetWidthChars: targetWidthChars)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuidSuffix = String(characteristic.uuid.uuidString.suffix(4))
        if let error = error {
            addLog("❌ Tx 发送返回错误 [\(uuidSuffix)]: \(error.localizedDescription)")
        } else {
            addLog("✅ Tx 数据包被 G2 成功接收确认 (ACK) [\(uuidSuffix)]")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            addLog("❌ Rx 接收返回错误: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        processReceivedG2Data(data)
    }
    
    /// 解析并记录从 G2 眼镜收到的原始蓝牙数据帧
    private func processReceivedG2Data(_ data: Data) {
        let hexString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        addLog("📥 Rx (G2 -> iPad): [\(hexString)]")
        
        let rawByte = data.first ?? 0
        var cmdDesc = "未知数据帧"
        var isGesture = false
        
        if rawByte == 0xAA && data.count >= 4 {
            let headerType = data.count > 1 ? data[1] : 0x00
            let seq = data.count > 2 ? data[2] : 0x00
            
            if headerType == 0x12 {
                cmdDesc = "🎉 G2 固件 ACK 确认应答包 [Seq=0x\(String(format: "%02X", seq))]"
                addLog("🎉 收到 G2 固件 ACK 成功应答 [Seq=0x\(String(format: "%02X", seq))]")
            } else {
                cmdDesc = "G2 固件应答包 (Cmd=0x\(String(format: "%02X", data.count > 4 ? data[4] : 0x00)))"
                addLog("ℹ️ 解码 G2 固件帧: Header=0x\(String(format: "%02X", headerType))")
            }
        } else if rawByte == 0x01 {
            lastGestureReceived = "Swipe Down / Next"
            cmdDesc = "镜腿手势: 向下滑动 (NEXT)"
            isGesture = true
            onPageControlTriggered?("NEXT")
            addLog("👉 收到镜腿手势: 向下滑动 (NEXT)")
        } else if rawByte == 0x02 {
            lastGestureReceived = "Swipe Up / Prev"
            cmdDesc = "镜腿手势: 向上滑动 (PREV)"
            isGesture = true
            onPageControlTriggered?("PREV")
            addLog("👈 收到镜腿手势: 向上滑动 (PREV)")
        } else if rawByte == 0x03 {
            lastGestureReceived = "Ring Click / Next"
            cmdDesc = "戒指按键: 单击 (NEXT)"
            isGesture = true
            onPageControlTriggered?("NEXT")
            addLog("💍 收到戒指按键: 点击 (NEXT)")
        } else {
            cmdDesc = "G2 通知数据 [\(data.count) 字节]"
        }
        
        onG2TelemetryLog?("Rx", hexString, cmdDesc)
        
        let rxMsg = G2RxMessage(
            timestamp: Date(),
            rawHex: hexString,
            commandType: String(format: "0x%02X", rawByte),
            description: cmdDesc,
            isGesture: isGesture
        )
        
        DispatchQueue.main.async {
            self.rxCount += 1
            self.g2RxMessages.insert(rxMsg, at: 0)
            if self.g2RxMessages.count > 50 {
                self.g2RxMessages.removeLast()
            }
        }
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
        let packet = G2ProtocolEncoder.buildSleepPacket()
        sendRawData(packet, channel: .content)
        DispatchQueue.main.async {
            self.lastBLEStatusMessage = "⚪ 已下发屏幕休眠指令 (0x0420 Sleep -> 5401)"
        }
    }
    
    func wakeHUD() {
        guard isConnected else { return }
        let packet = G2ProtocolEncoder.buildWakePacket()
        sendRawData(packet, channel: .content)
        
        DispatchQueue.main.async {
            self.lastBLEStatusMessage = "🟢 已下发屏幕唤醒指令 (0x0420 Wake -> 5401)"
        }
    }
    
    func enterTeleprompterMode() {
        guard isConnected else { return }
        let configPacket = G2ProtocolEncoder.buildDisplayConfig(seq: 0x08, msgId: 0x14)
        sendRawData(configPacket, channel: .content)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let modeEnterPacket = G2ProtocolEncoder.buildEnterTeleprompterModePacket(seq: 0x09, msgId: 0x15)
            self.sendRawData(modeEnterPacket, channel: .content)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let scrollModePacket = G2ProtocolEncoder.buildTeleprompterModeConfigPacket(seq: 0x0A, mode: 0x00)
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
        if characteristic.properties.contains(.writeWithoutResponse) {
            return .withoutResponse
        } else if characteristic.properties.contains(.write) {
            return .withResponse
        } else {
            return .withoutResponse
        }
    }

    private func sendRawData(_ data: Data, channel: G2Channel = .teleprompter, logDesc: String? = nil) {
        guard isConnected else {
            addLog("⚠️ 发送失败: 蓝牙未连接")
            return
        }
        guard let peripheral = targetPeripheral else { return }
        
        let targetChar: CBCharacteristic?
        switch channel {
        case .control:
            targetChar = contentTxChar ?? controlTxChar
        case .content:
            targetChar = contentTxChar ?? controlTxChar
        case .rendering:
            targetChar = renderingTxChar ?? contentTxChar ?? controlTxChar
        case .teleprompter:
            targetChar = contentTxChar ?? controlTxChar
        }
        
        guard let txChar = targetChar else {
            addLog("⚠️ 发送失败: 无法找到通道 [\(channel)] 对应的 TX 特征值")
            return
        }
        
        let writeType = getWriteType(for: txChar)
        peripheral.writeValue(data, for: txChar, type: writeType)
        
        let hexString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        let uuidSuffix = String(txChar.uuid.uuidString.suffix(4))
        
        if let logDesc = logDesc {
            addLog("📤 下发 \(logDesc) -> [\(uuidSuffix)]")
        }
        onG2TelemetryLog?("Tx", hexString, logDesc ?? "下发 G2 帧 [\(uuidSuffix)]")
    }
    
    func commitRender() {
        // 已合并进 8 步推屏序列
    }
    
    /// 向 Even G2 发送 3 行 HUD 显存刷新数据帧 (调用 100% 官方推屏引擎)
    func sendHUDFrame(chunk: HUDDisplayChunk, channel: G2Channel = .content) {
        guard isConnected, isHUDDisplayActive else { return }
        let fullText = "\(chunk.headerText)\n\(chunk.highlightedLine)\n\(chunk.nextLinePreview)"
        sendTeleprompterText(fullText)
    }
}

