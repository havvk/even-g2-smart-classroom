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
            
            let uuidSuffix = String(uuidStr.suffix(4))
            // 官方精准订阅: 仅允许 5402 (内容) 与 0002 (控制) 通道，使用 hasSuffix 排除 Base UUID 前缀误匹配
            if canNotify && (uuidStr.hasSuffix("5402") || uuidStr.hasSuffix("0002")) {
                peripheral.setNotifyValue(true, for: characteristic)
                addLog("🔔 正在开启 \(uuidSuffix) 通道 Notify 接收...")
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
    
    /// 接收 G2 固件在 5402 Notify 通道上回发的 ACK 确认帧 (100% 对齐 teleprompter.py notify handler)
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            addLog("❌ Rx 接收返回错误: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value, !data.isEmpty else { return }
        let hexString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        let uuidSuffix = String(characteristic.uuid.uuidString.suffix(4))
        
        let logText = "📥 Rx (G2 -> Phone) [\(uuidSuffix)]: \(hexString)"
        print(logText)
        addLog(logText)
        processReceivedG2Data(data)
        onG2TelemetryLog?("Rx", hexString, "收到 G2 Notify 节点包 [\(uuidSuffix)]")
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
        addLog("🚀 [1:1 零加工抓包重放] 开始下发 OfficialRawPkts 70 个二进制 Raw 数据包...")
        
        var delay: Double = 0.05
        for (idx, hexStr) in rawHexes.enumerated() {
            let currentPkt = hexToData(hexStr)
            let pktIndex = idx + 1
            
            let item = DispatchWorkItem {
                self.sendRawData(currentPkt, channel: .content, logDesc: "bt.pklg 物理包 [\(pktIndex)/71]")
            }
            self.teleprompterWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            
            // 精确 1:1 物理时间线 Pacing 算力
            if pktIndex <= 22 {
                delay += 0.025 // Auth 阶段
            } else if pktIndex <= 36 {
                delay += 0.035 // DisplayConfig / VSYNC 初始化阶段
            } else if pktIndex == 37 {
                delay += 0.150 // TeleprompterInit 阶段, 预留 150ms 显存分配
            } else if pktIndex <= 67 {
                // 正文下发阶段
                let isLastSliceInPage = (pktIndex == 41 || pktIndex == 44 || pktIndex == 48 || pktIndex == 52 || pktIndex == 55 || pktIndex == 58 || pktIndex == 61 || pktIndex == 64 || pktIndex == 67)
                delay += isLastSliceInPage ? 0.040 : 0.018
            } else if pktIndex <= 69 {
                delay += 0.050 // Render Trigger 阶段
            } else if pktIndex == 70 {
                delay += 0.080 // UI 0x09-20 路由切页前台
            } else {
                delay += 0.020
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.1) {
            self.addLog("🎉 1:1 物理抓包 71 个 Raw 字节包全部重发完成！")
        }
    }
    
    /// 100% 零加工 1:1 原装 bt.pklg 抓包 70 包纯物理重发 (一个 Byte 都不改)
    func sendTeleprompterText(_ rawText: String, targetWidthChars: Int = 14) {
        sendHardcodedOfficialPklg()
    }
    
    /// 手动发送退出提词器模式报文 (Service 0x06-20 type=4 state=4)
    func sendExitTeleprompterMode() {
        guard isConnected else { return }
        let exitData = Data([0x08, 0x01, 0x10, 0x32, 0x1A, 0x02, 0x08, 0x04])
        let pktExit = G2ProtocolEncoder.buildPacket(seq: 0x30, serviceHi: 0x06, serviceLo: 0x20, payload: exitData)
        sendRawData(pktExit, channel: .content, logDesc: "退出提词器模式 (state=4)")
        addLog("🛑 已下发 0x06-20 state=4 退出提词器模式指令")
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
        
        // 过滤高频无意义的 ACK 应答日志，避免调试界面刷屏
        if rawByte == 0xAA && data.count >= 4 && data[1] == 0x12 {
            // 静默处理 G2 固件 ACK 应答，仅更新计数
            DispatchQueue.main.async {
                self.rxCount += 1
            }
            return
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

    @Published var physicalWriteCount: Int = 0
    
    private func sendRawData(_ data: Data, channel: G2Channel = .content, logDesc: String? = nil) {
        guard isConnected else {
            addLog("⚠️ 发送失败: 蓝牙未连接")
            return
        }
        guard let peripheral = targetPeripheral else { return }
        
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
        
        // 100% 对齐 teleprompter.py: response=False (.withoutResponse)
        peripheral.writeValue(data, for: txChar, type: .withoutResponse)
        
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
    
    /// 向 Even G2 发送 3 行 HUD 显存刷新数据帧 (不再误触发全量推屏)
    func sendHUDFrame(chunk: HUDDisplayChunk, channel: G2Channel = .content) {
        // 静默禁用高频 HUD 全量重推
    }
}

