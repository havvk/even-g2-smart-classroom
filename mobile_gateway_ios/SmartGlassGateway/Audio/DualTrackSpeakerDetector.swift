import Foundation
import AVFoundation
import Combine

/// 说话人身份枚举
enum SpeakerIdentity: String, CaseIterable, Identifiable {
    case me = "我方"
    case guest = "对方"
    case unknown = "未定"
    
    var id: String { rawValue }
    
    /// 字幕前缀标识
    var prefix: String {
        switch self {
        case .me: return "[我] "
        case .guest: return "[对方] "
        case .unknown: return ""
        }
    }
}

/// Even G2 双轨麦克风能量说话人判别器 (Dual-Track Energy Gate Diarization)
///
/// 物理原理:
/// - 佩戴者讲话: 近场下颌振动，GlassesMic (LC3) 能量暴增 (RMS 极高);
/// - 对方讲话: 空气远场衰减，PhoneMic 能量显著高于 GlassesMic;
/// - 纯标量数学比对，零冷启动开销，抗噪能力极强。
class DualTrackSpeakerDetector: ObservableObject {
    
    // MARK: - Published State
    
    /// 当前判定的说话人身份
    @Published var currentSpeaker: SpeakerIdentity = .unknown
    
    /// 眼镜端实时音频归一化能量 (0.0 ~ 1.0)
    @Published var glassesLevel: Float = 0.0
    
    /// 手机端实时音频归一化能量 (0.0 ~ 1.0)
    @Published var phoneLevel: Float = 0.0
    
    /// 能量比率 (Glasses RMS / Phone RMS)
    @Published var energyRatio: Float = 1.0
    
    // MARK: - Threshold Configuration
    
    /// 手机桌面麦克风远场灵敏度补偿因子 (默认 2.5 倍，补偿平方反比声学衰减与原生无 AGC 差异)
    var phoneSensitivityMultiplier: Float = 2.5
    
    /// 判定为自己的比率门限 (GlassesMic 能量为 PhoneMic 的 2.0 倍以上)
    var selfRatioThreshold: Float = 2.0
    
    /// 判定为对方的比率门限 (GlassesMic 能量不足 PhoneMic 的 0.8 倍)
    var guestRatioThreshold: Float = 0.8
    
    /// 静音能量底噪阈值
    var silenceThreshold: Float = 0.015
    
    // MARK: - Private State
    
    private var lastGlassesRMS: Float = 0.0
    private var lastPhoneRMS: Float = 0.0
    
    /// 3 帧平滑判定窗口，防止突发爆破音抖动
    private var decisionHistory: [SpeakerIdentity] = []
    private let historyWindowSize = 3
    
    // MARK: - Singleton
    
    static let shared = DualTrackSpeakerDetector()
    
    init() {}
    
    // MARK: - Audio Buffer Feed
    
    /// 喂入眼镜端音频采样 Buffer (16kHz PCM)
    func feedGlassesAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        let rms = Self.calculateRMS(buffer: buffer)
        self.lastGlassesRMS = rms
        
        DispatchQueue.main.async {
            self.glassesLevel = min(1.0, rms * 15.0)
            self.evaluateCurrentSpeaker()
        }
    }
    
    /// 喂入手机端音频采样 Buffer (48kHz/16kHz PCM)
    func feedPhoneAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        let rawRms = Self.calculateRMS(buffer: buffer)
        // 核心：应用 2.5x 远场声学增益补偿，真实还原高灵敏度手机麦克风电平
        let calibratedRms = rawRms * phoneSensitivityMultiplier
        self.lastPhoneRMS = calibratedRms
        
        DispatchQueue.main.async {
            self.phoneLevel = min(1.0, calibratedRms * 15.0)
            self.evaluateCurrentSpeaker()
        }
    }
    
    // MARK: - RMS Calculation
    
    /// 计算 PCM Buffer 的短时均方根能量 (Root Mean Square)
    static func calculateRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0.0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0.0 }
        
        var sumSquares: Float = 0.0
        for i in 0..<frameLength {
            let sample = channelData[i]
            sumSquares += sample * sample
        }
        
        return sqrt(sumSquares / Float(frameLength))
    }
    
    // MARK: - Diarization Evaluation
    
    private func evaluateCurrentSpeaker() {
        let gRMS = lastGlassesRMS
        let pRMS = lastPhoneRMS
        
        // 1. 静音门禁
        if gRMS < silenceThreshold && pRMS < silenceThreshold {
            return
        }
        
        // 2. 比率判定
        let epsilon: Float = 0.0001
        let ratio = (gRMS + epsilon) / (pRMS + epsilon)
        self.energyRatio = ratio
        
        let candidate: SpeakerIdentity
        if ratio >= selfRatioThreshold {
            candidate = .me
        } else if ratio <= guestRatioThreshold {
            candidate = .guest
        } else {
            candidate = currentSpeaker // 维持在滞后区间 (Hysteresis)
        }
        
        // 3. 历史平滑滤波
        decisionHistory.append(candidate)
        if decisionHistory.count > historyWindowSize {
            decisionHistory.removeFirst()
        }
        
        let meCount = decisionHistory.filter { $0 == .me }.count
        let guestCount = decisionHistory.filter { $0 == .guest }.count
        
        if meCount >= 2 {
            self.currentSpeaker = .me
        } else if guestCount >= 2 {
            self.currentSpeaker = .guest
        }
    }
    
    // MARK: - Reset
    
    func reset() {
        DispatchQueue.main.async {
            self.currentSpeaker = .unknown
            self.glassesLevel = 0.0
            self.phoneLevel = 0.0
            self.energyRatio = 1.0
            self.decisionHistory.removeAll()
            self.lastGlassesRMS = 0.0
            self.lastPhoneRMS = 0.0
        }
    }
}
