//
//  AudioInputSource.swift
//  SmartGlassGateway
//
//  Created by Antigravity on 2026-09-06.
//

import Foundation
import AVFoundation

/// 音频输入源枚举
enum AudioSourceType: String, CaseIterable, Identifiable {
    case phoneMic = "手机麦克风"
    case glassesMic = "眼镜麦克风"
    
    var id: String { rawValue }
    
    var iconName: String {
        switch self {
        case .phoneMic: return "iphone"
        case .glassesMic: return "eyeglasses"
        }
    }
    
    var subtitle: String {
        switch self {
        case .phoneMic: return "48kHz 高保真原生波束成形阵列 (手机在身边最佳)"
        case .glassesMic: return "16kHz LC3 蓝牙超低功耗音频流 (手机离身移动场景)"
        }
    }
}

/// 音频输入源统一协议
protocol AudioInputSourceProtocol: AnyObject {
    var sourceType: AudioSourceType { get }
    var isRunning: Bool { get }
    
    /// 当采集或解码出可供识别的 PCM 音频缓冲区时触发
    var onAudioBufferCaptured: ((AVAudioPCMBuffer) -> Void)? { get set }
    
    /// 当音频底层出现故障或意外断开时触发
    var onError: ((Error) -> Void)? { get set }
    
    /// 启动音频捕获流水线
    func start() throws
    
    /// 停止音频捕获流水线
    func stop()
}

// MARK: - 1. 手机内置麦克风输入源 (PhoneBuiltinAudioSource)
final class PhoneBuiltinAudioSource: AudioInputSourceProtocol {
    let sourceType: AudioSourceType = .phoneMic
    private(set) var isRunning: Bool = false
    
    var onAudioBufferCaptured: ((AVAudioPCMBuffer) -> Void)?
    var onError: ((Error) -> Void)?
    
    private let audioEngine = AVAudioEngine()
    
    init() {}
    
    func start() throws {
        guard !isRunning else { return }
        NSLog("🎙️ [PhoneBuiltinAudioSource] 启动 iPhone 内置麦克风音频采集...")
        
        let audioSession = AVAudioSession.sharedInstance()
        // 核心保障：仅使用 .duckOthers，严格禁止蓝牙 HFP 电话协议，保持高清录音
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.onAudioBufferCaptured?(buffer)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        self.isRunning = true
        NSLog("✅ [PhoneBuiltinAudioSource] iPhone 内置麦克风已就绪 (格式: %@)", recordingFormat.description)
    }
    
    func stop() {
        guard isRunning else { return }
        NSLog("🛑 [PhoneBuiltinAudioSource] 停止 iPhone 内置麦克风采集")
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        self.isRunning = false
    }
}

// MARK: - 2. 眼镜蓝牙麦克风输入源 (GlassesBLEAudioSource)
final class GlassesBLEAudioSource: AudioInputSourceProtocol {
    let sourceType: AudioSourceType = .glassesMic
    private(set) var isRunning: Bool = false
    
    var onAudioBufferCaptured: ((AVAudioPCMBuffer) -> Void)?
    var onError: ((Error) -> Void)?
    
    private let decoder: G2LC3AudioDecoder?
    weak var bleManager: BLEManager?
    
    init(bleManager: BLEManager? = nil) {
        self.bleManager = bleManager ?? BLEManager.shared
        self.decoder = G2LC3AudioDecoder()
        if self.decoder == nil {
            NSLog("❌ [GlassesBLEAudioSource] 初始化 G2LC3AudioDecoder 失败")
        }
    }
    
    func start() throws {
        guard !isRunning else { return }
        let ble = bleManager ?? BLEManager.shared
        self.bleManager = ble
        
        guard ble.isConnected else {
            throw NSError(domain: "GlassesBLEAudioSource", code: -2, userInfo: [NSLocalizedDescriptionKey: "Even G2 眼镜尚未连接蓝牙"])
        }
        
        guard let decoder = decoder else {
            throw NSError(domain: "GlassesBLEAudioSource", code: -3, userInfo: [NSLocalizedDescriptionKey: "LC3 解码器未就绪"])
        }
        
        NSLog("👓 [GlassesBLEAudioSource] 启动 Even G2 眼镜蓝牙麦克风流...")
        decoder.reset()
        
        // 绑定 6402 音频数据包接收回调
        ble.onAudioPacketReceived = { [weak self] packetData in
            guard let self = self, self.isRunning else { return }
            
            // 收到 205 字节 LC3 压缩包 -> 解码为 800 个采样的 AVAudioPCMBuffer (50ms @ 16kHz)
            if let pcmBuffer = decoder.decodePacket(packetData) {
                self.onAudioBufferCaptured?(pcmBuffer)
            } else {
                NSLog("⚠️ [GlassesBLEAudioSource] LC3 解码失败或数据包异常 (长度: %ld)", packetData.count)
            }
        }
        
        // 发送启动指令并监听 6402
        ble.startGlassesMicrophone()
        self.isRunning = true
        NSLog("✅ [GlassesBLEAudioSource] 眼镜蓝牙麦克风采集已开启 (Service: 6450, Char: 6402)")
    }
    
    func stop() {
        guard isRunning else { return }
        NSLog("🛑 [GlassesBLEAudioSource] 停止 Even G2 眼镜蓝牙麦克风流")
        let ble = bleManager ?? BLEManager.shared
        ble.onAudioPacketReceived = nil
        ble.stopGlassesMicrophone()
        decoder?.reset()
        self.isRunning = false
    }
}
