import Foundation
import CoreBluetooth
import Combine

class BLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var isConnected = false
    @Published var isScanning = false
    @Published var connectedPeripheralName: String? = nil
    @Published var lastGestureReceived: String = "None"
    
    // CoreBluetooth 句柄
    private var centralManager: CBCentralManager!
    private var targetPeripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    
    // 手势与翻页回调
    var onPageControlTriggered: ((String) -> Void)?
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    private var isManualDisconnect = false
    
    func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        isManualDisconnect = false
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
        if let peripheral = targetPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
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
            targetPeripheral = peripheral
            targetPeripheral?.delegate = self
            stopScanning()
            centralManager.connect(peripheral, options: nil)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        connectedPeripheralName = peripheral.name ?? "Even G2 Smart Glass"
        lastBLEStatusMessage = "🟢 蓝牙已连接设备: \(connectedPeripheralName ?? "")"
        peripheral.discoverServices(nil)
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        connectedPeripheralName = nil
        if !isManualDisconnect {
            startScanning()
        } else {
            lastBLEStatusMessage = "已断开蓝牙，点击按钮可重新扫描"
        }
    }
    
    // MARK: - CBPeripheralDelegate
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            if characteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            if characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) {
                txCharacteristic = characteristic
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        // 模拟解调 Even G2 镜腿 Touchpad / 戒指按键手势信号
        let rawByte = data.first ?? 0
        if rawByte == 0x01 {
            lastGestureReceived = "Swipe Down / Next"
            onPageControlTriggered?("NEXT")
        } else if rawByte == 0x02 {
            lastGestureReceived = "Swipe Up / Prev"
            onPageControlTriggered?("PREV")
        } else if rawByte == 0x03 {
            lastGestureReceived = "Ring Click / Next"
            onPageControlTriggered?("NEXT")
        }
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
        sendRawCommand(bytes: [0x00, 0xFF, 0x00, 0x00])
        DispatchQueue.main.async {
            self.lastBLEStatusMessage = "⚪ 已向眼镜发送息屏/清屏指令"
        }
    }
    
    func wakeHUD() {
        sendRawCommand(bytes: [0x00, 0xFF, 0x01, 0x01])
        DispatchQueue.main.async {
            self.lastBLEStatusMessage = "🟢 已向眼镜发送显存唤醒/亮屏指令"
        }
    }
    
    @Published var lastBLEStatusMessage: String = "等待扫描连接眼镜"

    private func sendRawCommand(bytes: [UInt8]) {
        guard isConnected else {
            print("⚠️ 蓝牙未连接：无法向 Even G2 发送指令，请先点击 [扫描连接 Even G2]")
            DispatchQueue.main.async {
                self.lastBLEStatusMessage = "⚠️ 请先点击下方 [扫描连接 Even G2]"
            }
            return
        }
        guard let peripheral = targetPeripheral, let txChar = txCharacteristic else {
            print("⚠️ 蓝牙特征通道未就绪")
            DispatchQueue.main.async {
                self.lastBLEStatusMessage = "⚠️ 蓝牙特征通道未就绪"
            }
            return
        }
        let data = Data(bytes)
        peripheral.writeValue(data, for: txChar, type: .withoutResponse)
        DispatchQueue.main.async {
            self.lastBLEStatusMessage = "🟢 指令已通过 BLE 发送到眼镜"
        }
    }
    
    /// 向 Even G2 发送 3 行 HUD 显存刷新数据帧
    func sendHUDFrame(chunk: HUDDisplayChunk) {
        guard isConnected, isHUDDisplayActive, let peripheral = targetPeripheral, let txChar = txCharacteristic else { return }
        let payloadString = "\(chunk.headerText)\n\(chunk.highlightedLine)\n\(chunk.nextLinePreview)"
        if let data = payloadString.data(using: .utf8) {
            peripheral.writeValue(data, for: txChar, type: .withoutResponse)
            DispatchQueue.main.async {
                self.lastBLEStatusMessage = "🟢 3行 HUD 显存帧已同步到眼镜"
            }
        }
    }
}
