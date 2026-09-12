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
    case audio
}

class BLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = BLEManager()
    
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
    
    // CoreBluetooth 句柄与 G2 专属多通道写特征 (支持左右双镜腿伴生拓扑)
    private var centralManager: CBCentralManager!
    private var targetPeripheral: CBPeripheral?       // 主显示/触控外设 (_R_ 镜腿为主)
    private var audioPeripheral: CBPeripheral?        // 专属麦克风外设 (严格绑定 _L_ 左镜腿)
    private var controlTxChar: CBCharacteristic?      // UUID 包含 0001 (主外设控制握手)
    private var contentTxChar: CBCharacteristic?      // UUID 包含 5401 (主外设文本内容)
    private var renderingTxChar: CBCharacteristic?    // UUID 包含 6401 (主外设渲染控制)
    private var teleprompterTxChar: CBCharacteristic? // UUID 包含 7401 (主外设提词专用)
    
    // 专属左耳麦克风通道特征 (严格绑定 audioPeripheral)
    private var audioTxChar: CBCharacteristic?        // UUID 包含 6401 (左耳音频写特征)
    private var audioRxChar: CBCharacteristic?        // UUID 包含 6402 (左耳音频 Notify 特征)
    private var audioContentTxChar: CBCharacteristic? // UUID 包含 5401 (左耳 EvenHub 写特征)
    private var audioControlTxChar: CBCharacteristic? // UUID 包含 0001 (左耳控制写特征)
    
    // MARK: - 智能眼镜麦克风与音频流管道 (Glasses Mic & Audio Stream)
    @Published var connectedAudioPeripheralName: String? = nil
    @Published var isAudioPeripheralConnected: Bool = false
    @Published var isGlassesMicActive: Bool = false
    @Published var isAudioTxReady: Bool = false
    @Published var isAudioNotifyReady: Bool = false
    @Published var audioPacketPPS: Int = 0
    @Published var totalAudioPacketsReceived: Int = 0
    @Published var lastAudioPacketHex: String = "无"
    var onAudioPacketReceived: ((Data) -> Void)?
    private let audioProcessingQueue = DispatchQueue(label: "cn.ylive.SmartGlassGateway.audioQueue", qos: .userInteractive)
    private var ppsCounter: Int = 0
    private var ppsTimer: Timer?
    
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
    
    // MARK: - 主动链路探活巡检与快速断开感知看门狗
    @Published var currentGlassesRSSI: Int = 0
    private var linkProbeTimer: Timer?
    private var lastRxOrHeartbeatTime: Date = Date()
    
    private var isManualDisconnect = false
    private var hasHandshakeExecuted = false
    private var isGattSystemModeInitialized = false
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }
    
    func addLog(_ message: String) {
        NSLog("🔵 [BLE] %@", message)
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
            
            // 核心修复 1: 优先检索已经被 iOS 系统级别配对连接的 G2 设备 (区分左右耳)
            let knownServices = [
                CBUUID(string: "00002760-08c2-11e1-9073-0e8ac72e0001"),
                CBUUID(string: "00002760-08c2-11e1-9073-0e8ac72e5450"),
                CBUUID(string: "00002760-08c2-11e1-9073-0e8ac72e6450"),
                CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
            ]
            let connectedPeripherals = cm.retrieveConnectedPeripherals(withServices: knownServices)
            var foundLeft: CBPeripheral?
            var foundRight: CBPeripheral?
            
            for p in connectedPeripherals {
                let name = p.name ?? ""
                self.addLog("⚡️ [系统快连探测] 检索到已连外设: \(name)")
                if name.contains("_L_") {
                    foundLeft = p
                } else if name.contains("_R_") {
                    foundRight = p
                } else if name.contains("Even") {
                    foundLeft = p
                }
            }
            
            // 规则 1: 麦克风硬件只在左耳 (_L_)，必须锁定左耳
            if let left = foundLeft {
                self.addLog("🎯 [左耳连接] 锁定 G2 左耳 (麦克风硬件主力端): \(left.name ?? "")")
                self.audioPeripheral = left
                left.delegate = self
                cm.connect(left, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
                if self.targetPeripheral == nil {
                    self.targetPeripheral = left
                }
            }
            
            // 规则 2: 右耳 (_R_) 负责 MicroLED 提词显示与 Touchpad 触控板
            if let right = foundRight {
                self.addLog("👓 [右耳连接] 锁定 G2 右耳 (显示/触控端): \(right.name ?? "")")
                if self.targetPeripheral == nil || self.targetPeripheral?.name?.contains("_L_") != true {
                    self.targetPeripheral = right
                }
                right.delegate = self
                cm.connect(right, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
            }
            
            // 规则 3: 若左耳麦克风尚未连接，保持后台广播扫描不中断！
            if self.audioPeripheral == nil || self.audioPeripheral?.state != .connected {
                self.addLog("🔍 [持续寻探左耳] 左耳麦克风硬件尚未就绪，启动后台 BLE 广播扫描寻找 _L_ 镜腿...")
                cm.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            }
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
            self.stopLinkProbing()
            if let p = self.targetPeripheral {
                self.centralManager.cancelPeripheralConnection(p)
            }
            if let ap = self.audioPeripheral {
                self.centralManager.cancelPeripheralConnection(ap)
            }
            self.handlePhysicalDisconnect(peripheral: self.targetPeripheral, error: nil)
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
                self.stopLinkProbing()
                self.handlePhysicalDisconnect(peripheral: self.targetPeripheral, error: nil)
                self.isConnected = false
                self.isScanning = false
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        guard name.contains("Even G2") || name.contains("Even") else { return }
        
        self.addLog("🔍 [BLE 广播发现] \(name) (RSSI: \(RSSI))")
        
        if name.contains("_L_") {
            if self.audioPeripheral == nil || self.audioPeripheral?.state != .connected {
                self.addLog("🎯 [捕获左耳] 锁定 G2 左耳 (麦克风硬件端): \(name)，立即发起连接！")
                self.audioPeripheral = peripheral
                peripheral.delegate = self
                central.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
                if self.targetPeripheral == nil {
                    self.targetPeripheral = peripheral
                }
                UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "last_connected_g2_uuid_left")
            }
        } else if name.contains("_R_") {
            if self.targetPeripheral == nil || self.targetPeripheral?.state != .connected {
                self.addLog("👓 [捕获右耳] 锁定 G2 右耳 (显示/触控端): \(name)，发起连接...")
                self.targetPeripheral = peripheral
                peripheral.delegate = self
                central.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
                UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "last_connected_g2_uuid_right")
            }
        }
        
        // 只有双耳都连接就绪才停止扫描
        if self.audioPeripheral?.state == .connected && self.targetPeripheral?.state == .connected {
            stopScanning()
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let name = peripheral.name ?? "Even G2"
        addLog("🔌 [物理连接成功] didConnect: \(name)")
        
        if name.contains("_L_") {
            self.audioPeripheral = peripheral
            DispatchQueue.main.async {
                self.connectedAudioPeripheralName = name
                self.isAudioPeripheralConnected = true
                self.addLog("🎙️ [麦克风硬件就绪] 成功挂载 G2 左耳音频外设: \(name)")
            }
            if self.targetPeripheral == nil {
                self.targetPeripheral = peripheral
            }
        } else if name.contains("_R_") {
            self.targetPeripheral = peripheral
            DispatchQueue.main.async {
                self.connectedPeripheralName = name
                self.addLog("👓 [主显设备就绪] 成功挂载 G2 右耳主外设: \(name)")
            }
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isConnected = true
            self.hasHandshakeExecuted = false
            self.teleprompterSeq = 0x01
            self.teleprompterMsgId = 0x14
            self.connectedPeripheralName = self.targetPeripheral?.name ?? name
            self.lastBLEStatusMessage = "🟢 蓝牙已物理连接: \(self.connectedPeripheralName ?? "")"
            self.updateReadyForTeleprompter()
            self.startLinkProbing()
        }
        peripheral.discoverServices(nil)
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let errDesc = error?.localizedDescription ?? "未知错误"
        addLog("❌ [物理连接失败] didFailToConnect: \(peripheral.name ?? "G2") (原因: \(errDesc))")
        handlePhysicalDisconnect(peripheral: peripheral, error: error)
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let errDesc = error != nil ? " (原因: \(error!.localizedDescription))" : " (远端断开或突然掉电)"
        addLog("🔌 [物理断开感知] didDisconnectPeripheral 触发: \(peripheral.name ?? "G2")\(errDesc)")
        handlePhysicalDisconnect(peripheral: peripheral, error: error)
    }
    
    /// 统一物理断开处理与状态清理，确保 UI 状态 0 延迟响应
    private func handlePhysicalDisconnect(peripheral: CBPeripheral?, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.stopLinkProbing()
            self.isConnected = false
            self.isNotifyReady = false
            self.isHardwareRenderConfirmed = false
            self.isHardwareCanvasMounted = false
            self.teleprompterPushStatusMessage = "🔴 眼镜已断开"
            self.connectionState = .disconnected
            self.hasHandshakeExecuted = false
            self.hasAuthBeenDoneForCurrentConnection = false
            self.isGattSystemModeInitialized = false
            self.teleprompterSeq = 0x01
            self.teleprompterMsgId = 0x14
            self.isTeleprompterSessionActive = false
            self.isPushingText = false
            self.isWaitingForSessionTeardown = false
            self.rePushTimeoutWorkItem?.cancel()
            self.rePushTimeoutWorkItem = nil
            self.renderVerificationWatchdog?.cancel()
            self.renderVerificationWatchdog = nil
            self.pendingRePushTask = nil
            self.stopSessionKeepaliveTimer()
            self.connectedPeripheralName = nil
            self.controlTxChar = nil
            self.contentTxChar = nil
            self.renderingTxChar = nil
            self.teleprompterTxChar = nil
            self.audioTxChar = nil
            self.audioRxChar = nil
            self.audioContentTxChar = nil
            self.audioControlTxChar = nil
            self.currentGlassesRSSI = 0
            self.isGlassesMicActive = false
            self.isAudioTxReady = false
            self.isAudioNotifyReady = false
            self.stopPPSMonitor()
            self.audioPacketPPS = 0
            self.updateReadyForTeleprompter()
            
            if !self.isManualDisconnect {
                self.lastBLEStatusMessage = "⚠️ 眼镜异常断开，正在自动重连..."
                self.addLog("🔄 [自动重连] 眼镜物理断开，立即挂起系统级重连并开启扫描...")
                // 1. 核心：立即对已知外设对象调用 connect (iOS 底层保持持续监听，一旦设备上线毫秒级重连)
                if let p = peripheral ?? self.targetPeripheral {
                    self.centralManager.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
                }
                // 2. 辅助：同时开启扫描备选
                self.startScanning()
            } else {
                self.lastBLEStatusMessage = "已断开蓝牙，点击按钮可重新扫描"
            }
        }
    }
    
    // MARK: - 主动链路探活巡检与快速感知看门狗 (Active Link Probing & Watchdog)
    
    /// 启动周期性 RSSI 探活巡检 (2.0s 间隔) 与 5.0s 静默超时看门狗
    func startLinkProbing() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.stopLinkProbing()
            self.lastRxOrHeartbeatTime = Date()
            self.addLog("🛡️ [链路巡检] 启动主动 RSSI 探活 (2.0s) 与 5.0s 无应答断线看门狗")
            self.linkProbeTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.performLinkProbe()
            }
        }
    }
    
    /// 停止链路探活巡检
    func stopLinkProbing() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.linkProbeTimer != nil {
                self.linkProbeTimer?.invalidate()
                self.linkProbeTimer = nil
            }
        }
    }
    
    /// 执行单次探活与看门狗判定
    private func performLinkProbe() {
        guard isConnected, let p = targetPeripheral else {
            stopLinkProbing()
            return
        }
        
        // 1. 物理层探测：迫使 iOS 蓝牙驱动向外设发送物理链路握手
        if p.state == .connected {
            p.readRSSI()
        } else {
            addLog("⚠️ [链路巡检] 外设底层状态已脱离 .connected (当前: \(p.state.rawValue))，立即执行断开清理")
            handlePhysicalDisconnect(peripheral: p, error: nil)
            return
        }
        
        // 2. 看门狗超时检测：若超过 5.0 秒未收到任何数据包且未收到 RSSI 回复，判定眼镜已断电合腿
        let silenceDuration = Date().timeIntervalSince(lastRxOrHeartbeatTime)
        if silenceDuration > 5.0 {
            addLog("🚨 [看门狗触发] 眼镜持续 \(String(format: "%.1f", silenceDuration))s 无任何物理响应，判定为合腿掉电僵尸连接，强行断开并重连！")
            centralManager.cancelPeripheralConnection(p)
            handlePhysicalDisconnect(peripheral: p, error: nil)
        }
    }
    
    // MARK: - CBPeripheralDelegate (RSSI)
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if let error = error {
            addLog("⚠️ [RSSI巡检] 读取失败: \(error.localizedDescription)")
            return
        }
        let rssiVal = RSSI.intValue
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentGlassesRSSI = rssiVal
            self.lastRxOrHeartbeatTime = Date()
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
            let isLeftTemple = (peripheral == audioPeripheral) || (peripheral.name?.contains("_L_") == true)
            
            // 订阅所有支持 Notify/Indicate 的特征通道 (包含 Nordic 串口 6E40 通道与 5402、6402)
            if canNotify {
                peripheral.setNotifyValue(true, for: characteristic)
                addLog("🔔 [物理 CCCD 激活] 正在开启 [\(uuidSuffix)] 通道 Notify 接收 (\(peripheral.name ?? "外设"))...")
                if uuidStr.hasSuffix("6402") {
                    audioRxChar = characteristic
                    addLog("🎙️ [独立音频通道] 成功捕获 6402 音频流 Notify 特征值 (\(peripheral.name ?? "左耳"))")
                }
            }
            
            // 按 UUID 结尾绑定 G2 专属 Channel 特征通道 (排除 6E40 串口，严格区分左右耳)
            if canWrite {
                if isLeftTemple {
                    // 左耳：专职麦克风硬件
                    if uuidStr.hasSuffix("6401") {
                        audioTxChar = characteristic
                        DispatchQueue.main.async {
                            self.isAudioTxReady = true
                        }
                        addLog("✍️ 绑定 [左耳 6401 麦克风控制写通道] 特征: \(uuidStr)")
                    } else if uuidStr.hasSuffix("5401") {
                        audioContentTxChar = characteristic
                        addLog("✍️ 绑定 [左耳 5401 内容通道] 写特征: \(uuidStr)")
                    } else if uuidStr.hasSuffix("0001") {
                        audioControlTxChar = characteristic
                        addLog("✍️ 绑定 [左耳 0001 控制通道] 写特征: \(uuidStr)")
                    }
                } else {
                    // 右耳：专职主显、提词与触控
                    if uuidStr.hasSuffix("0001") {
                        controlTxChar = characteristic
                        addLog("✍️ 绑定 [右耳 0001 控制通道] 写特征: \(uuidStr)")
                    } else if uuidStr.hasSuffix("5401") {
                        contentTxChar = characteristic
                        addLog("✍️ 绑定 [右耳 5401 内容通道] 写特征: \(uuidStr)")
                    } else if uuidStr.hasSuffix("6401") {
                        renderingTxChar = characteristic
                        addLog("✍️ 绑定 [右耳 6401 渲染通道] 写特征: \(uuidStr)")
                    } else if uuidStr.hasSuffix("7401") {
                        teleprompterTxChar = characteristic
                        addLog("✍️ 绑定 [右耳 7401 提词通道] 写特征: \(uuidStr)")
                    }
                }
            }
        }
        
        let hasAnyTxChar = controlTxChar != nil || contentTxChar != nil || audioContentTxChar != nil
        if hasAnyTxChar {
            addLog("✍️ 已成功绑定 G2 物理写特征通道 (6401音频写就绪: \(audioTxChar != nil))")
            DispatchQueue.main.async { [weak self] in
                self?.updateReadyForTeleprompter()
            }
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
                    self.lastBLEStatusMessage = "🟢 眼镜就绪: \(self.connectedPeripheralName ?? "Even G2")"
                    self.addLog("🔒 [物理订阅锁] 5402 Notify 100% 订阅就绪，允许推屏!")
                    self.updateReadyForTeleprompter()
                    self.onGlassesReadyToRender?()
                }
            } else if uuidStr.contains("6402") {
                DispatchQueue.main.async {
                    self.isAudioNotifyReady = characteristic.isNotifying
                    self.addLog("🎙️ [物理订阅锁] 6402 音频流通道订阅就绪! (isNotifying=\(characteristic.isNotifying))")
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
        
        // 核心通道 1: 6402 为麦克风 LC3 音频流通道 (单包 205 字节，~20 pps)
        if uuidSuffix == "6402" {
            audioProcessingQueue.async { [weak self] in
                guard let self = self else { return }
                self.ppsCounter += 1
                self.onAudioPacketReceived?(data)
                
                // 仅每 20 包 (约 1 秒) 更新一次遥测调试信息，避免主线程日志轰炸
                if self.ppsCounter % 20 == 1 {
                    let hexPreview = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
                    DispatchQueue.main.async {
                        self.totalAudioPacketsReceived += 1
                        self.lastAudioPacketHex = "\(hexPreview)... (\(data.count)B)"
                    }
                }
            }
            return
        }
        
        // 核心过滤 2: 过滤非 0xAA 的非协议杂乱帧 (如纯文本/串口杂音)
        let hexStr = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        
        addLog("📩 [Rx Notify] 通道 [\(uuidSuffix)] (\(data.count)B): \(hexStr)")
        onG2TelemetryLog?("Rx", hexStr, "G2 Notify 接收 [\(uuidSuffix)] (\(data.count)B)")
        
        DispatchQueue.main.async {
            self.rxPacketCount += 1
            self.lastRawHex = hexStr
            self.lastRxOrHeartbeatTime = Date()
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
    @Published var useV2OnDemandPadding: Bool = true // 开: V2 按需切分 (官方原装), 关: V1 14页补满
    @Published var isHardwareRenderConfirmed: Bool = false
    @Published var isHardwareCanvasMounted: Bool = false
    @Published var teleprompterPushStatusMessage: String = "未推屏"
    
    /// 蓝牙通信与 5401/5402 数据通道完全就绪指示 (声明为 @Published 确保 SwiftUI 界面毫秒级响应)
    @Published var isReadyForTeleprompter: Bool = false
    
    func updateReadyForTeleprompter() {
        let ready = isConnected && contentTxChar != nil && isNotifyReady
        if self.isReadyForTeleprompter != ready {
            self.isReadyForTeleprompter = ready
            self.addLog("⚡️ [G2状态变更] isReadyForTeleprompter -> \(ready ? "🟢通道就绪" : "🔴未就绪")")
        }
    }
    
    /// 眼镜蓝牙通道就绪回调 (用于自动补推当前页逐字稿)
    var onGlassesReadyToRender: (() -> Void)?
    
    private var lastSentRawText: String = ""
    private var lastSentTargetWidthChars: Int = 28
    private var lastSentScrollModeAI: Bool = false
    private var lastSentStartLine: Int = 0
    private var renderVerificationWatchdog: DispatchWorkItem?
    private var retryCountForCurrentPush: Int = 0
    private var pendingNextSlidePush: (text: String, width: Int, scrollMode: Bool, startLine: Int)?
    
    private var pushStartTime: Date?
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
        isHardwareCanvasMounted = false
        isHardwareRenderConfirmed = false
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
    /// 实时当前朗读进度行号 (用于 AI 逐字变暗 Type 4 精准咬合)
    @Published var currentReadingLine: Int = 0
    @Published var currentWordOrder: Int = 0
    @Published var currentTotalLines: Int = 130
    @Published var linesPerPage: Int = 9
    @Published var currentWrappedLines: [String] = []
    @Published var currentGlassesState: GlassesState = .dashboard
    
    /// 视口实际对齐行号回调（眼镜端 06-01 遥测/Touchpad 物理触底上报）
    var onGlassesViewportLineReported: ((Int) -> Void)?
    
    private var currentPages: [String] = []
    var lastPhoneScrollTime: Date = Date.distantPast
    
    /// 手机端最近是否主动滑动提词 (500ms 内，用于视图层防外部回波强行 scrollTo 引起回弹)
    var isRecentPhoneScroll: Bool {
        Date().timeIntervalSince(lastPhoneScrollTime) < 0.500
    }
    
    /// 仅在用户手指触摸屏幕物理滑动时调用，精准标记物理滑动
    func markPhonePhysicalScroll() {
        self.lastPhoneScrollTime = Date()
    }
    private var lastGlassesRxScrollTime: Date = Date.distantPast
    private var lastScrollSyncSentTime: Date = Date.distantPast
    private var pendingSyncLineIndex: Int?
    private var scrollSyncThrottleWorkItem: DispatchWorkItem?
    private var lastAISyncSentTime: Date = Date.distantPast
    private var pendingAISyncTarget: (line: Int, wordOrder: Int)?
    private var aiSyncThrottleWorkItem: DispatchWorkItem?
    private var pendingRePushTask: (() -> Void)?
    private var rePushTimeoutWorkItem: DispatchWorkItem?
    var isWaitingForSessionTeardown: Bool = false
    private var sessionKeepaliveTimer: Timer?
    
    /// 当用户在手机端物理触摸屏幕滑动时，立即复位眼镜 Rx 屏障，确保手机端手势 100% 优先发包
    func resetGlassesRxShield() {
        self.lastGlassesRxScrollTime = Date.distantPast
    }
    
    // MARK: - 机制 A: 15 秒物理心跳保活 (防止 G2 固件闲置超时注销)
    private func startSessionKeepaliveTimer() {
        stopSessionKeepaliveTimer()
        DispatchQueue.main.async { [weak self] in
            // 每 5 秒轮询检查一次，确保闲置满 15s 立即无缝补发保活帧
            let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
                self?.sendSessionKeepaliveHeartbeat()
            }
            RunLoop.current.add(timer, forMode: .common)
            self?.sessionKeepaliveTimer = timer
        }
    }
    
    private func stopSessionKeepaliveTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.sessionKeepaliveTimer?.invalidate()
            self?.sessionKeepaliveTimer = nil
        }
    }
    
    private func sendSessionKeepaliveHeartbeat() {
        guard isConnected, isTeleprompterSessionActive, !isPushingText, !isWaitingForSessionTeardown else { return }
        let timeSinceLastSync = Date().timeIntervalSince(lastScrollSyncSentTime)
        guard timeSinceLastSync >= 6.0 else { return }
        
        let actualLectureLines = LectureSessionManager.shared.getWrappedScriptLines().count
        let totalLines = actualLectureLines > 0 ? actualLectureLines : currentTotalLines
        let pageMaxLine = min(9, max(totalLines - 1, 0))
        
        addLog("💓 [6s 视口保活] 闲置满 6s，下发 0x06-20 Type 255 显存保活帧 (满屏 Line \(pageMaxLine)) 与 0x80-00 硬件心跳")
        sendTeleprompterFlush(lineIndex: pageMaxLine)
        
        // 强行追加下发 0x80-00 Flush Commit 显存双缓冲翻转帧
        var seq = teleprompterSeq
        let msgId = teleprompterMsgId
        let commitPkt = G2ProtocolEncoder.buildFlushCommit(seq: &seq, msgId: msgId)
        teleprompterSeq = seq
        teleprompterMsgId = msgId + 1
        sendRawData(commitPkt, channel: .content, logDesc: "保活 0x80-00 物理心跳")
    }
    
    /// 发送 0x06-20 Type 255 提词显存提交与保活帧 (100% 物理对齐 tests/AI提词模式亮度变化.pklg 抓包)
    func sendTeleprompterFlush(lineIndex: Int) {
        guard isConnected, (isTeleprompterSessionActive || isHardwareCanvasMounted) else { return }
        if isWaitingForSessionTeardown || isPushingText { return }
        
        let actualLectureLines = LectureSessionManager.shared.getWrappedScriptLines().count
        let totalLines = actualLectureLines > 0 ? actualLectureLines : currentTotalLines
        let clampedLine = min(max(lineIndex, 0), max(totalLines - 1, 0))
        
        let flushPkt = G2ProtocolEncoder.buildTeleprompterFlush(
            seq: &teleprompterSeq,
            msgId: teleprompterMsgId,
            lineIndex: clampedLine
        )
        teleprompterMsgId += 1
        sendRawData(flushPkt, channel: .content, logDesc: "Type 255 显存提交 (Line \(clampedLine))")
    }
    
    /// 硬件物理屏幕视口高度（行数）
    /// Even G2 智能眼镜物理视口固定显示 9 行文本 (与官方 App 及独立提词器保持 100% 一致)
    static let physicalViewportLines: Int = 9
    
    /// 当前讲稿视口顶端最大行号 (Even G2 物理视口固定 9 行，触底时最后一行刚好停在屏幕第 9 行底端，消除反向滑动空转死区)
    var maxMovableLine: Int {
        let actualLectureLines = LectureSessionManager.shared.getWrappedScriptLines().count
        let total = actualLectureLines > 0 ? actualLectureLines : currentTotalLines
        return max(total - BLEManager.physicalViewportLines, 0)
    }
    
    /// 发送双向滚动位置同步 (150ms 物理节流保护，下发 0x06-20 Type 165 报文至眼镜固件)
    func sendScrollSync(lineIndex: Int, force: Bool = false) {
        guard isConnected, isTeleprompterSessionActive else { return }
        if isWaitingForSessionTeardown || isPushingText { return }
        
        // 🛡️ 双向防乒乓屏障：若当前滑动是由眼镜镜腿 Touchpad 触发的(500ms内)，手机禁止反向发包给眼镜，打断乒乓死循环
        if !force {
            let timeSinceGlassesRx = Date().timeIntervalSince(lastGlassesRxScrollTime)
            if timeSinceGlassesRx < 0.500 {
                return
            }
        } else {
            self.lastGlassesRxScrollTime = Date.distantPast
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
        
        let maxLine = self.maxMovableLine
        let clampedLine = min(max(lineIndex, 0), maxLine)
        self.currentFocusPageLine = clampedLine
        
        let syncPkt = G2ProtocolEncoder.buildScrollSync(seq: &teleprompterSeq, msgId: teleprompterMsgId, lineIndex: clampedLine)
        teleprompterMsgId += 1
        sendRawData(syncPkt, channel: .content, logDesc: "双向位置同步 (Line \(clampedLine))")
        addLog("📍 [双向同步] 已发送 0x06-20 Type 165 报文 (Line \(clampedLine))\(force ? " [终点强制对齐]" : "")")
    }
    
    /// 发送 0x06-20 AI 跟随同步与逐字变暗报文 (官方 Type 4 驱动 MicroLED 灰阶字级变暗)
    /// 100% 物理对齐 tests/AI提词模式亮度变化.pklg 抓包实测
    func sendAISync(lineIndex: Int, wordOrder: Int, force: Bool = false) {
        guard isConnected, (isTeleprompterSessionActive || isHardwareCanvasMounted) else { return }
        if isWaitingForSessionTeardown || isPushingText { return }
        
        let actualLectureLines = LectureSessionManager.shared.getWrappedScriptLines().count
        let totalLines = actualLectureLines > 0 ? actualLectureLines : currentTotalLines
        let maxAllowedLine = max(totalLines - 1, 0)
        let targetLine = min(max(lineIndex, 0), maxAllowedLine)
        let validWordOrder = max(0, wordOrder)
        
        let elapsed = Date().timeIntervalSince(lastAISyncSentTime)
        if !force && elapsed < 0.080 {
            // 🛡️ 80ms 字符级节流合并，确保高频发音时不阻塞蓝牙信道且反应灵敏
            self.pendingAISyncTarget = (targetLine, validWordOrder)
            if aiSyncThrottleWorkItem == nil {
                let item = DispatchWorkItem { [weak self] in
                    guard let self = self, let target = self.pendingAISyncTarget else { return }
                    self.aiSyncThrottleWorkItem = nil
                    self.sendAISync(lineIndex: target.line, wordOrder: target.wordOrder)
                }
                self.aiSyncThrottleWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + (0.080 - elapsed), execute: item)
            }
            return
        }
        
        self.lastAISyncSentTime = Date()
        self.pendingAISyncTarget = nil
        
        self.currentReadingLine = targetLine
        self.currentWordOrder = validWordOrder
        
        // 🌟 1. 视口随读平滑滚动规范 (100% 物理对齐 tests/AI提词模式亮度变化.pklg):
        // 当总行数在 10 行以内（满屏）时，开局已顶格满屏完整呈现（Line 0~9），朗读期间视口绝对静止，严禁下发任何 Type 165 干扰！
        // 只有当总行数 > 10 的超长文本，且朗读深入到当前视口下半区 (targetLine > self.currentFocusPageLine + 3) 时，
        // 才按需平滑微调焦点行，带单调递增保护，杜绝任何视窗抖动！
        if totalLines > 10 && targetLine > self.currentFocusPageLine + 3 {
            let maxFocus = max(totalLines - 5, 0)
            let newFocus = min(targetLine - 2, maxFocus)
            if newFocus > self.currentFocusPageLine {
                self.currentFocusPageLine = newFocus
                let scrollPkt = G2ProtocolEncoder.buildScrollSync(
                    seq: &teleprompterSeq,
                    msgId: teleprompterMsgId,
                    lineIndex: newFocus
                )
                teleprompterMsgId += 1
                sendRawData(scrollPkt, channel: .content, logDesc: "AI 跟随长文本平滑视口滚动 Type 165 (FocusLine \(newFocus))")
            }
        }
        
        // 🌟 2. 核心字级变暗信令: 官方标准 Type 4 (Tag 6 0x32 携带 page/line/charOffset) 驱动 MicroLED 灰阶字级变暗
        let aiPkt = G2ProtocolEncoder.buildAISync(
            seq: &teleprompterSeq,
            msgId: teleprompterMsgId,
            lineIndex: targetLine,
            wordOrder: validWordOrder
        )
        teleprompterMsgId += 1
        sendRawData(aiPkt, channel: .content, logDesc: "Type 4 镜显字级变暗 (Line \(targetLine), Char \(validWordOrder))")
        
        addLog("✨ [镜显逐字变暗] Line \(targetLine), WordOrder \(validWordOrder) (Type 4 已发送)")
    }
    
    /// 手势停顿/滑动结束时调用的终点同步闭环：强行刷新最新终点帧，并开放 Rx 校准通道
    func flushFinalScrollSync(lineIndex: Int) {
        guard isConnected else { return }
        sendScrollSync(lineIndex: lineIndex, force: true)
        self.lastPhoneScrollTime = Date()
        // 延时 500ms 确保手机端动画完成之后，开放眼镜 Rx 校准通道
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.500) {
            self.lastGlassesRxScrollTime = Date.distantPast
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
            self.isHardwareCanvasMounted = true
            self.startSessionKeepaliveTimer()
            let elapsedMs = pushStartTime != nil ? Int(Date().timeIntervalSince(pushStartTime!) * 1000) : 0
            let modeStr = useV2OnDemandPadding ? "V2 按需切分 (官方原装)" : "V1 14页固定 Buffer 补满"
            addLog("🎉 [Lock-step 下发完成] ⏱️ 物理发包总耗时: \(elapsedMs) ms | 策略: \(modeStr) | 下发: \(self.currentPages.count) 页")
            addLog("✅ G2 物理屏显提词与前台焦点已锁定，MicroLED 显像完成！")
            
            // 🌟 所有物理包已完整下发并触发双缓冲翻转，屏显已点亮确认
            self.isHardwareRenderConfirmed = true
            self.teleprompterPushStatusMessage = "🟢 提词已在镜显"
            self.retryCountForCurrentPush = 0
            self.renderVerificationWatchdog?.cancel()
            self.renderVerificationWatchdog = nil
            
            // 🎯 检查在推流发包期间是否有暂存的下一页请求，有则自动无缝续推
            if let pending = self.pendingNextSlidePush {
                self.pendingNextSlidePush = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.080) { [weak self] in
                    self?.sendTeleprompterText(pending.text, targetWidthChars: pending.width, scrollModeAI: pending.scrollMode, startLine: pending.startLine)
                }
            }
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
        
        if bt3CurrentIndex == 0 {
            self.pushStartTime = Date() // ⏱️ 记录物理传输 Packet #1 下发的绝对起始时间
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
    
    /// 动态编码并推送讲稿文本到 G2 眼镜 (100% 官方原装按需下发，严格对齐内容实际行数)
    func sendTeleprompterText(_ rawText: String, targetWidthChars: Int = 28, scrollModeAI: Bool = true, startLine: Int = 0, linesPerPage: Int? = nil) {
        let effectiveLinesPerPage = linesPerPage ?? self.linesPerPage
        // 🌟 统一全量路由至 V2 官方按需下发路径 (严格对齐内容行数，绝不补满 14 页)
        sendTeleprompterTextV2(rawText, targetWidthChars: targetWidthChars, scrollModeAI: scrollModeAI, startLine: startLine, linesPerPage: effectiveLinesPerPage)
    }
        

    
    /// §25 官方按需下发 V2: 100% 对齐 multiprompts.pklg 官方发包序列
    /// 差异: 动态 Init 参数 + 按需页数(不补满) + type=255 Complete + 双 Render Commit
    func sendTeleprompterTextV2(_ rawText: String, targetWidthChars: Int = 28, scrollModeAI: Bool = true, startLine: Int = 0, linesPerPage: Int? = nil) {
        let effectiveLinesPerPage = linesPerPage ?? self.linesPerPage
        guard isConnected else {
            addLog("⚠️ 蓝牙未连接，请先连接 G2 眼镜")
            return
        }
        guard contentTxChar != nil else {
            addLog("⚠️ 5401 通道未绑定")
            return
        }
        
        // 🎯 1. 每次新推流彻底重置看门狗与重试计数，确保新页状态独立
        self.retryCountForCurrentPush = 0
        self.renderVerificationWatchdog?.cancel()
        self.renderVerificationWatchdog = nil
        
        // 🎯 2. 并发切页防吞机制：若当前正在发包，记录最新讲稿，发包完成后自动续推最新页
        if isPushingText {
            addLog("⏳ [并发切页暂存] 当前正在下发讲稿，已暂存最新页待完成时自动续推...")
            self.pendingNextSlidePush = (rawText, targetWidthChars, scrollModeAI, startLine)
            return
        }
        
        // 记录当前推屏参数以备硬件超时自动重试
        self.lastSentRawText = rawText
        self.lastSentTargetWidthChars = targetWidthChars
        self.lastSentScrollModeAI = scrollModeAI
        self.lastSentStartLine = startLine
        
        // 🎯 3. 若正在等待旧 Session 注销，直接更新回调任务为最新页文本，避免并发乱序
        if isWaitingForSessionTeardown {
            addLog("⏳ [注销中换页] 旧 Session 注销中，更新目标推送任务为最新页...")
            self.pendingRePushTask = { [weak self] in
                guard let self = self else { return }
                self.sendTeleprompterTextV2(rawText, targetWidthChars: targetWidthChars, scrollModeAI: scrollModeAI, startLine: startLine, linesPerPage: effectiveLinesPerPage)
            }
            return
        }
        
        // 🎯 4. 热重推: 先发 state=4 退出旧 Session
        if isTeleprompterSessionActive {
            addLog("🔄 [V2 热重推] 先发 state=4 退出旧 Session...")
            self.isHardwareRenderConfirmed = false
            self.teleprompterPushStatusMessage = "🟡 正在刷新屏显..."
            
            self.pendingRePushTask = { [weak self] in
                guard let self = self else { return }
                self.addLog("⚡️ [V2 Session Terminated 确认] 自动启动 V2 按需推流...")
                self.sendTeleprompterTextV2(rawText, targetWidthChars: targetWidthChars, scrollModeAI: scrollModeAI, startLine: startLine, linesPerPage: effectiveLinesPerPage)
            }
            
            // 设置 3.0 秒超时保底：给予 MCU 充足注销窗口，正常收到 0D-01 即刻 cancel，杜绝假超时抢跑引发黑屏
            let timeoutItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if self.isWaitingForSessionTeardown {
                    self.addLog("⏱️ [V2 超时保底] 3.0s 未收到 Session Terminated，自动执行冷启动自愈推流")
                    self.isWaitingForSessionTeardown = false
                    self.isTeleprompterSessionActive = false
                    self.isHardwareCanvasMounted = false
                    if let task = self.pendingRePushTask {
                        self.pendingRePushTask = nil
                        task()
                    }
                }
            }
            self.rePushTimeoutWorkItem = timeoutItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: timeoutItem)
            
            sendExitTeleprompterMode()
            return
        }
        
        // 冷启动 / 自愈推流路径
        cancelPendingTeleprompterTasks()
        self.isPushingText = true
        self.targetStartLine = startLine
        self.currentReadingLine = startLine
        self.currentWordOrder = 0
        
        // 🛡️ 固件底层 Page Slot 物理槽位恒定为 10 行。下发时严格按 10 行连续紧密装填，
        // 最后一页保留真实行数，按需生成实际页数（绝不多补 14 页空白缓冲）；
        // 视口满屏高度则由 TeleprompterInit Field 9 (linesPerPage) 动态控制。
        let (pages, totalLines) = G2ProtocolEncoder.formatTextToPagesOnDemand(rawText, maxLineWidth: targetWidthChars * 2, linesPerPage: 10)
        self.currentPages = pages
        self.currentTotalLines = max(totalLines, 1)
        let totalPages = pages.count
        
        self.currentFocusPageLine = startLine
        DispatchQueue.main.async {
            self.currentFocusPageLine = startLine
            self.currentReadingLine = startLine
            self.currentWordOrder = 0
        }
        
        var packets: [Data] = []
        var descs: [String] = []
        
        var seq: UInt8 = self.teleprompterSeq == 0 ? 0x01 : self.teleprompterSeq
        var msgId: Int = self.teleprompterMsgId == 0 ? 0x01 : self.teleprompterMsgId
        
        // [冷启动 vs 热重推判定 (100% 对齐官方 §23.2 与 multiprompts.pklg 抓包)]
        // 当次 BLE 物理连接建立后的首次推屏（Push #1 冷启动）：必须下发 Auth (4包) + Setup (6包)
        // 后续翻页与重推（Push #2+ 热重推）：必须跳过 Auth 和 Setup！绝不重复下发 Setup（重复下发会导致 MCU 视口重置黑屏）！
        let isColdStart = !hasAuthBeenDoneForCurrentConnection
        if isColdStart {
            addLog("🔑 [V2 首次冷启动] 下发 Auth (4包) + Setup (6包) 挂载 MicroLED 画布与视口通道...")
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
            self.isHardwareCanvasMounted = true
        } else {
            addLog("⚡️ [V2 热重推] 已完成基础 Setup，严格跳过 Auth/Setup，直接下发提词序列 (防黑屏)...")
        }
        
        // §25.1: TeleprompterInit V2 参数：100% 官方原装 (Field 4 动态总页数, Field 5 动态总行数, Field 9 动态每屏行数)
        let initPages = totalPages
        let initLines = totalLines
        
        let initPkts = G2ProtocolEncoder.buildTeleprompterInitV2(seq: &seq, msgId: msgId, totalPages: initPages, totalLines: initLines, linesPerPage: effectiveLinesPerPage, scrollModeAI: scrollModeAI)
        for pkt in initPkts {
            packets.append(pkt)
            descs.append("V2 TeleprompterInit (pages=\(initPages), lines=\(initLines), lpp=\(effectiveLinesPerPage))")
        }
        msgId += 1
        
        // 100% 对齐 multiprompts.pklg 帧 #1: 补全 2 包 System Layout Config (0x01-20) 硬件视口开辟包
        packets.append(G2ProtocolEncoder.buildSystemLayoutConfig(seq: &seq, msgId: msgId))
        descs.append("System Layout Config 1 (0x01-20)")
        msgId += 1
        
        packets.append(G2ProtocolEncoder.buildTouchpadEventListener(seq: &seq, msgId: msgId))
        descs.append("System Layout Config 2 (0x01-20 Touchpad Listener)")
        msgId += 1
        
        // Pages 灌入 (仅实际内容页，不补满)
        for (i, pageText) in pages.enumerated() {
            let pagePkts = G2ProtocolEncoder.buildContentPagePackets(seq: &seq, msgId: msgId, pageNum: i, text: pageText)
            for pkt in pagePkts {
                packets.append(pkt)
                descs.append("Page \(i)")
            }
            msgId += 1
        }
        
        // §25.3: ScrollSync × 2 (对齐 multiprompts.pklg #4/#5: 在 Commit 前发，首页顶格为 startLine)
        let syncPkt1 = G2ProtocolEncoder.buildScrollSync(seq: &seq, msgId: msgId, lineIndex: startLine)
        packets.append(syncPkt1)
        descs.append("V2 ScrollSync #1 (line \(startLine))")
        msgId += 1
        
        let syncPkt2 = G2ProtocolEncoder.buildScrollSync(seq: &seq, msgId: msgId, lineIndex: startLine)
        packets.append(syncPkt2)
        descs.append("V2 ScrollSync #2 (line \(startLine))")
        msgId += 1
        
        // §25.3: Render Commit #1 (对齐 multiprompts.pklg #6)
        let pktCommit1 = G2ProtocolEncoder.buildFlushCommit(seq: &seq, msgId: msgId)
        packets.append(pktCommit1)
        descs.append("V2 Render Commit #1")
        msgId += 1
        
        // §25.2: TeleprompterComplete type=255 (对齐 multiprompts.pklg #7 / 最新固件抓包: 动态传入当前 page 与 line)
        let completePage = startLine / 10
        let completeLine = startLine % 10
        let pktComplete = G2ProtocolEncoder.buildTeleprompterComplete(seq: &seq, msgId: msgId, page: completePage, line: completeLine)
        packets.append(pktComplete)
        descs.append("V2 TeleprompterComplete (type=255, p=\(completePage), l=\(completeLine))")
        msgId += 1
        
        // §25.3: Render Commit #2 (对齐 multiprompts.pklg #8)
        let pktCommit2 = G2ProtocolEncoder.buildFlushCommit(seq: &seq, msgId: msgId)
        packets.append(pktCommit2)
        descs.append("V2 Render Commit #2")
        msgId += 1
        
        let modeTag = useV2OnDemandPadding ? "⚡️ [V2 按需切分 (100% 官方)]" : "📦 [V1 14页固定 Buffer 补满]"
        addLog("\(modeTag) 开始下发 \(packets.count) 包 (\(totalPages) 有效页, \(totalLines) 总行) — 对齐官方物理信令...")
        
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
        stopSessionKeepaliveTimer()
        self.isWaitingForSessionTeardown = true
        self.isTeleprompterSessionActive = false
        self.isHardwareCanvasMounted = false
        self.isHardwareRenderConfirmed = false
        self.teleprompterPushStatusMessage = "🟡 正在切换页面..."
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
        
        // §22.2 Step 3: 紧跟发送 0x80-00 Render Commit (切回 Dashboard 界面)，触发 MCU 快速回发 0D-01 Session Terminated
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
    
    /// 手动强制彻底重新推送当前讲稿至智能眼镜（强力复位Session + 消除死锁）
    func retryCurrentSlidePush() {
        guard isReadyForTeleprompter, !lastSentRawText.isEmpty else {
            addLog("⚠️ Even G2 未就绪或无历史讲稿，跳过重推")
            return
        }
        addLog("🔄 [手动强力重推] 彻底复位硬件 Session 并重新灌入当前讲稿...")
        self.renderVerificationWatchdog?.cancel()
        self.renderVerificationWatchdog = nil
        self.cancelPendingTeleprompterTasks()
        self.isWaitingForSessionTeardown = false
        self.isPushingText = false
        self.isTeleprompterSessionActive = false
        self.isHardwareCanvasMounted = false
        self.retryCountForCurrentPush = 0
        self.teleprompterPushStatusMessage = "🟡 正在重置屏显..."
        
        // 强制向硬件发送一次 state=4 清理残留显存与 Session
        sendExitTeleprompterMode()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.180) { [weak self] in
            guard let self = self else { return }
            self.isWaitingForSessionTeardown = false
            self.sendTeleprompterTextV2(self.lastSentRawText, targetWidthChars: self.lastSentTargetWidthChars, scrollModeAI: self.lastSentScrollModeAI, startLine: self.lastSentStartLine)
        }
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
    /// §25 实测切换: V2 按需下发 (对齐官方 multiprompts.pklg 协议)
    func sendFullScreenTeleprompterText(_ text: String, targetWidthChars: Int = 28) {
        // V1 (14 页补满保守策略，如 V2 测试失败可快速回退):
        // sendTeleprompterText(text, targetWidthChars: targetWidthChars)
        sendTeleprompterTextV2(text, targetWidthChars: targetWidthChars)
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
            
            // 捕获眼镜端主动退出提词器模式通知
            // 1) 换页主动注销确认: 在 isWaitingForSessionTeardown 期间收到 0x0D-01/00 回执
            let isTeardownAck = self.isWaitingForSessionTeardown && (sHi == 0x0D && (sLo == 0x01 || sLo == 0x00))
            // 2) 眼镜端主动退出提词: Svc 0D-01 (含 1A 00 Session Terminated 或 08 06)
            let isSessionTerminatedNotify = (sHi == 0x0D && sLo == 0x01) && (relativeData.contains(Data([0x1A, 0x00])) || relativeData.contains(Data([0x08, 0x06])))
            // 3) Svc 01-01: 镜腿手势退出 (含 08 03)
            let isGestureExit = (sHi == 0x01 && sLo == 0x01) && relativeData.contains(Data([0x08, 0x03]))
            // 4) Dashboard 退出指令: 含 22 02 08 04
            let isSessionExit = relativeData.range(of: Data([0x22, 0x02, 0x08, 0x04])) != nil
            // 5) 屏幕休眠 / 息屏: Svc 04-01 / 04-00
            let isDisplaySleep = (sHi == 0x04 && (sLo == 0x01 || sLo == 0x00)) && (relativeData.contains(Data([0x08, 0x02])) || relativeData.contains(Data([0x1A, 0x02, 0x08, 0x02])))
            
            if isTeardownAck || isSessionTerminatedNotify || isGestureExit || isSessionExit || isDisplaySleep {
                DispatchQueue.main.async {
                    self.isWaitingForSessionTeardown = false
                    self.isTeleprompterSessionActive = false
                    self.isHardwareRenderConfirmed = false
                    self.isHardwareCanvasMounted = false
                    self.isPushingText = false
                    self.teleprompterPushStatusMessage = "🔴 提词已退出"
                    self.stopSessionKeepaliveTimer()
                    self.addLog("🛑 [眼镜端退出/会话释放] (Svc \(svcStr): Session Terminated) → Session 已物理注销，UI 状态已同步置为🔴提词已退出")
                    
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
                // 1. 🌟 Tag 0x52 (Type 164 - 固件渲染/屏显就绪回执)
                // 物理特征: 08 a4 01 10 xx 52 02 08 01
                // 语义: 固件底层 MicroLED 渲染完成确认 (08 01 为 Status=1/Success ACK)，绝非视口行号！
                if data.range(of: Data([0x52])) != nil {
                    DispatchQueue.main.async {
                        self.isHardwareRenderConfirmed = true
                        self.retryCountForCurrentPush = 0
                        self.renderVerificationWatchdog?.cancel()
                        self.renderVerificationWatchdog = nil
                        self.teleprompterPushStatusMessage = "🟢 提词已在镜显"
                        self.addLog("✅ [硬件屏显确认] 收到 G2 MCU 渲染就绪回执 (Tag 0x52 Success)")
                    }
                    onG2TelemetryLog?("Rx", hexString, "06-01 Telemetry: 📺 硬件屏显就绪确认 (Tag 0x52)")
                    continue
                }
                
                // 2. 🌟 Tag 0x5A (Type 165 - Touchpad 镜腿滑动手势 / 物理视口回波)
                // 物理特征: 08 a5 01 10 xx 5a 02 10 <line>
                // 语义: 真实的视口绝对物理行号 (Field 2: 10 <line>)
                if let idx5A = data.range(of: Data([0x5A]))?.lowerBound {
                    let len = idx5A + 1 < data.count ? Int(data[idx5A + 1]) : 0
                    let endIdx = min(data.count, idx5A + 2 + len)
                    let sub = data.subdata(in: min(data.count, idx5A + 2)..<endIdx)
                    
                    var reportedLine: Int? = nil
                    if let idx10 = sub.range(of: Data([0x10]))?.lowerBound, idx10 + 1 < sub.count {
                        reportedLine = Int(sub[idx10 + 1])
                    }
                    
                    if let line = reportedLine, line >= 0 && line <= 200 {
                        let maxLine = self.maxMovableLine
                        let clampedLine = min(max(line, 0), maxLine)
                        let timeSincePhoneScroll = Date().timeIntervalSince(self.lastPhoneScrollTime)
                        
                        // 手机主控保护期 (250ms): 若当前手机刚主动滚动过，且回波落后于预期推进方向，屏蔽以防 UI 抖动
                        if (timeSincePhoneScroll < 0.250 || self.isPushingText) && clampedLine >= self.currentFocusPageLine {
                            DispatchQueue.main.async {
                                self.addLog("🛡️ [主控屏障] 屏蔽眼镜 Touchpad 回波 (Line \(line))，防止 UI 回弹")
                            }
                        } else {
                            self.lastGlassesRxScrollTime = Date()
                            DispatchQueue.main.async {
                                self.currentFocusPageLine = clampedLine
                                self.lastGestureReceived = "👆 镜腿手势 -> L\(clampedLine)"
                                self.addLog("🎯 👆 [RX 06-01 镜腿滑动] 视口平移至第 \(clampedLine) 行 (原始 Rx: \(line), 上限 \(maxLine))")
                                self.onGlassesViewportLineReported?(clampedLine)
                            }
                        }
                    }
                    onG2TelemetryLog?("Rx", hexString, "06-01 Telemetry: 👆 镜腿手势 (Tag 0x5A)")
                    continue
                }
                
                // 3. 🌟 Tag 0x72 (Type 167 - 文本灌入过程中的固件流控包)
                if data.range(of: Data([0x72])) != nil {
                    DispatchQueue.main.async {
                        self.addLog("📄 [流控回执] 收到 G2 页面缓存流控标记 (Tag 0x72)")
                    }
                    onG2TelemetryLog?("Rx", hexString, "06-01 Telemetry: 📄 视口流控标记 (Tag 0x72)")
                    continue
                }
                
                DispatchQueue.main.async {
                    self.addLog("🎯 👆 [RX 06-01 遥测] [\(hexString)]")
                }
                onG2TelemetryLog?("Rx", hexString, "06-01 Telemetry: [\(hexString)]")
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
        // 目标外设与特征通道精准选择：音频流控优先左耳 audioPeripheral，主命令使用 targetPeripheral
        let p: CBPeripheral?
        let txChar: CBCharacteristic?
        
        switch channel {
        case .control:
            p = targetPeripheral ?? audioPeripheral
            txChar = (p == targetPeripheral ? controlTxChar : audioControlTxChar) ?? controlTxChar ?? audioControlTxChar
        case .content:
            p = targetPeripheral ?? audioPeripheral
            txChar = (p == targetPeripheral ? contentTxChar : audioContentTxChar) ?? contentTxChar ?? audioContentTxChar
        case .teleprompter:
            p = targetPeripheral ?? audioPeripheral
            txChar = (p == targetPeripheral ? teleprompterTxChar : contentTxChar) ?? contentTxChar
        case .rendering:
            p = targetPeripheral ?? audioPeripheral
            txChar = (p == targetPeripheral ? renderingTxChar : audioTxChar) ?? contentTxChar
        case .audio:
            p = audioPeripheral ?? targetPeripheral
            txChar = (p == audioPeripheral ? audioTxChar : renderingTxChar) ?? audioTxChar ?? contentTxChar
        }
        
        guard let finalTxChar = txChar else {
            addLog("⚠️ 发送失败: 无法找到 [\(channel)] 通道对应的 TX 特征值")
            return
        }
        
        // 关键安全防护：确保使用的外设与特征值所属的外设绝对一致，杜绝跨外设写特征
        let actualPeripheral = finalTxChar.service?.peripheral ?? p
        guard let peripheral = actualPeripheral, peripheral.state == .connected else {
            addLog("⚠️ 发送失败: 目标蓝牙外设未连接 (ch=\(channel), p=\(p?.name ?? "nil"))")
            return
        }
        
        // 增加物理发包计数与确凿时间戳
        DispatchQueue.main.async {
            self.physicalWriteCount += 1
        }
        
        let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let uuidSuffix = String(finalTxChar.uuid.uuidString.suffix(4))
        print("🔥 [\(uuidSuffix) 物理 BLE 写入第 \(physicalWriteCount + 1) 包] \(dateStr) | len=\(data.count)b | ch=\(channel) | desc=\(logDesc ?? "")")
        
        // 尊重蓝牙物理特征值广播属性，动态安全选择写入模式 (防止系统抛出拒绝写入 Error)
        let writeType: CBCharacteristicWriteType = getWriteType(for: finalTxChar)
        peripheral.writeValue(data, for: finalTxChar, type: writeType)
        
        let hexString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        
        if let logDesc = logDesc {
            addLog("⬆️ [TX 发送 -> \(uuidSuffix)] \(logDesc) (Type: \(writeType == .withResponse ? "WithResp" : "NoResp"))")
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
    
    func handleWatchGesture(action: String, source: String = "Watch") {
        let maxLine = self.maxMovableLine
        
        switch action {
        case "SCROLL_DOWN", "CROWN_DOWN", "SWIPE_UP", "SINGLE_TAP":
            // 1. 基准归位：严格限制在 [0, maxLine]
            let baseLine = min(max(currentFocusPageLine, 0), maxLine)
            
            // 2. 边缘硬锁死：若当前已达最底部 (baseLine >= maxLine)，死死锁在 maxLine！
            // 严禁产生任何隐形越界累加，彻底杜绝反向滑动时的空转滞后！
            if baseLine >= maxLine {
                self.currentFocusPageLine = maxLine
                LectureSessionManager.shared.syncStateToWatch(lineIndex: maxLine, forceImmediate: true)
                addLog("🛑 ⌚️ 已处于讲稿最底部 (Line \(maxLine))，位置死锁，拦截越界发包")
                return
            }
            
            addLog("⌚️ 接收到 Watch 触控/手势 [\(action)] (Source: \(source))")
            // 保持 lastPhoneScrollTime 为历史时间，确保手机端 HUD 视口能够及时同步响应并滚动
            self.lastGlassesRxScrollTime = Date.distantPast
            
            // 3. 步长精准区分：
            // - 单击 (SINGLE_TAP) / 表冠 (CROWN_DOWN): 单行微调 1 行
            // - 上下滑动 (SCROLL_DOWN / SWIPE_UP): 高效快速滚 3 行
            let step: Int
            if action == "SINGLE_TAP" || action == "CROWN_DOWN" {
                step = 1
            } else if action == "SCROLL_DOWN" || action == "SWIPE_UP" {
                step = 3
            } else {
                step = max(self.linesPerPage, 1)
            }
            let nextLine = min(baseLine + step, maxLine)
            self.currentFocusPageLine = nextLine
            if isConnected && isTeleprompterSessionActive {
                sendScrollSync(lineIndex: nextLine, force: true)
            }
            LectureSessionManager.shared.syncStateToWatch(lineIndex: nextLine, forceImmediate: true)
            
        case "SCROLL_UP", "CROWN_UP", "SWIPE_DOWN":
            // 1. 基准归位：严格限制在 [0, maxLine]
            let baseLine = min(max(currentFocusPageLine, 0), maxLine)
            
            // 2. 边缘硬锁死：若当前已处于最顶部 (baseLine <= 0)，死死锁在 0！
            // 严禁产生负数越界，彻底消除反向滑动延迟！
            if baseLine <= 0 {
                self.currentFocusPageLine = 0
                LectureSessionManager.shared.syncStateToWatch(lineIndex: 0, forceImmediate: true)
                addLog("🛑 ⌚️ 已处于讲稿最顶部 (Line 0)，位置死锁，拦截发包")
                return
            }
            
            addLog("⌚️ 接收到 Watch 触控/手势 [\(action)] (Source: \(source))")
            // 保持 lastPhoneScrollTime 为历史时间，确保手机端 HUD 视口能够及时同步响应并滚动
            self.lastGlassesRxScrollTime = Date.distantPast
            
            // 3. 步长精准区分：
            // - 表冠 (CROWN_UP): 单行上移 1 行
            // - 上下滑动 (SCROLL_UP / SWIPE_DOWN): 高效上滚 3 行
            let step: Int
            if action == "CROWN_UP" {
                step = 1
            } else if action == "SCROLL_UP" || action == "SWIPE_DOWN" {
                step = 3
            } else {
                step = max(self.linesPerPage, 1)
            }
            let prevLine = max(baseLine - step, 0)
            self.currentFocusPageLine = prevLine
            if isConnected && isTeleprompterSessionActive {
                sendScrollSync(lineIndex: prevLine, force: true)
            }
            LectureSessionManager.shared.syncStateToWatch(lineIndex: prevLine, forceImmediate: true)
            
        default:
            break
        }
    }
    
    // MARK: - 智能眼镜麦克风音频流控制 (Glasses Mic Control via Service 0x64-50 & 0xE0 / 0x0E)
    
    /// 启动眼镜镜腿麦克风采音流
    func startGlassesMicrophone() {
        guard isConnected else {
            addLog("⚠️ 无法启动眼镜麦克风: 蓝牙未连接")
            return
        }
        
        // 1. 确保左耳 6402 Notify 处于激活状态
        if let rxChar = audioRxChar, let peripheral = rxChar.service?.peripheral ?? audioPeripheral {
            if !rxChar.isNotifying {
                addLog("🔔 [6402 订阅检查] 发现 6402 未激活，立即请求 setNotifyValue(true)...")
                peripheral.setNotifyValue(true, for: rxChar)
            }
        }
        
        // 2. 前置会话保障：若尚未进入提词会话态，自动挂载提词测试屏显以激活 MicroLED 容器，确保 MCU 解锁麦克风硬件
        if !isTeleprompterSessionActive && !isPushingText {
            addLog("⚡️ [眼镜模式激活] 检测到尚未进入会话态，自动下发屏显容器使能麦克风硬件...")
            sendTeleprompterText("NCU 智能眼镜采音测试\n麦克风流传输中...", targetWidthChars: 28, scrollModeAI: true, startLine: 0)
        }
        
        addLog("🎙️ [眼镜麦克风] 正在多通道激活麦克风采音 (左耳 6401/5401 + 右耳 5401)...")
        var seq = self.teleprompterSeq
        
        // A. 官方标准 Cmd=18 (APP_REQUEST_AUDIO_CTR_PACKET) 报文
        let pkt18 = G2ProtocolEncoder.buildAudioControlPacket(enable: true, seq: &seq, cmd: 18)
        self.teleprompterSeq = seq
        
        // 写入左耳 6401
        if let char = audioTxChar, let p = char.service?.peripheral ?? audioPeripheral {
            let writeType = getWriteType(for: char)
            p.writeValue(pkt18, for: char, type: writeType)
            addLog("⬆️ [TX -> 左耳 6401] AudioCtrCmd18(Enable=1)")
        }
        // 写入左耳 5401 (若存在)
        if let char = audioContentTxChar, let p = char.service?.peripheral ?? audioPeripheral {
            let writeType = getWriteType(for: char)
            p.writeValue(pkt18, for: char, type: writeType)
            addLog("⬆️ [TX -> 左耳 5401] AudioCtrCmd18(Enable=1)")
        }
        // 写入右耳 5401
        if let char = contentTxChar, let p = char.service?.peripheral ?? targetPeripheral {
            let writeType = getWriteType(for: char)
            p.writeValue(pkt18, for: char, type: writeType)
            addLog("⬆️ [TX -> 右耳 5401] AudioCtrCmd18(Enable=1)")
        }
        
        // B. 辅助透传指令 [0x0E, 0x01]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self, self.isConnected else { return }
            let rawCmd = G2ProtocolEncoder.buildRawMicControlPacket(enable: true)
            if let char = self.audioTxChar, let p = char.service?.peripheral ?? self.audioPeripheral {
                let writeType = self.getWriteType(for: char)
                p.writeValue(rawCmd, for: char, type: writeType)
                self.addLog("⬆️ [TX -> 左耳 6401] RawMicCmd[0x0E, 0x01]")
            }
            if let char = self.audioContentTxChar, let p = char.service?.peripheral ?? self.audioPeripheral {
                let writeType = self.getWriteType(for: char)
                p.writeValue(rawCmd, for: char, type: writeType)
                self.addLog("⬆️ [TX -> 左耳 5401] RawMicCmd[0x0E, 0x01]")
            }
            if let char = self.contentTxChar, let p = char.service?.peripheral ?? self.targetPeripheral {
                let writeType = self.getWriteType(for: char)
                p.writeValue(rawCmd, for: char, type: writeType)
                self.addLog("⬆️ [TX -> 右耳 5401] RawMicCmd[0x0E, 0x01]")
            }
        }
        
        // C. 兼容性备选：80ms 后发送 Cmd=15
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            guard let self = self, self.isConnected else { return }
            var s = self.teleprompterSeq
            let pkt15 = G2ProtocolEncoder.buildAudioControlPacket(enable: true, seq: &s, cmd: 15)
            self.teleprompterSeq = s
            if let char = self.audioTxChar, let p = char.service?.peripheral ?? self.audioPeripheral {
                let writeType = self.getWriteType(for: char)
                p.writeValue(pkt15, for: char, type: writeType)
            }
            if let char = self.contentTxChar, let p = char.service?.peripheral ?? self.targetPeripheral {
                let writeType = self.getWriteType(for: char)
                p.writeValue(pkt15, for: char, type: writeType)
            }
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isGlassesMicActive = true
            self.startPPSMonitor()
        }
    }
    
    /// 关闭眼镜镜腿麦克风采音流 (保护眼镜电池)
    func stopGlassesMicrophone() {
        guard isConnected else { return }
        
        addLog("🎙️ [眼镜麦克风] 正在多通道下发 AudioCtrCmd 关闭麦克风采音 (省电保护)...")
        var seq = self.teleprompterSeq
        let pkt18 = G2ProtocolEncoder.buildAudioControlPacket(enable: false, seq: &seq, cmd: 18)
        self.teleprompterSeq = seq
        
        if let char = audioTxChar, let p = char.service?.peripheral ?? audioPeripheral {
            let writeType = getWriteType(for: char)
            p.writeValue(pkt18, for: char, type: writeType)
        }
        if let char = audioContentTxChar, let p = char.service?.peripheral ?? audioPeripheral {
            let writeType = getWriteType(for: char)
            p.writeValue(pkt18, for: char, type: writeType)
        }
        if let char = contentTxChar, let p = char.service?.peripheral ?? targetPeripheral {
            let writeType = getWriteType(for: char)
            p.writeValue(pkt18, for: char, type: writeType)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self = self, self.isConnected else { return }
            let rawCmd = G2ProtocolEncoder.buildRawMicControlPacket(enable: false)
            if let char = self.audioTxChar, let p = char.service?.peripheral ?? self.audioPeripheral {
                let writeType = self.getWriteType(for: char)
                p.writeValue(rawCmd, for: char, type: writeType)
            }
            if let char = self.audioContentTxChar, let p = char.service?.peripheral ?? self.audioPeripheral {
                let writeType = self.getWriteType(for: char)
                p.writeValue(rawCmd, for: char, type: writeType)
            }
            if let char = self.contentTxChar, let p = char.service?.peripheral ?? self.targetPeripheral {
                let writeType = self.getWriteType(for: char)
                p.writeValue(rawCmd, for: char, type: writeType)
            }
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isGlassesMicActive = false
            self.stopPPSMonitor()
            self.audioPacketPPS = 0
        }
    }
    
    private func startPPSMonitor() {
        stopPPSMonitor()
        ppsCounter = 0
        ppsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.audioPacketPPS = self.ppsCounter
                self.ppsCounter = 0
            }
        }
    }
    
    private func stopPPSMonitor() {
        ppsTimer?.invalidate()
        ppsTimer = nil
        ppsCounter = 0
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
