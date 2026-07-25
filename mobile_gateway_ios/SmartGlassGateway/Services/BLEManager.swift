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
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    private var isManualDisconnect = false
    private var hasHandshakeExecuted = false
    
    func addLog(_ message: String) {
        DispatchQueue.main.async {
            self.bleLogHistory.append(message)
            if self.bleLogHistory.count > 100 {
                self.bleLogHistory.removeFirst()
            }
        }
        onG2TelemetryLog?("Log", "", message)
    }
    
    func clearLogs() {
        DispatchQueue.main.async {
            self.bleLogHistory.removeAll()
            self.g2RxMessages.removeAll()
            self.rxCount = 0
        }
    }
    
    // MARK: - 双耳双 BLE 外设管理结构
    @Published var connectedPeripherals: [CBPeripheral] = []
    private var controlTxChars: [ObjectIdentifier: CBCharacteristic] = [:]
    private var contentTxChars: [ObjectIdentifier: CBCharacteristic] = [:]
    private var renderingTxChars: [ObjectIdentifier: CBCharacteristic] = [:]
    private var teleprompterTxChars: [ObjectIdentifier: CBCharacteristic] = [:]
    
    func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        isManualDisconnect = false
        hasHandshakeExecuted = false
        isScanning = true
        lastBLEStatusMessage = "正在扫描附近的 Even G2 左右双耳眼镜..."
        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        
        // 扫描 5 秒确保搜齐左右双耳 (_L_ 和 _R_) 避免只连单侧
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self, self.isScanning else { return }
            if !self.connectedPeripherals.isEmpty {
                self.stopScanning()
            }
        }
    }
    
    func stopScanning() {
        isScanning = false
        centralManager.stopScan()
    }
    
    func disconnect() {
        isManualDisconnect = true
        hasHandshakeExecuted = false
        for peripheral in connectedPeripherals {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        connectedPeripherals.removeAll()
        controlTxChars.removeAll()
        contentTxChars.removeAll()
        renderingTxChars.removeAll()
        teleprompterTxChars.removeAll()
        
        isConnected = false
        connectedPeripheralName = nil
        lastBLEStatusMessage = "已手动断开蓝牙"
    }
    
    // MARK: - CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            if !isManualDisconnect {
                startScanning()
            }
        } else {
            isConnected = false
            isScanning = false
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        if name.contains("Even G2") || name.contains("Smart Ring") || name.contains("Even") {
            if !connectedPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
                addLog("🔎 搜到 G2 外设: \(name) [RSSI: \(RSSI)]，发起双侧连入...")
                peripheral.delegate = self
                connectedPeripherals.append(peripheral)
                centralManager.connect(peripheral, options: nil)
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        hasHandshakeExecuted = false
        let name = peripheral.name ?? "Even G2 Smart Glass"
        connectedPeripheralName = connectedPeripherals.map { $0.name ?? "G2" }.joined(separator: " + ")
        lastBLEStatusMessage = "🟢 已连入双耳设备: \(connectedPeripheralName ?? "")"
        addLog("🤝 成功连接物理镜腿外设: \(name)")
        peripheral.discoverServices(nil)
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        connectedPeripherals.removeAll(where: { $0.identifier == id })
        let key = ObjectIdentifier(peripheral)
        controlTxChars.removeValue(forKey: key)
        contentTxChars.removeValue(forKey: key)
        renderingTxChars.removeValue(forKey: key)
        teleprompterTxChars.removeValue(forKey: key)
        
        if connectedPeripherals.isEmpty {
            isConnected = false
            hasHandshakeExecuted = false
            isTeleprompterSessionActive = false
            connectedPeripheralName = nil
            if !isManualDisconnect {
                startScanning()
            } else {
                lastBLEStatusMessage = "已断开蓝牙，点击按钮可重新扫描"
            }
        } else {
            connectedPeripheralName = connectedPeripherals.map { $0.name ?? "G2" }.joined(separator: " + ")
            lastBLEStatusMessage = "🟢 维护单侧/双侧通道: \(connectedPeripheralName ?? "")"
        }
    }
    
    // MARK: - CBPeripheralDelegate
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            addLog("❌ 发现服务异常 (\(peripheral.name ?? "")): \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else { return }
        for service in services {
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
            
            // 严格对齐 teleprompter.py: 只为 5402 通道开启 Notify 接收应答 ACK
            if canNotify && uuidStr.contains("5402") {
                peripheral.setNotifyValue(true, for: characteristic)
                addLog("🔔 已开启 5402 专属 Notify 接收通道: \(uuidStr)")
            }
            
            if canWrite {
                if uuidStr.contains("0001") {
                    controlTxChar = characteristic
                } else if uuidStr.contains("5401") {
                    contentTxChar = characteristic
                    addLog("✍️ 绑定 [5401 提词核心写特征]: \(uuidStr)")
                } else if uuidStr.contains("6401") {
                    renderingTxChar = characteristic
                } else if uuidStr.contains("7401") {
                    teleprompterTxChar = characteristic
                }
            }
        }
        if contentTxChar != nil {
            addLog("✍️ G2 [5401 提词核心通道] 绑定完成，物理传输准备就绪！")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let uuidStr = characteristic.uuid.uuidString.uppercased()
        if let error = error {
            addLog("❌ Notify 通道订阅失败 (\(uuidStr)): \(error.localizedDescription)")
        } else {
            addLog("✅ Notify 通道订阅成功 (\(uuidStr)), isNotifying=\(characteristic.isNotifying)")
        }
    }
    
    // MARK: - 官方 FIFO 串行发包队列机制 (100% 对齐 Python 100ms 时间戳)
    struct BLECommand {
        let data: Data
        let channel: G2Channel
        let description: String
    }
    
    private var commandQueue: [BLECommand] = []
    private var isProcessingQueue: Bool = false
    
    /// 将待下发的物理报文压入 FIFO 串行队列
    private func enqueueCommand(_ command: BLECommand) {
        commandQueue.append(command)
        processNextQueueCommand()
    }
    
    /// 串行处理队列中的下一条指令（1:1 匹配 Python asyncio.sleep(0.1) 100ms 间隔锁）
    private func processNextQueueCommand() {
        guard !isProcessingQueue, !commandQueue.isEmpty else { return }
        isProcessingQueue = true
        
        let command = commandQueue.removeFirst()
        sendRawData(command.data, channel: command.channel)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.isProcessingQueue = false
            self?.processNextQueueCommand()
        }
    }
    
    /// 撤销所有队列中未下发的物理报文
    private func cancelPendingTeleprompterTasks() {
        commandQueue.removeAll()
        isProcessingQueue = false
        teleprompterWorkItems.forEach { $0.cancel() }
        teleprompterWorkItems.removeAll()
    }
    
    /// 重置提词器会话状态并清空历史文本防抖
    func resetTeleprompterSession() {
        cancelPendingTeleprompterTasks()
        lastSentTeleprompterText = ""
        isTeleprompterSessionActive = false
    }
    
    private var isTeleprompterSessionActive: Bool = false
    private var teleprompterWorkItems: [DispatchWorkItem] = []
    @Published var lastSentTeleprompterText: String = ""
    
    /// 实时当前滚动的焦点行号回调 (用于 9 行所见即所得 View 高亮卡片)
    @Published var currentFocusPageLine: Int = 0
    @Published var currentWrappedLines: [String] = []
    
    /// 发送双向滚动同步报文 (App 向 Glasses 下发焦点行号)
    func sendScrollSync(pageLine: Int) {
        guard isConnected else { return }
        self.currentFocusPageLine = pageLine
        var seq: UInt8 = 0xFE
        let packet = G2ProtocolEncoder.buildScrollSync(seq: seq, msgId: 0x99, pageLine: pageLine)
        enqueueCommand(BLECommand(data: packet, channel: .content, description: "ScrollSync Line \(pageLine)"))
    }
    
    /// 完整推送提词文本到 G2 智能眼镜 (1:1 匹配验证成功的 Python teleprompter.py 发包全流程)
    func sendTeleprompterText(_ text: String, force: Bool = false) {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return }
        
        cancelPendingTeleprompterTasks()
        lastSentTeleprompterText = cleanText
        isTeleprompterSessionActive = true
        
        let (pages, totalLines) = G2ProtocolEncoder.formatTextToPages(cleanText, charsPerLine: 25, linesPerPage: 10)
        
        addLog("📜 准备推屏: 文本切分为 \(pages.count) 页, 画布总行数 \(totalLines) 行")
        
        // 1. Auth 序列 (7 帧: 压入串行队列至 5401 通道)
        let authPackets = G2ProtocolEncoder.buildAuthPackets()
        for (idx, pkt) in authPackets.enumerated() {
            enqueueCommand(BLECommand(data: pkt, channel: .content, description: "Auth Handshake Packet \(idx+1)"))
        }
        
        var seq: UInt8 = 0x08
        var msgId: Int = 0x14
        
        // 2. DisplayConfig (0x0E-20)
        let configPacket = G2ProtocolEncoder.buildDisplayConfig(seq: seq, msgId: msgId)
        enqueueCommand(BLECommand(data: configPacket, channel: .content, description: "DisplayConfig"))
        seq &+= 1; msgId += 1
        
        // 3. TeleprompterInit (0x06-20 type=1)
        let initPacket = G2ProtocolEncoder.buildTeleprompterInit(seq: seq, msgId: msgId, totalLines: totalLines, manualMode: true)
        enqueueCommand(BLECommand(data: initPacket, channel: .content, description: "TeleprompterInit"))
        seq &+= 1; msgId += 1
        
        // 4. 正文 0-9 页推屏
        let firstBatchCount = min(10, pages.count)
        for i in 0..<firstBatchCount {
            let pkt = G2ProtocolEncoder.buildContentPage(seq: seq, msgId: msgId, pageNum: i, text: pages[i])
            enqueueCommand(BLECommand(data: pkt, channel: .content, description: "Content Page \(i)"))
            seq &+= 1; msgId += 1
        }
        
        // 5. Type 255 Mid-Stream Marker 流控标记帧
        let markerPacket = G2ProtocolEncoder.buildMarker(seq: seq, msgId: msgId)
        enqueueCommand(BLECommand(data: markerPacket, channel: .content, description: "Mid-Stream Marker"))
        seq &+= 1; msgId += 1
        
        // 6. 正文 10-11 页推屏
        if pages.count > 10 {
            let secondBatchCount = min(12, pages.count)
            for i in 10..<secondBatchCount {
                let pkt = G2ProtocolEncoder.buildContentPage(seq: seq, msgId: msgId, pageNum: i, text: pages[i])
                enqueueCommand(BLECommand(data: pkt, channel: .content, description: "Content Page \(i)"))
                seq &+= 1; msgId += 1
            }
        }
        
        // 7. GPU VSYNC Sync Trigger (0x80-00 type=14 on 5401)
        let syncPacket = G2ProtocolEncoder.buildSync(seq: seq, msgId: msgId)
        enqueueCommand(BLECommand(data: syncPacket, channel: .content, description: "GPU VSYNC Sync Trigger"))
        seq &+= 1; msgId += 1
        
        // 8. 剩余 12..13 页推屏
        if pages.count > 12 {
            for i in 12..<pages.count {
                let pkt = G2ProtocolEncoder.buildContentPage(seq: seq, msgId: msgId, pageNum: i, text: pages[i])
                enqueueCommand(BLECommand(data: pkt, channel: .content, description: "Content Page \(i)"))
                seq &+= 1; msgId += 1
            }
        }
    }
    
    /// 推送全屏满屏提词文本 (10行/页 28字/行 满屏全宽滚动模式)
    func sendFullScreenTeleprompterText(_ text: String) {
        resetTeleprompterSession()
        sendTeleprompterText(text, force: true)
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

    private func sendRawData(_ data: Data, channel: G2Channel = .teleprompter) {
        guard isConnected, !connectedPeripherals.isEmpty else {
            addLog("⚠️ 发送失败: 蓝牙双侧外设均未连接")
            return
        }
        
        let hexString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        var sentCount = 0
        
        for peripheral in connectedPeripherals {
            let pKey = ObjectIdentifier(peripheral)
            let targetChar: CBCharacteristic?
            switch channel {
            case .control:
                targetChar = contentTxChars[pKey] ?? controlTxChars[pKey]
            case .content:
                targetChar = contentTxChars[pKey] ?? teleprompterTxChars[pKey] ?? controlTxChars[pKey]
            case .rendering:
                targetChar = renderingTxChars[pKey] ?? teleprompterTxChars[pKey] ?? contentTxChars[pKey]
            case .teleprompter:
                targetChar = contentTxChars[pKey] ?? teleprompterTxChars[pKey] ?? controlTxChars[pKey]
            }
            
            if let txChar = targetChar {
                let writeType = getWriteType(for: txChar)
                peripheral.writeValue(data, for: txChar, type: writeType)
                sentCount += 1
            }
        }
        
        guard sentCount > 0 else {
            addLog("⚠️ 发送失败: 无法在连入通道中获取目标物理 TX 特征值")
            return
        }
        
        addLog("📤 Tx (\(sentCount)耳) -> [\(channel)]: [\(hexString)]")
        onG2TelemetryLog?("Tx", hexString, "下发 G2 帧 (\(sentCount)耳) [\(channel)]")
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

