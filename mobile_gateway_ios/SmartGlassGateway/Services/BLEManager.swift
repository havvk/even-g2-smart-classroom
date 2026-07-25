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
    
    func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        isManualDisconnect = false
        hasHandshakeExecuted = false
        isScanning = true
        lastBLEStatusMessage = "正在扫描附近的 Even G2 眼镜..."
        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
    
    func stopScanning() {
        isScanning = false
        centralManager.stopScan()
    }
    
    func disconnect() {
        isManualDisconnect = true
        hasHandshakeExecuted = false
        if let peripheral = targetPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        isConnected = false
        connectedPeripheralName = nil
        controlTxChar = nil
        contentTxChar = nil
        renderingTxChar = nil
        teleprompterTxChar = nil
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
            targetPeripheral = peripheral
            targetPeripheral?.delegate = self
            stopScanning()
            centralManager.connect(peripheral, options: nil)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        hasHandshakeExecuted = false
        connectedPeripheralName = peripheral.name ?? "Even G2 Smart Glass"
        lastBLEStatusMessage = "🟢 蓝牙已连接设备: \(connectedPeripheralName ?? "")"
        peripheral.discoverServices(nil)
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        hasHandshakeExecuted = false
        isTeleprompterSessionActive = false
        connectedPeripheralName = nil
        controlTxChar = nil
        contentTxChar = nil
        renderingTxChar = nil
        teleprompterTxChar = nil
        if !isManualDisconnect {
            startScanning()
        } else {
            lastBLEStatusMessage = "已断开蓝牙，点击按钮可重新扫描"
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
    
    /// 推送全屏提词文本 (支持 10..28 汉字可变显示区域宽度调节)
    func sendTeleprompterText(_ rawText: String, targetWidthChars: Int = 11) {
        guard isConnected else {
            addLog("⚠️ 发送提词失败: 蓝牙未连接")
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
        
        // 1. 动态排版格式化 (单页 9 行全屏，幅宽 10..28 汉字)
        let linesPerPage = 9
        let (pages, wrappedLines, _) = G2ProtocolEncoder.formatTextToPages(rawText, targetWidthChars: targetWidthChars, linesPerPage: linesPerPage)
        self.currentWrappedLines = wrappedLines
        
        let totalLines = max(140, pages.count * linesPerPage)
        addLog("📜 准备推屏: 文本切分为 \(pages.count) 页 (\(linesPerPage)行/页, 幅宽\(targetWidthChars)字), 画布总行数 \(totalLines) 行")
        
        var delay: Double = 0.0
        
        let scheduleTask = { (delayInSeconds: Double, action: @escaping () -> Void) in
            let item = DispatchWorkItem {
                action()
            }
            self.teleprompterWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delayInSeconds, execute: item)
        }
        
        // 1. Send auth sequence (7 packets: seq 0x01..0x07) (100% 独占自包含 Session 鉴权)
        let authPackets = G2ProtocolEncoder.buildAuthPackets()
        for packet in authPackets {
            let authDelay = delay
            let pkt = packet
            scheduleTask(authDelay) {
                self.sendRawData(pkt, channel: .control)
            }
            delay += 0.08
        }
        delay += 0.15 // Auth 完成后 0.15 秒沉淀等待
        
        var seq: UInt8 = 0x08
        var msgId: Int = 0x14
        
        // 1. Enter Teleprompter Foreground App Mode (seq=8, Service 0x06-20) - 强制指令 G2 Window Manager 切换前台 UI 到提词器 App
        let enterModePacket = G2ProtocolEncoder.buildEnterTeleprompterModePacket(seq: seq, msgId: msgId)
        seq &+= 1; msgId += 1
        scheduleTask(delay) {
            self.sendRawData(enterModePacket, channel: .teleprompter)
        }
        delay += 0.2
        
        // 2. Display Wake (seq=9, msg_id=20) - 物理点亮 G2 MicroLED 显示引擎总线供电
        let wakePacket = G2ProtocolEncoder.buildWakePacket(seq: seq, msgId: msgId)
        seq &+= 1; msgId += 1
        scheduleTask(delay) {
            self.sendRawData(wakePacket, channel: .teleprompter)
        }
        delay += 0.2
        
        // 2. Display Config (seq=9, msg_id=21) - 动态计算 Region 2 视口 32 位浮点宽度
        let configPacket = G2ProtocolEncoder.buildDisplayConfig(seq: seq, msgId: msgId, targetWidthChars: targetWidthChars)
        seq &+= 1; msgId += 1
        scheduleTask(delay) {
            self.sendRawData(configPacket, channel: .teleprompter)
        }
        delay += 0.3
        
        // 3. Teleprompter Init (seq=10, msg_id=22) - 动态计算 10..28 汉字对应物理画布视口宽度 (TargetWidth * 23px)
        let initPacket = G2ProtocolEncoder.buildTeleprompterInit(seq: seq, msgId: msgId, totalLines: totalLines, manualMode: true, targetWidthChars: targetWidthChars)
        seq &+= 1; msgId += 1
        scheduleTask(delay) {
            self.sendRawData(initPacket, channel: .teleprompter)
        }
        delay += 0.3
        
        // 4. Teleprompter List (seq=11, msg_id=23) - 下发官方 Type 2 讲稿元数据，在 G2 显存建立全量滚动画卷
        let listPacket = G2ProtocolEncoder.buildTeleprompterList(seq: seq, msgId: msgId)
        seq &+= 1; msgId += 1
        scheduleTask(delay) {
            self.sendRawData(listPacket, channel: .teleprompter)
        }
        delay += 0.4
        
        // 5. Send content pages 0..13 (发送补满的 14 页全量正文)
        for i in 0..<pages.count {
            let pageMsg = msgId
            let pageText = pages[i]
            let packets = G2ProtocolEncoder.buildContentPagePackets(seq: &seq, msgId: pageMsg, pageNum: i, text: pageText, lineCount: linesPerPage)
            msgId += 1
            for pkt in packets {
                let currentPkt = pkt
                scheduleTask(delay) {
                    self.sendRawData(currentPkt, channel: .teleprompter)
                }
                delay += 0.08
            }
        }
        
        // 6. 下发官方 Type 4 (TeleprompterComplete) Commit 渲染提交指令 (强制下发 >=14 页与 >=140 行)
        let completeSeq = seq
        let completeMsg = msgId
        let totalPages = max(14, pages.count)
        let commitTotalLines = max(140, totalPages * linesPerPage)
        let completePacket = G2ProtocolEncoder.buildTeleprompterComplete(
            seq: completeSeq,
            msgId: completeMsg,
            startPage: 0,
            totalPages: totalPages,
            totalLines: commitTotalLines
        )
        seq &+= 1; msgId += 1
        scheduleTask(delay) {
            self.sendRawData(completePacket, channel: .teleprompter)
        }
        delay += 0.15
        
        // 7. 下发官方 ScrollSync 渲染归位指令 (ProtoTeleprompterExt|sendTeleprompterScrollSyncEvent pageLine=0)，触发 GPU 将第0页绘制入显存视口！
        let syncSeq = seq
        let syncMsg = msgId
        let syncPacket = G2ProtocolEncoder.buildScrollSync(seq: syncSeq, msgId: syncMsg, pageLine: 0)
        seq &+= 1; msgId += 1
        scheduleTask(delay) {
            self.sendRawData(syncPacket, channel: .teleprompter)
        }
        delay += 0.1
        
        // 8. 下发 Step 10 官方 GPU VSYNC 物理刷屏同步脉冲 (Service 0x80-00 type=14 Sync Trigger)
        let gpuSyncSeq = seq
        let gpuSyncMsg = msgId
        let gpuSyncPacket = G2ProtocolEncoder.buildSync(seq: gpuSyncSeq, msgId: gpuSyncMsg)
        seq &+= 1; msgId += 1
        scheduleTask(delay) {
            self.sendRawData(gpuSyncPacket, channel: .rendering)
        }
        delay += 0.1
        
        scheduleTask(delay) {
            self.isTeleprompterSessionActive = false
            self.addLog("✅ 100% 官方标准推屏发包完成 (\(pages.count)页)")
        }
    }
    
    /// 推送全屏满屏提词文本 (10行/页 28字/行 满屏全宽滚动模式)
    func sendFullScreenTeleprompterText(_ text: String, targetWidthChars: Int = 28) {
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

    private func sendRawData(_ data: Data, channel: G2Channel = .teleprompter) {
        guard isConnected else {
            addLog("⚠️ 发送失败: 蓝牙未连接")
            return
        }
        guard let peripheral = targetPeripheral else { return }
        
        let targetChar: CBCharacteristic?
        switch channel {
        case .control:
            // 鉴权与 Session 时间同步必须由 5401 通道承载并获取固件 ACK
            targetChar = contentTxChar ?? controlTxChar
        case .content:
            targetChar = contentTxChar ?? teleprompterTxChar ?? controlTxChar
        case .rendering:
            targetChar = renderingTxChar ?? teleprompterTxChar ?? contentTxChar
        case .teleprompter:
            targetChar = teleprompterTxChar ?? contentTxChar ?? controlTxChar
        }
        
        guard let txChar = targetChar else {
            addLog("⚠️ 发送失败: 无法找到通道 [\(channel)] 对应的 TX 特征值")
            return
        }
        
        let writeType = getWriteType(for: txChar)
        peripheral.writeValue(data, for: txChar, type: writeType)
        
        let hexString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        let typeStr = writeType == .withResponse ? "withResponse" : "withoutResponse"
        let uuidSuffix = String(txChar.uuid.uuidString.suffix(4))
        addLog("📤 Tx -> [\(uuidSuffix)] [\(typeStr)]: [\(hexString)]")
        onG2TelemetryLog?("Tx", hexString, "下发 G2 帧 [\(uuidSuffix)] [\(typeStr)]")
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

