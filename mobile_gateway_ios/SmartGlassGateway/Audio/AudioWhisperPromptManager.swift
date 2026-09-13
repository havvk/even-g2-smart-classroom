//
//  AudioWhisperPromptManager.swift
//  SmartGlassGateway
//
//  Created by Antigravity on 2026-09-13.
//

import Foundation
import AVFoundation
import Combine

/// 苹果系统官方发音人规范模型 (与 iOS 系统设置截图 1:1 严格对齐，零音译，纯英文/官方原名)
struct SystemVoiceItem: Identifiable, Equatable {
    let id: String                          // 唯一标识, 如 "siri-cn-2", "han-premium"
    let name: String                        // 截屏真实名称: "Voice 1", "Voice 2", "Han (Premium)"
    let section: String                     // 分组名称: "Siri (China mainland)", "Siri (Taiwan)", "Premium Voices"
    let detail: String                      // 容量与性别说明: "Female · 252 MB", "Male · 279 MB"
    let displayTitle: String                // 按钮与列表展示名: "Voice 2 (Male) · Siri"
    let candidateIdentifiers: [String]      // 系统底层标识符优先级
    let fallbackGender: AVSpeechSynthesisVoiceGender
    let fallbackLanguage: String
    
    static func == (lhs: SystemVoiceItem, rhs: SystemVoiceItem) -> Bool {
        lhs.id == rhs.id
    }
}

/// AI 提示耳机私密耳语播报管理器 (Audio Whisper Prompt Manager)
/// - 自动感知耳机硬件状态 (AirPods / 蓝牙耳机 / 有线耳机)
/// - 戴上耳机自动激活播报开关，取下/拔出耳机自动关闭静音
/// - 坚决禁止扬声器外放，消除社交暴露与麦克风声学自激啸叫
final class AudioWhisperPromptManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = AudioWhisperPromptManager()
    
    // MARK: - Published 状态
    
    /// 耳机硬件物理连接状态
    @Published private(set) var isHeadphonesConnected: Bool = false
    
    /// 耳机设备名称提示 (如 "AirPods Pro", "蓝牙耳机")
    @Published private(set) var connectedHeadphoneName: String = "未连接耳机"
    
    /// 播放 AI 提示的主开关 (佩戴耳机时默认自动打开，拔出耳机自动关闭，同时支持用户手动切换)
    @Published var isAudioPromptEnabled: Bool = false
    
    /// 当前优选的发音人品质与名称描述 (用于 UI 展示)
    @Published private(set) var activeVoiceDescription: String = "Voice 2 (男声)"
    
    /// 苹果官方 Siri 大陆普通话预设 (Voice 1~4)
    @Published private(set) var siriMainlandVoicesList: [SystemVoiceItem] = []
    
    /// 苹果官方 Siri 台湾普通话预设 (Voice 1~2)
    @Published private(set) var siriTaiwanVoicesList: [SystemVoiceItem] = []
    
    /// 苹果官方 Siri 香港粤语预设 (浩贤 / 嘉欣)
    @Published private(set) var siriHongKongVoicesList: [SystemVoiceItem] = []
    
    /// 真机是否已下载香港 Siri 离线包
    @Published private(set) var isHKSiriDownloaded: Bool = false
    
    /// 苹果官方高级神经网络发音人列表 (Han, Lilian, Yu-shu, Li-mu, Yue, Yun, Meijia, Fangfang, Lili, Sinji, Fung, Wing)
    @Published private(set) var officialPremiumVoicesList: [SystemVoiceItem] = []
    
    /// 苹果官方 Siri 英语全系列发音人列表 (美式 Voice 1~5, 英式 Voice 1~4, 澳式 Voice 1~4, 爱尔兰 Voice 1~2, 南非 Voice 1~2)
    @Published private(set) var siriEnglishVoicesList: [SystemVoiceItem] = []
    
    /// 英语官方 Premium 旗舰人声列表 (Ava, Zoe, Jamie, Serena, Karen, Lee, Matilda, Isha 及动态扫描声音)
    @Published private(set) var premiumEnglishVoicesList: [SystemVoiceItem] = []
    
    /// 韩语官方 Premium 旗舰人声列表 (Yuna, Jian 及动态扫描声音)
    @Published private(set) var premiumKoreanVoicesList: [SystemVoiceItem] = []
    
    /// 苹果官方 Siri 韩语发音人列表 (Jinsoo 男声 / Minji 女声)
    @Published private(set) var siriKoreanVoicesList: [SystemVoiceItem] = []
    
    /// 苹果官方 Siri 日语发音人列表 (Hiro 男声 / Sakura 女声 · 官方仅此类为 Premium 神经网络级)
    @Published private(set) var siriJapaneseVoicesList: [SystemVoiceItem] = []
    
    /// 苹果官方 Siri 国际多语种预设 (保留字段)
    @Published private(set) var siriInternationalVoicesList: [SystemVoiceItem] = []
    
    /// 当前选中的预设 ID (默认对准用户当前系统勾选的 Voice 2)
    @Published private(set) var selectedVoiceItemId: String = "siri-cn-2"
    
    /// 兼容存量字段
    @Published private(set) var selectedPresetId: String = "zh-CN-voice-2"
    @Published private(set) var selectedVoiceIdentifier: String = ""
    @Published private(set) var allScannedChineseVoices: [AVSpeechSynthesisVoice] = []
    @Published private(set) var siriVoices: [AVSpeechSynthesisVoice] = []
    @Published private(set) var officialPremiumVoices: [AVSpeechSynthesisVoice] = []
    @Published private(set) var allPremiumVoices: [AVSpeechSynthesisVoice] = []
    @Published private(set) var siriMainlandVoices: [AVSpeechSynthesisVoice] = []
    @Published private(set) var siriTaiwanVoices: [AVSpeechSynthesisVoice] = []
    @Published private(set) var systemVoices: [AVSpeechSynthesisVoice] = []
    @Published private(set) var availableVoices: [AVSpeechSynthesisVoice] = []
    
    private let itemStorageKey = "SelectedAudioWhisperSystemVoiceItemId"
    private let presetStorageKey = "SelectedAudioWhisperPresetId"
    private let voiceStorageKey = "SelectedAudioWhisperVoiceIdentifier"
    
    // MARK: - TTS 语音合成器
    private var speechSynthesizer = AVSpeechSynthesizer()
    @Published private(set) var chineseVoice: AVSpeechSynthesisVoice?
    
    /// 防抖与内容去重锁：防止短时间内高频调用或相同文本重入导致 0.38s 处音频流被强行掐断
    private var lastSpeakTime: DispatchTime = DispatchTime(uptimeNanoseconds: 0)
    private var lastSpeakText: String = ""
    
    /// 防抖工作项：防止快速连点切换发音人时产生多路并发试听竞态
    private var pendingSamplePromptWorkItem: DispatchWorkItem?
    
    /// 是否开启“离线预合成后整句播放”模式（先完全生成完毕，再由 AVAudioPlayer 完整播放，彻底消除边算边播的推流毛刺）
    private let preSynthStorageKey = "AudioWhisperPreSynthesizeModeEnabled"
    @Published var isPreSynthesizeModeEnabled: Bool = (UserDefaults.standard.object(forKey: "AudioWhisperPreSynthesizeModeEnabled") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(isPreSynthesizeModeEnabled, forKey: preSynthStorageKey)
            NSLog("⚙️ [AudioWhisper] 切换预合成整句播放模式: %@", isPreSynthesizeModeEnabled ? "开启 (防抖缓冲)" : "关闭 (原生流式)")
        }
    }
    
    /// 离线完整音频播放器 (用于零 TTS 对照与整句预合成播放)
    private var audioPlayer: AVAudioPlayer?
    
    /// 预合成专用的 AVSpeechSynthesizer（类级别强引用，防止异步 write 过程中被 ARC 销毁导致无法发声）
    private var preSynthesizer: AVSpeechSynthesizer?
    
    /// 音频会话是否已激活就绪 (防止每次播报反复调用 setActive(true) 导致蓝牙流中断破音)
    private var isAudioSessionConfigured: Bool = false
    
    /// 当前选中的发音人是否已在真机安装就绪
    var isCurrentVoiceInstalled: Bool {
        return chineseVoice != nil
    }
    
    override init() {
        super.init()
        speechSynthesizer.delegate = self
        
        // 构造系统设置截图 1:1 对标发音人清单
        setupSystemVoiceItems()
        refreshActiveVoice()
        
        // 核心：提前预配置并激活 AudioSession，让 App 在未点击“开启对话”前即可实时感知耳机插拔
        ensureAudioSessionActive()
        
        // 注册监听系统音频路由变更广播 (耳机插入/拔出/蓝牙断连)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        
        // 注册监听音频打断通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        
        NSLog("🎧 [AudioWhisper] AudioWhisperPromptManager 初始化完毕")
    }
    
    // MARK: - 轻量控制台日志 (零磁盘 I/O 阻塞)
    
    func appendDiagLog(_ tag: String, _ message: String) {
        NSLog("🔬 [AudioDiag] [%@] %@", tag, message)
    }
    
    @objc private func handleAudioInterruption(_ notification: Notification) {
        let typeVal = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 999
        appendDiagLog("INTERRUPT", "收到音频打断广播: type=\(typeVal)")
    }
    
    /// 尝试调用底层系统内部通道获取包括 Siri 在内的全量发音人 (突破第三方公开 API 剥离 Siri 的限制)
    static func fetchAllVoicesIncludingSiri() -> [AVSpeechSynthesisVoice] {
        let sel = NSSelectorFromString("_speechVoicesIncludingSiri")
        if AVSpeechSynthesisVoice.responds(to: sel),
           let unmanaged = AVSpeechSynthesisVoice.perform(sel),
           let list = unmanaged.takeUnretainedValue() as? [AVSpeechSynthesisVoice],
           !list.isEmpty {
            return list
        }
        return AVSpeechSynthesisVoice.speechVoices()
    }
    
    /// 尝试直接从系统内部完整音色列表精确按 ID 加载语音 (突破第三方公开 API 剥离 Siri 的限制)
    static func loadVoiceWithIdentifier(_ identifier: String) -> AVSpeechSynthesisVoice? {
        // 1. 尝试内部通道 _voiceFromInternalVoiceListWithIdentifier:
        let internalSel = NSSelectorFromString("_voiceFromInternalVoiceListWithIdentifier:")
        if AVSpeechSynthesisVoice.responds(to: internalSel),
           let unmanaged = AVSpeechSynthesisVoice.perform(internalSel, with: identifier),
           let voice = unmanaged.takeUnretainedValue() as? AVSpeechSynthesisVoice {
            return voice
        }
        
        // 2. 尝试从全量内部列表 (_speechVoicesIncludingSiri) 中查找
        let allWithSiri = fetchAllVoicesIncludingSiri()
        if let matched = allWithSiri.first(where: { $0.identifier.lowercased() == identifier.lowercased() }) {
            return matched
        }
        
        // 3. 公开 API 兜底
        return AVSpeechSynthesisVoice(identifier: identifier)
    }
    
    /// 无过滤转储全量系统发音人到本地沙盒 (包含 Siri 内部发音人)
    private func dumpAllInstalledVoicesToDisk() {
        let all = Self.fetchAllVoicesIncludingSiri()
        var records: [[String: Any]] = []
        for v in all {
            records.append([
                "identifier": v.identifier,
                "name": v.name,
                "language": v.language,
                "quality": v.quality.rawValue,
                "gender": v.gender.rawValue
            ])
        }
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let fileURL = docs.appendingPathComponent("voices_dump.json")
            if let data = try? JSONSerialization.data(withJSONObject: records, options: .prettyPrinted) {
                try? data.write(to: fileURL)
                NSLog("🎙️ [DUMP] 已成功写入 %ld 个系统发音人 (含Siri) 至: %@", all.count, fileURL.path)
            }
        }
    }
    
    /// 深入探测真机所有能被 AVSpeechSynthesisVoice 实例化的语音变体并输出沙盒
    private func probeAllAvailableVoices() {
        var discovered: [[String: Any]] = []
        var testedIds = Set<String>()
        
        let prefixes = [
            "com.apple.ttsbundle.gryphon-neural_",
            "com.apple.ttsbundle.gryphon_",
            "com.apple.ttsbundle.siri_",
            "com.apple.speech.synthesis.voice.custom.siri.",
            "com.apple.voice.premium.",
            "com.apple.voice.enhanced.",
            "com.apple.voice.compact."
        ]
        let suffixes = ["_premium", "_compact", "_enhanced", ""]
        let names = [
            "linfei", "Linfei", "limu", "Limu", "li-mu", "Li-mu",
            "zh-CN-C", "zh-CN-D", "chenghan", "Chenghan", "shufen", "Shufen",
            "hoyin", "Hoyin", "kayan", "Kayan", "Yu-shu", "yu-shu",
            "Han", "han", "Lilian", "lilian", "Yue", "yue", "Yun", "yun",
            "Meijia", "meijia", "Panpan", "panpan", "Fangfang", "fangfang",
            "Lili", "lili", "Tingting", "tingting"
        ]
        let locales = ["zh-CN", "zh-TW", "zh-HK", "zh_CN", "zh_TW", "zh_HK"]
        
        for pre in prefixes {
            for name in names {
                for loc in locales {
                    for suf in suffixes {
                        testedIds.insert("\(pre)\(name)_\(loc)\(suf)")
                    }
                }
            }
        }
        
        for num in 1...4 {
            for loc in locales {
                testedIds.insert("com.apple.ttsbundle.siri_Voice\(num)_\(loc)_premium")
                testedIds.insert("com.apple.ttsbundle.gryphon-neural_Voice\(num)_\(loc)_premium")
                testedIds.insert("com.apple.speech.synthesis.voice.custom.siri.\(num)")
                testedIds.insert("com.apple.siri.tts.voice.\(loc).voice\(num).premium")
            }
        }
        
        for item in self.allConfiguredItems {
            for c in item.candidateIdentifiers {
                testedIds.insert(c)
            }
        }
        
        for id in testedIds {
            if let v = AVSpeechSynthesisVoice(identifier: id) {
                discovered.append([
                    "identifier": v.identifier,
                    "name": v.name,
                    "language": v.language,
                    "quality": v.quality.rawValue,
                    "gender": v.gender.rawValue,
                    "testedId": id
                ])
                NSLog("🔬 [PROBE-HIT] 探测成功命中语音: [%@] -> ID: %@ (Name: %@, Quality: %ld)",
                      id, v.identifier, v.name, v.quality.rawValue)
            }
        }
        
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let fileURL = docs.appendingPathComponent("voice_probe_results.json")
            let payload: [String: Any] = [
                "testedTotal": testedIds.count,
                "discoveredCount": discovered.count,
                "discovered": discovered
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) {
                try? data.write(to: fileURL)
                NSLog("🔬 [AudioWhisper] 探测完成: 共测试 %ld 个ID，成功捕获 %ld 个可用语音", testedIds.count, discovered.count)
            }
        }
    }
    
    // MARK: - 发音人严密判定与分类
    
    /// 地区枚举
    enum VoiceRegion: String {
        case mainland = "大陆"
        case taiwan = "台湾"
        case hongkong = "香港"
        case other = "其他"
    }
    
    /// 严格语言准入：严禁任何非中文（en, ja, de 等）声音混入！
    static func isStrictChineseVoice(_ voice: AVSpeechSynthesisVoice) -> Bool {
        let lang = voice.language.lowercased()
        let idLower = voice.identifier.lowercased()
        
        // 1. 语言代码必须是中文 (zh-CN, zh-TW, zh-HK, zh-Hans, zh-Hant, cmn, yue 等)
        if lang.hasPrefix("zh") || lang.hasPrefix("cmn") || lang.hasPrefix("yue") {
            return true
        }
        
        // 2. 标识符中明确带有中文语言标签
        if idLower.contains("zh-cn") || idLower.contains("zh_cn") ||
           idLower.contains("zh-tw") || idLower.contains("zh_tw") ||
           idLower.contains("zh-hk") || idLower.contains("zh_hk") ||
           idLower.contains("zh-hans") || idLower.contains("zh-hant") {
            return true
        }
        
        return false
    }
    
    /// 判断发音人真实地区归属 (大陆 / 台湾 / 香港 / 其他)
    static func detectRegion(for voice: AVSpeechSynthesisVoice) -> VoiceRegion {
        let lang = voice.language.lowercased()
        let idLower = voice.identifier.lowercased()
        
        if lang.contains("tw") || lang.contains("hant") || idLower.contains("zh-tw") || idLower.contains("zh_tw") || idLower.contains("zh-hant") {
            return .taiwan
        } else if lang.contains("hk") || lang.contains("yue") || idLower.contains("zh-hk") || idLower.contains("zh_hk") || idLower.contains("yue") {
            return .hongkong
        } else if lang.contains("cn") || lang.contains("hans") || idLower.contains("zh-cn") || idLower.contains("zh_cn") || idLower.contains("zh-hans") || lang == "zh" {
            return .mainland
        }
        return .other
    }
    
    /// 判断是否为真正的苹果 Siri 原生神经发音人 (严禁将婷婷、美佳等传统具名发音人误判为 Siri)
    static func isNativeSiriVoice(_ voice: AVSpeechSynthesisVoice) -> Bool {
        guard isStrictChineseVoice(voice) else { return false }
        
        let idLower = voice.identifier.lowercased()
        let name = voice.name
        let nameLower = name.lowercased()
        
        // 1. 排除传统具名人声 (婷婷、美佳、冠龙、大宝、莉莉、机械音等)
        let namedVoices = ["tingting", "meijia", "guanlong", "dabao", "sinji", "lili", "eloquence", "eddy", "flo", "grandma", "grandpa", "reed", "rocko", "sandy", "shelley"]
        for named in namedVoices {
            if idLower.contains(named) || nameLower.contains(named) {
                // 除非 identifier 中明确包含 .siri. 且不包含 compact
                if !idLower.contains("siri") {
                    return false
                }
            }
        }
        
        // 2. 排除明确的传统机械音
        if idLower.contains("voice.compact.") && !idLower.contains("siri") { return false }
        if idLower.contains("voice.super-compact.") && !idLower.contains("siri") { return false }
        
        // 3. 命中 Siri 专属特征：
        // (A) identifier 明确包含 siri
        if idLower.contains("siri") {
            return true
        }
        // (B) 名字直接采用苹果 Siri 专属编号规范 ("声音 1"~"声音 4" / "聲音 1"~"聲音 2" / "Voice 1"~"Voice 4")
        if name.contains("声音") || name.contains("聲音") || nameLower.contains("voice") {
            return true
        }
        // (C) 苹果 Gryphon 神经语音引擎
        if idLower.contains("gryphon-neural") {
            return true
        }
        
        return false
    }
    
    /// 判断是否为任何语种的苹果 Siri 专属发音人 (通用规则，不限语言)
    static func isAnySiriVoice(_ voice: AVSpeechSynthesisVoice) -> Bool {
        let idLower = voice.identifier.lowercased()
        let nameLower = voice.name.lowercased()
        if idLower.contains("siri") || idLower.contains("gryphon-neural") || idLower.contains("gryphon_") {
            return true
        }
        if nameLower.hasPrefix("voice ") || nameLower.hasPrefix("声音 ") || nameLower.hasPrefix("聲音 ") {
            return true
        }
        return false
    }
    
    /// 严格判断是否为苹果最高品质 Premium (高级神经网络) 版语音
    static func isPremiumVoice(_ voice: AVSpeechSynthesisVoice) -> Bool {
        let idLower = voice.identifier.lowercased()
        let nameLower = voice.name.lowercased()
        
        // 彻底排除所有普通压缩版与机械音
        if idLower.contains("compact") || idLower.contains("eloquence") {
            return false
        }
        
        // 1. 系统枚举音质为 premium (rawValue == 3 或 .premium)
        if voice.quality == .premium {
            return true
        }
        
        // 2. identifier 明确带有 premium (如 com.apple.ttsbundle.siri_Yu-shu_zh-CN_premium)
        if idLower.contains("premium") {
            return true
        }
        
        // 3. 名称明确带有 Premium
        if nameLower.contains("premium") {
            return true
        }
        
        return false
    }
    
    // MARK: - 苹果官方发音人自我介绍与名称映射 (严格按苹果 TTS 真实发音自介与 Bundle ID 提取，杜绝随意音译)
    static let officialVoiceIntroMap: [String: String] = [
        "com.apple.voice.premium.zh-CN.Yue": "月",
        "com.apple.voice.premium.zh-CN.Han": "瀚",
        "com.apple.voice.premium.zh-CN.Lilian": "黎潋",
        "com.apple.voice.premium.zh-CN.Yun": "韵",
        "com.apple.voice.premium.zh-TW.Meijia": "美佳",
        "com.apple.voice.premium.zh-HK.Sinji": "善怡",
        "com.apple.voice.premium.zh-CN-u-sd-cnsc.Fangfang": "盼盼",
        "com.apple.voice.premium.zh-CN.Lili": "莉莉",
        "com.apple.ttsbundle.siri_Yu-shu_zh-CN_premium": "语舒",
        "com.apple.ttsbundle.siri_Li-mu_zh-CN_premium": "李牧",
        "com.apple.ttsbundle.gryphon-neural_linfei_zh-CN_premium": "林菲",
        "com.apple.ttsbundle.gryphon-neural_limu_zh-CN_premium": "李牧",
        "com.apple.ttsbundle.siri_shanshan_zh-CN_premium": "珊珊",
        "com.apple.ttsbundle.gryphon-neural_shanshan_zh-CN_premium": "珊珊",
        "com.apple.ttsbundle.siri_bolin_zh-CN_premium": "柏林",
        "com.apple.ttsbundle.gryphon-neural_bolin_zh-CN_premium": "柏林",
        "com.apple.ttsbundle.gryphon-neural_shufen_zh-TW_premium": "淑芬",
        "com.apple.ttsbundle.gryphon-neural_chenghan_zh-TW_premium": "成翰",
        "com.apple.ttsbundle.gryphon-neural_hoyin_zh-HK_premium": "浩贤",
        "com.apple.ttsbundle.gryphon-neural_kayan_zh-HK_premium": "嘉欣",
        "com.apple.voice.premium.zh-HK.Fung": "峰",
        "com.apple.voice.premium.zh-HK.Wing": "颖",
        "com.apple.voice.premium.en-US.Ava": "Ava",
        "com.apple.voice.premium.en-US.Zoe": "Zoe",
        "com.apple.voice.premium.en-GB.Malcolm": "Jamie",
        "com.apple.voice.premium.en-GB.Serena": "Serena",
        "com.apple.voice.premium.en-AU.Karen": "Karen",
        "com.apple.voice.premium.en-AU.Lee": "Lee",
        "com.apple.voice.premium.en-AU.Matilda": "Matilda",
        "com.apple.voice.premium.en-IN.Isha": "Isha",
        "com.apple.voice.premium.ko-KR.Yuna": "Yuna",
        "com.apple.voice.premium.ko-KR.Jina": "Jian",
        "com.apple.voice.premium.ko-KR.Jian": "Jian",
        "com.apple.ttsbundle.gryphon-neural_jinsoo_ko-KR_premium": "Jinsoo",
        "com.apple.siri.natural.jinsoo": "Jinsoo",
        "com.apple.siri.natural.minji": "Minji",
        "com.apple.ttsbundle.gryphon-neural_minji_ko-KR_premium": "Minji",
        "com.apple.ttsbundle.gryphon-neural_hiro_ja-JP_premium": "Hiro",
        "com.apple.ttsbundle.gryphon-neural_sakura_ja-JP_premium": "Sakura",
        "com.apple.siri.natural.hiro": "Hiro",
        "com.apple.siri.natural.sakura": "Sakura"
    ]
    
    /// 从发音人中精准提取官方真实中文名称
    static func extractOfficialVoiceName(for voice: AVSpeechSynthesisVoice) -> String {
        let id = voice.identifier
        if let exact = officialVoiceIntroMap[id] {
            return exact
        }
        for (key, val) in officialVoiceIntroMap {
            if id.contains(key) || key.contains(id) {
                return val
            }
        }
        let pure = voice.name
            .replacingOccurrences(of: " (Premium)", with: "")
            .replacingOccurrences(of: " (Enhanced)", with: "")
            .trimmingCharacters(in: .whitespaces)
        let fallbackMap: [String: String] = [
            "Yue": "月",
            "Han": "瀚",
            "Lilian": "黎潋",
            "Yun": "韵",
            "Meijia": "美佳",
            "Sinji": "善怡",
            "Fangfang": "盼盼",
            "Panpan": "盼盼",
            "Lili": "莉莉",
            "Tiantian": "田田",
            "Binbin": "彬彬",
            "Tingting": "婷婷",
            "Linfei": "林菲",
            "Limu": "李牧",
            "Shanshan": "珊珊",
            "Bolin": "柏林",
            "Shufen": "淑芬",
            "Chenghan": "成翰",
            "Hoyin": "浩贤",
            "Kayan": "嘉欣",
            "Fung": "峰",
            "Wing": "颖",
            "Ava": "Ava",
            "Zoe": "Zoe",
            "Malcolm": "Jamie",
            "Jamie": "Jamie",
            "Serena": "Serena",
            "Karen": "Karen",
            "Lee": "Lee",
            "Matilda": "Matilda",
            "Isha": "Isha",
            "Yuna": "Yuna",
            "Jina": "Jian",
            "Jian": "Jian",
            "Jinsoo": "Jinsoo",
            "Minji": "Minji",
            "Hiro": "Hiro",
            "Sakura": "Sakura"
        ]
        return fallbackMap[pure] ?? pure
    }
    
    /// 格式化发音人展示标题
    func displayTitle(for voice: AVSpeechSynthesisVoice) -> String {
        let officialName = Self.extractOfficialVoiceName(for: voice)
        if officialName != voice.name {
            return "\(officialName) (\(voice.name))"
        }
        return voice.name
    }
    
    /// 获取发音人原始详细标识
    func rawTitle(for voice: AVSpeechSynthesisVoice) -> String {
        let idShort = voice.identifier.components(separatedBy: ".").last ?? voice.identifier
        return "\(displayTitle(for: voice)) [\(idShort)]"
    }
    
    // MARK: - 构建系统官方发音人清单 (对齐 iOS 设置截屏)
    
    /// 获取全部已配置的系统规范发音人列表 (含 Siri 大陆、台湾、香港、英语全系列、日语旗舰、韩语 Siri、中文 Premium、英语 Premium、韩语 Premium)
    var allConfiguredItems: [SystemVoiceItem] {
        return siriMainlandVoicesList +
               siriTaiwanVoicesList +
               siriHongKongVoicesList +
               siriEnglishVoicesList +
               siriJapaneseVoicesList +
               siriKoreanVoicesList +
               officialPremiumVoicesList +
               premiumEnglishVoicesList +
               premiumKoreanVoicesList +
               siriInternationalVoicesList
    }
    
    func setupSystemVoiceItems() {
        // 1. Siri 大陆普通话 (Voice 1~4)
        // 苹果官方内部真机实测 100% 存在的原生神经网络语音：
        // Voice 1 (男声 · 278.7 MB), Voice 2 (女声 · 292.4 MB), Voice 3 (男声 · 297.9 MB), Voice 4 (女声 · 299.5 MB)
        self.siriMainlandVoicesList = [
            SystemVoiceItem(
                id: "siri-cn-1",
                name: "Voice 1",
                section: "🎙️ Siri - Mandarin (China mainland)",
                detail: "Male · 278.7 MB",
                displayTitle: "Siri Voice 1",
                candidateIdentifiers: [
                    "com.apple.siri.natural.limu",
                    "com.apple.ttsbundle.gryphon-neural_limu_zh-CN_premium",
                    "com.apple.ttsbundle.gryphon_limu_zh-CN_premium",
                    "com.apple.speech.synthesis.voice.custom.siri.li-mu"
                ],
                fallbackGender: .male,
                fallbackLanguage: "zh-CN"
            ),
            SystemVoiceItem(
                id: "siri-cn-2",
                name: "Voice 2",
                section: "🎙️ Siri - Mandarin (China mainland)",
                detail: "Female · 292.4 MB",
                displayTitle: "Siri Voice 2",
                candidateIdentifiers: [
                    "com.apple.siri.natural.linfei",
                    "com.apple.ttsbundle.gryphon-neural_linfei_zh-CN_premium",
                    "com.apple.ttsbundle.gryphon_linfei_zh-CN_premium",
                    "com.apple.speech.synthesis.voice.custom.siri.linfei"
                ],
                fallbackGender: .female,
                fallbackLanguage: "zh-CN"
            ),
            SystemVoiceItem(
                id: "siri-cn-3",
                name: "Voice 3",
                section: "🎙️ Siri - Mandarin (China mainland)",
                detail: "Male · 297.9 MB",
                displayTitle: "Siri Voice 3",
                candidateIdentifiers: [
                    "com.apple.siri.natural.zh-CN-C",
                    "com.apple.ttsbundle.gryphon-neural_zh-CN-C_zh-CN_premium",
                    "com.apple.ttsbundle.gryphon_zh-CN-C_zh-CN_premium",
                    "com.apple.speech.synthesis.voice.custom.siri.zh-CN-C"
                ],
                fallbackGender: .male,
                fallbackLanguage: "zh-CN"
            ),
            SystemVoiceItem(
                id: "siri-cn-4",
                name: "Voice 4",
                section: "🎙️ Siri - Mandarin (China mainland)",
                detail: "Female · 299.5 MB",
                displayTitle: "Siri Voice 4",
                candidateIdentifiers: [
                    "com.apple.siri.natural.zh-CN-D",
                    "com.apple.ttsbundle.gryphon-neural_zh-CN-D_zh-CN_premium",
                    "com.apple.ttsbundle.gryphon_zh-CN-D_zh-CN_premium",
                    "com.apple.speech.synthesis.voice.custom.siri.zh-CN-D"
                ],
                fallbackGender: .female,
                fallbackLanguage: "zh-CN"
            )
        ]
        
        // 2. Siri 台湾普通话 (Voice 1~2)
        // 苹果官方内部真机实测 100% 存在的原生神经网络语音：
        // Voice 1 (男声 · 91.1 MB), Voice 2 (女声 · 88.7 MB)
        self.siriTaiwanVoicesList = [
            SystemVoiceItem(
                id: "siri-tw-1",
                name: "Voice 1 (台湾)",
                section: "🇹🇼 Siri - Mandarin (Taiwan)",
                detail: "Male · 91.1 MB",
                displayTitle: "Siri 台湾 Voice 1",
                candidateIdentifiers: [
                    "com.apple.ttsbundle.gryphon-neural_chenghan_zh-TW_premium",
                    "com.apple.ttsbundle.gryphon_chenghan_zh-TW_premium",
                    "com.apple.speech.synthesis.voice.custom.siri.chenghan"
                ],
                fallbackGender: .male,
                fallbackLanguage: "zh-TW"
            ),
            SystemVoiceItem(
                id: "siri-tw-2",
                name: "Voice 2 (台湾)",
                section: "🇹🇼 Siri - Mandarin (Taiwan)",
                detail: "Female · 88.7 MB",
                displayTitle: "Siri 台湾 Voice 2",
                candidateIdentifiers: [
                    "com.apple.ttsbundle.gryphon-neural_shufen_zh-TW_premium",
                    "com.apple.ttsbundle.gryphon_shufen_zh-TW_premium",
                    "com.apple.speech.synthesis.voice.custom.siri.shufen"
                ],
                fallbackGender: .female,
                fallbackLanguage: "zh-TW"
            )
        ]
        
        // 3. Siri 香港粤语 (浩贤 / 嘉欣)
        self.siriHongKongVoicesList = [
            SystemVoiceItem(
                id: "siri-hk-1",
                name: "Voice 1 (浩贤 · 男声)",
                section: "🇭🇰 Siri - Cantonese (Hong Kong)",
                detail: "Male · 神经网络",
                displayTitle: "Siri 香港 Voice 1 (浩贤)",
                candidateIdentifiers: [
                    "com.apple.ttsbundle.gryphon-neural_hoyin_zh-HK_premium",
                    "com.apple.ttsbundle.gryphon-neural_Hoyin_zh-HK_premium",
                    "com.apple.siri.natural.hoyin"
                ],
                fallbackGender: .male,
                fallbackLanguage: "zh-HK"
            ),
            SystemVoiceItem(
                id: "siri-hk-2",
                name: "Voice 2 (嘉欣 · 女声)",
                section: "🇭🇰 Siri - Cantonese (Hong Kong)",
                detail: "Female · 神经网络",
                displayTitle: "Siri 香港 Voice 2 (嘉欣)",
                candidateIdentifiers: [
                    "com.apple.ttsbundle.gryphon-neural_kayan_zh-HK_premium",
                    "com.apple.ttsbundle.gryphon-neural_Kayan_zh-HK_premium",
                    "com.apple.siri.natural.kayan"
                ],
                fallbackGender: .female,
                fallbackLanguage: "zh-HK"
            )
        ]
        
        // 4. Siri 英语全量发音人 (美式 1~5, 英式 1~4, 澳式 1~4, 爱尔兰 1~2, 南非 1~2)
        self.siriEnglishVoicesList = [
            // 🇺🇸 美式英语 (English - United States)
            SystemVoiceItem(
                id: "siri-en-us-1",
                name: "Voice 1 (Aaron · 男声)",
                section: "🇺🇸 Siri - English (US)",
                detail: "Male · 神经网络",
                displayTitle: "Siri 美语 Voice 1 (Aaron)",
                candidateIdentifiers: [
                    "com.apple.siri.natural.aaron",
                    "com.apple.ttsbundle.gryphon-neural_aaron_en-US_premium",
                    "com.apple.ttsbundle.siri_Aaron_en-US_compact"
                ],
                fallbackGender: .male,
                fallbackLanguage: "en-US"
            ),
            SystemVoiceItem(
                id: "siri-en-us-2",
                name: "Voice 2 (Simone · 女声)",
                section: "🇺🇸 Siri - English (US)",
                detail: "Female · 神经网络",
                displayTitle: "Siri 美语 Voice 2 (Simone)",
                candidateIdentifiers: [
                    "com.apple.siri.natural.simone",
                    "com.apple.ttsbundle.gryphon-neural_simone_en-US_premium"
                ],
                fallbackGender: .female,
                fallbackLanguage: "en-US"
            ),
            SystemVoiceItem(
                id: "siri-en-us-3",
                name: "Voice 3 (Damon · 男声)",
                section: "🇺🇸 Siri - English (US)",
                detail: "Male · 神经网络",
                displayTitle: "Siri 美语 Voice 3 (Damon)",
                candidateIdentifiers: [
                    "com.apple.siri.natural.damon",
                    "com.apple.ttsbundle.gryphon-neural_damon_en-US_premium"
                ],
                fallbackGender: .male,
                fallbackLanguage: "en-US"
            ),
            SystemVoiceItem(
                id: "siri-en-us-4",
                name: "Voice 4 (Nora · 女声)",
                section: "🇺🇸 Siri - English (US)",
                detail: "Female · 神经网络",
                displayTitle: "Siri 美语 Voice 4 (Nora)",
                candidateIdentifiers: [
                    "com.apple.siri.natural.nora",
                    "com.apple.ttsbundle.gryphon-neural_nora_en-US_premium"
                ],
                fallbackGender: .female,
                fallbackLanguage: "en-US"
            ),
            SystemVoiceItem(
                id: "siri-en-us-5",
                name: "Voice 5 (Quinn · 中性)",
                section: "🇺🇸 Siri - English (US)",
                detail: "Neutral · 神经网络",
                displayTitle: "Siri 美语 Voice 5 (Quinn)",
                candidateIdentifiers: [
                    "com.apple.siri.natural.quinn",
                    "com.apple.ttsbundle.gryphon-neural_quinn_en-US_premium"
                ],
                fallbackGender: .unspecified,
                fallbackLanguage: "en-US"
            ),
            
            // 🇬🇧 英式英语 (English - United Kingdom)
            SystemVoiceItem(
                id: "siri-en-gb-1",
                name: "Voice 1 (Martha · 女声)",
                section: "🇬🇧 Siri - English (UK)",
                detail: "Female · 神经网络",
                displayTitle: "Siri 英音 Voice 1 (Martha)",
                candidateIdentifiers: [
                    "com.apple.siri.natural.martha",
                    "com.apple.ttsbundle.gryphon-neural_martha_en-GB_premium",
                    "com.apple.ttsbundle.siri_Martha_en-GB_compact"
                ],
                fallbackGender: .female,
                fallbackLanguage: "en-GB"
            ),
            SystemVoiceItem(
                id: "siri-en-gb-2",
                name: "Voice 2 (Arthur · 男声)",
                section: "🇬🇧 Siri - English (UK)",
                detail: "Male · 神经网络",
                displayTitle: "Siri 英音 Voice 2 (Arthur)",
                candidateIdentifiers: [
                    "com.apple.siri.natural.arthur",
                    "com.apple.ttsbundle.gryphon-neural_arthur_en-GB_premium",
                    "com.apple.ttsbundle.siri_Arthur_en-GB_compact"
                ],
                fallbackGender: .male,
                fallbackLanguage: "en-GB"
            ),
            SystemVoiceItem(
                id: "siri-en-gb-3",
                name: "Voice 3 (女声)",
                section: "🇬🇧 Siri - English (UK)",
                detail: "Female · 神经网络",
                displayTitle: "Siri 英音 Voice 3",
                candidateIdentifiers: [
                    "com.apple.siri.natural.en-GB-C",
                    "com.apple.ttsbundle.gryphon-neural_en-GB-C_en-GB_premium"
                ],
                fallbackGender: .female,
                fallbackLanguage: "en-GB"
            ),
            SystemVoiceItem(
                id: "siri-en-gb-4",
                name: "Voice 4 (男声)",
                section: "🇬🇧 Siri - English (UK)",
                detail: "Male · 神经网络",
                displayTitle: "Siri 英音 Voice 4",
                candidateIdentifiers: [
                    "com.apple.siri.natural.en-GB-D",
                    "com.apple.ttsbundle.gryphon-neural_en-GB-D_en-GB_premium"
                ],
                fallbackGender: .male,
                fallbackLanguage: "en-GB"
            ),
            
            // 🇦🇺 澳大利亚英语 (English - Australia)
            SystemVoiceItem(
                id: "siri-en-au-1",
                name: "Voice 1 (Gordon · 男声)",
                section: "🇦🇺 Siri - English (Australia)",
                detail: "Male · 神经网络",
                displayTitle: "Siri 澳音 Voice 1 (Gordon)",
                candidateIdentifiers: [
                    "com.apple.siri.natural.gordon",
                    "com.apple.ttsbundle.gryphon-neural_gordon_en-AU_premium",
                    "com.apple.ttsbundle.siri_Gordon_en-AU_compact"
                ],
                fallbackGender: .male,
                fallbackLanguage: "en-AU"
            ),
            SystemVoiceItem(
                id: "siri-en-au-2",
                name: "Voice 2 (Catherine · 女声)",
                section: "🇦🇺 Siri - English (Australia)",
                detail: "Female · 神经网络",
                displayTitle: "Siri 澳音 Voice 2 (Catherine)",
                candidateIdentifiers: [
                    "com.apple.siri.natural.catherine",
                    "com.apple.ttsbundle.gryphon-neural_catherine_en-AU_premium",
                    "com.apple.ttsbundle.siri_Catherine_en-AU_compact"
                ],
                fallbackGender: .female,
                fallbackLanguage: "en-AU"
            ),
            SystemVoiceItem(
                id: "siri-en-au-3",
                name: "Voice 3 (男声)",
                section: "🇦🇺 Siri - English (Australia)",
                detail: "Male · 神经网络",
                displayTitle: "Siri 澳音 Voice 3",
                candidateIdentifiers: [
                    "com.apple.siri.natural.en-AU-C",
                    "com.apple.ttsbundle.gryphon-neural_en-AU-C_en-AU_premium"
                ],
                fallbackGender: .male,
                fallbackLanguage: "en-AU"
            ),
            SystemVoiceItem(
                id: "siri-en-au-4",
                name: "Voice 4 (女声)",
                section: "🇦🇺 Siri - English (Australia)",
                detail: "Female · 神经网络",
                displayTitle: "Siri 澳音 Voice 4",
                candidateIdentifiers: [
                    "com.apple.siri.natural.en-AU-D",
                    "com.apple.ttsbundle.gryphon-neural_en-AU-D_en-AU_premium"
                ],
                fallbackGender: .female,
                fallbackLanguage: "en-AU"
            ),
            
            // 🇮🇪 爱尔兰英语 (English - Ireland)
            SystemVoiceItem(
                id: "siri-en-ie-1",
                name: "Voice 1 (Aidan · 男声)",
                section: "🇮🇪 Siri - English (Ireland)",
                detail: "Male · 神经网络",
                displayTitle: "Siri 爱尔兰 Voice 1 (Aidan)",
                candidateIdentifiers: [
                    "com.apple.siri.natural.aidan",
                    "com.apple.ttsbundle.gryphon-neural_aidan_en-IE_premium"
                ],
                fallbackGender: .male,
                fallbackLanguage: "en-IE"
            ),
            SystemVoiceItem(
                id: "siri-en-ie-2",
                name: "Voice 2 (Maeve · 女声)",
                section: "🇮🇪 Siri - English (Ireland)",
                detail: "Female · 神经网络",
                displayTitle: "Siri 爱尔兰 Voice 2 (Maeve)",
                candidateIdentifiers: [
                    "com.apple.siri.natural.maeve",
                    "com.apple.ttsbundle.gryphon-neural_maeve_en-IE_premium"
                ],
                fallbackGender: .female,
                fallbackLanguage: "en-IE"
            ),
            
            // 🇿🇦 南非英语 (English - South Africa)
            SystemVoiceItem(
                id: "siri-en-za-1",
                name: "Voice 1 (Xander · 男声)",
                section: "🇿🇦 Siri - English (South Africa)",
                detail: "Male · 神经网络",
                displayTitle: "Siri 南非 Voice 1 (Xander)",
                candidateIdentifiers: [
                    "com.apple.siri.natural.xander",
                    "com.apple.ttsbundle.gryphon-neural_xander_en-ZA_premium"
                ],
                fallbackGender: .male,
                fallbackLanguage: "en-ZA"
            ),
            SystemVoiceItem(
                id: "siri-en-za-2",
                name: "Voice 2 (Leona · 女声)",
                section: "🇿🇦 Siri - English (South Africa)",
                detail: "Female · 神经网络",
                displayTitle: "Siri 南非 Voice 2 (Leona)",
                candidateIdentifiers: [
                    "com.apple.siri.natural.leona",
                    "com.apple.ttsbundle.gryphon-neural_leona_en-ZA_premium"
                ],
                fallbackGender: .female,
                fallbackLanguage: "en-ZA"
            )
        ]
        
        // 5. 苹果官方 Premium 旗舰声音列表 (对标设置界面真实文件大小与音质)
        var premiumList: [SystemVoiceItem] = [
            SystemVoiceItem(
                id: "premium-han",
                name: "瀚 · Han",
                section: "🌟 Premium Voices",
                detail: "Male · 60.2 MB",
                displayTitle: "瀚 (Han)",
                candidateIdentifiers: [
                    "com.apple.voice.premium.zh-CN.Han",
                    "com.apple.voice.enhanced.zh-CN.Han"
                ],
                fallbackGender: .male,
                fallbackLanguage: "zh-CN"
            ),
            SystemVoiceItem(
                id: "premium-lilian",
                name: "黎潋 · Lilian",
                section: "🌟 Premium Voices",
                detail: "Female · 60.1 MB",
                displayTitle: "黎潋 (Lilian)",
                candidateIdentifiers: [
                    "com.apple.voice.premium.zh-CN.Lilian",
                    "com.apple.voice.enhanced.zh-CN.Lilian"
                ],
                fallbackGender: .female,
                fallbackLanguage: "zh-CN"
            ),
            SystemVoiceItem(
                id: "premium-yue",
                name: "月 · Yue",
                section: "🌟 Premium Voices",
                detail: "Female · 60.4 MB",
                displayTitle: "月 (Yue)",
                candidateIdentifiers: [
                    "com.apple.voice.premium.zh-CN.Yue"
                ],
                fallbackGender: .female,
                fallbackLanguage: "zh-CN"
            ),
            SystemVoiceItem(
                id: "premium-yun",
                name: "韵 · Yun",
                section: "🌟 Premium Voices",
                detail: "Female · 60.3 MB",
                displayTitle: "韵 (Yun)",
                candidateIdentifiers: [
                    "com.apple.voice.premium.zh-CN.Yun"
                ],
                fallbackGender: .female,
                fallbackLanguage: "zh-CN"
            ),
            SystemVoiceItem(
                id: "premium-fangfang",
                name: "盼盼 · Panpan",
                section: "🌟 Premium Voices",
                detail: "Female · 55.8 MB · 四川话",
                displayTitle: "盼盼 (四川话)",
                candidateIdentifiers: [
                    "com.apple.voice.premium.zh-CN-u-sd-cnsc.Fangfang"
                ],
                fallbackGender: .female,
                fallbackLanguage: "zh-CN"
            ),
            SystemVoiceItem(
                id: "premium-lili",
                name: "莉莉 · Lili",
                section: "🌟 Premium Voices",
                detail: "Female · 普通话",
                displayTitle: "莉莉 (Lili)",
                candidateIdentifiers: [
                    "com.apple.voice.premium.zh-CN.Lili"
                ],
                fallbackGender: .female,
                fallbackLanguage: "zh-CN"
            ),
            SystemVoiceItem(
                id: "premium-meijia",
                name: "美佳 · Meijia",
                section: "🌟 Premium Voices",
                detail: "Female · 57 MB · 台湾国语",
                displayTitle: "美佳 (台湾国语)",
                candidateIdentifiers: [
                    "com.apple.voice.premium.zh-TW.Meijia"
                ],
                fallbackGender: .female,
                fallbackLanguage: "zh-TW"
            ),
            SystemVoiceItem(
                id: "premium-fung",
                name: "峰 · Fung",
                section: "🌟 Premium Voices",
                detail: "Male · 粤语旗舰",
                displayTitle: "峰 (Fung)",
                candidateIdentifiers: [
                    "com.apple.voice.premium.zh-HK.Fung"
                ],
                fallbackGender: .male,
                fallbackLanguage: "zh-HK"
            ),
            SystemVoiceItem(
                id: "premium-sinji",
                name: "善怡 · Sinji",
                section: "🌟 Premium Voices",
                detail: "Female · 粤语旗舰",
                displayTitle: "善怡 (Sinji)",
                candidateIdentifiers: [
                    "com.apple.voice.premium.zh-HK.Sinji"
                ],
                fallbackGender: .female,
                fallbackLanguage: "zh-HK"
            ),
            SystemVoiceItem(
                id: "premium-wing",
                name: "颖 · Wing",
                section: "🌟 Premium Voices",
                detail: "Female · 粤语旗舰",
                displayTitle: "颖 (Wing)",
                candidateIdentifiers: [
                    "com.apple.voice.premium.zh-HK.Wing"
                ],
                fallbackGender: .female,
                fallbackLanguage: "zh-HK"
            )
        ]
        
        // 动态扫描真机上其他已就绪的中文与多语种 Premium 语音
        let allVoices = Self.fetchAllVoicesIncludingSiri()
        let knownCandidateIds = Set(
            (self.siriMainlandVoicesList + self.siriTaiwanVoicesList + self.siriHongKongVoicesList + self.siriEnglishVoicesList + premiumList)
                .flatMap { $0.candidateIdentifiers }
        )
        let extraPremiums = allVoices.filter { voice in
            Self.isStrictChineseVoice(voice) &&
            Self.isPremiumVoice(voice) &&
            !Self.isAnySiriVoice(voice) &&
            !knownCandidateIds.contains(voice.identifier) &&
            !voice.identifier.lowercased().contains("siri")
        }
        for extra in extraPremiums {
            let cleanName = Self.extractOfficialVoiceName(for: extra)
            let item = SystemVoiceItem(
                id: "extra-\(extra.identifier)",
                name: "\(cleanName) · \(extra.name)",
                section: "🌟 Premium Voices",
                detail: "\(extra.gender == AVSpeechSynthesisVoiceGender.male ? "Male" : "Female") · \(extra.language)",
                displayTitle: "\(cleanName) (\(extra.name))",
                candidateIdentifiers: [extra.identifier],
                fallbackGender: extra.gender,
                fallbackLanguage: extra.language
            )
            premiumList.append(item)
        }
        
        self.officialPremiumVoicesList = premiumList
        
        // 6. 英语官方 Premium 旗舰人声列表
        var englishPremiums: [SystemVoiceItem] = [
            SystemVoiceItem(
                id: "premium-en-us-ava",
                name: "Ava (美音 · 女声)",
                section: "🌟 Premium Voices (English - US)",
                detail: "Female · 优质旗舰",
                displayTitle: "Ava (Premium · 美音)",
                candidateIdentifiers: [
                    "com.apple.voice.premium.en-US.Ava"
                ],
                fallbackGender: .female,
                fallbackLanguage: "en-US"
            ),
            SystemVoiceItem(
                id: "premium-en-us-zoe",
                name: "Zoe (美音 · 女声)",
                section: "🌟 Premium Voices (English - US)",
                detail: "Female · 优质旗舰",
                displayTitle: "Zoe (Premium · 美音)",
                candidateIdentifiers: [
                    "com.apple.voice.premium.en-US.Zoe"
                ],
                fallbackGender: .female,
                fallbackLanguage: "en-US"
            ),
            SystemVoiceItem(
                id: "premium-en-gb-jamie",
                name: "Jamie (英音 · 男声)",
                section: "🌟 Premium Voices (English - UK)",
                detail: "Male · 优质旗舰",
                displayTitle: "Jamie (Premium · 英音)",
                candidateIdentifiers: [
                    "com.apple.voice.premium.en-GB.Malcolm"
                ],
                fallbackGender: .male,
                fallbackLanguage: "en-GB"
            ),
            SystemVoiceItem(
                id: "premium-en-gb-serena",
                name: "Serena (英音 · 女声)",
                section: "🌟 Premium Voices (English - UK)",
                detail: "Female · 优质旗舰",
                displayTitle: "Serena (Premium · 英音)",
                candidateIdentifiers: [
                    "com.apple.voice.premium.en-GB.Serena"
                ],
                fallbackGender: .female,
                fallbackLanguage: "en-GB"
            ),
            SystemVoiceItem(
                id: "premium-en-au-karen",
                name: "Karen (澳音 · 女声)",
                section: "🌟 Premium Voices (English - AU)",
                detail: "Female · 优质旗舰",
                displayTitle: "Karen (Premium · 澳音)",
                candidateIdentifiers: [
                    "com.apple.voice.premium.en-AU.Karen"
                ],
                fallbackGender: .female,
                fallbackLanguage: "en-AU"
            ),
            SystemVoiceItem(
                id: "premium-en-au-lee",
                name: "Lee (澳音 · 男声)",
                section: "🌟 Premium Voices (English - AU)",
                detail: "Male · 优质旗舰",
                displayTitle: "Lee (Premium · 澳音)",
                candidateIdentifiers: [
                    "com.apple.voice.premium.en-AU.Lee"
                ],
                fallbackGender: .male,
                fallbackLanguage: "en-AU"
            ),
            SystemVoiceItem(
                id: "premium-en-au-matilda",
                name: "Matilda (澳音 · 女声)",
                section: "🌟 Premium Voices (English - AU)",
                detail: "Female · 优质旗舰",
                displayTitle: "Matilda (Premium · 澳音)",
                candidateIdentifiers: [
                    "com.apple.voice.premium.en-AU.Matilda"
                ],
                fallbackGender: .female,
                fallbackLanguage: "en-AU"
            ),
            SystemVoiceItem(
                id: "premium-en-in-isha",
                name: "Isha (印音 · 女声)",
                section: "🌟 Premium Voices (English - IN)",
                detail: "Female · 优质旗舰",
                displayTitle: "Isha (Premium · 印音)",
                candidateIdentifiers: [
                    "com.apple.voice.premium.en-IN.Isha"
                ],
                fallbackGender: .female,
                fallbackLanguage: "en-IN"
            )
        ]
        
        // 动态扫描真机上其他已下载的英语 Premium 声音 (严格排除任何 Siri 发音人)
        let knownEnglishIds = Set((self.siriEnglishVoicesList + englishPremiums).flatMap { $0.candidateIdentifiers })
        let extraEnglishPremiums = allVoices.filter { voice in
            voice.language.lowercased().hasPrefix("en") &&
            Self.isPremiumVoice(voice) &&
            !Self.isAnySiriVoice(voice) &&
            !knownEnglishIds.contains(voice.identifier) &&
            !voice.identifier.lowercased().contains("siri")
        }
        for extra in extraEnglishPremiums {
            let cleanName = Self.extractOfficialVoiceName(for: extra)
            let item = SystemVoiceItem(
                id: "extra-\(extra.identifier)",
                name: "\(cleanName) · \(extra.name)",
                section: "🌟 Premium Voices (\(extra.language))",
                detail: "\(extra.gender == AVSpeechSynthesisVoiceGender.male ? "Male" : "Female") · 优质旗舰",
                displayTitle: "\(cleanName) (\(extra.name))",
                candidateIdentifiers: [extra.identifier],
                fallbackGender: extra.gender,
                fallbackLanguage: extra.language
            )
            englishPremiums.append(item)
        }
        
        self.premiumEnglishVoicesList = englishPremiums
        
        // 7. 苹果官方 Siri 日语发音人列表 (Hiro 男声 / Sakura 女声)
        // 用户与真机实测核心事实：日语在 iOS 中只有官方 Siri 声音才是 Premium 神经网络级 (gryphon-neural_*_premium)，虽然名称不含 Premium 字段
        self.siriJapaneseVoicesList = [
            SystemVoiceItem(
                id: "siri-ja-1",
                name: "Voice 1 (Hiro · 男声)",
                section: "🇯🇵 Siri - Japanese (日本語 · 官方旗舰)",
                detail: "Male · 神经网络旗舰",
                displayTitle: "Siri 日语 Voice 1 (Hiro)",
                candidateIdentifiers: [
                    "com.apple.ttsbundle.gryphon-neural_hiro_ja-JP_premium",
                    "com.apple.siri.natural.hiro"
                ],
                fallbackGender: .male,
                fallbackLanguage: "ja-JP"
            ),
            SystemVoiceItem(
                id: "siri-ja-2",
                name: "Voice 2 (Sakura · 女声)",
                section: "🇯🇵 Siri - Japanese (日本語 · 官方旗舰)",
                detail: "Female · 神经网络旗舰",
                displayTitle: "Siri 日语 Voice 2 (Sakura)",
                candidateIdentifiers: [
                    "com.apple.ttsbundle.gryphon-neural_sakura_ja-JP_premium",
                    "com.apple.siri.natural.sakura"
                ],
                fallbackGender: .female,
                fallbackLanguage: "ja-JP"
            )
        ]
        self.siriInternationalVoicesList = self.siriJapaneseVoicesList
        
        // 8. 苹果官方 Siri 韩语发音人列表 (Jinsoo 男声 / Minji 女声)
        self.siriKoreanVoicesList = [
            SystemVoiceItem(
                id: "siri-ko-1",
                name: "Voice 1 (Jinsoo · 男声)",
                section: "🇰🇷 Siri - Korean (한국어)",
                detail: "Male · 神经网络",
                displayTitle: "Siri 韩语 Voice 1 (Jinsoo)",
                candidateIdentifiers: [
                    "com.apple.ttsbundle.gryphon-neural_jinsoo_ko-KR_premium",
                    "com.apple.siri.natural.jinsoo"
                ],
                fallbackGender: .male,
                fallbackLanguage: "ko-KR"
            ),
            SystemVoiceItem(
                id: "siri-ko-2",
                name: "Voice 2 (Minji · 女声)",
                section: "🇰🇷 Siri - Korean (한국어)",
                detail: "Female · 神经网络",
                displayTitle: "Siri 韩语 Voice 2 (Minji)",
                candidateIdentifiers: [
                    "com.apple.ttsbundle.gryphon-neural_minji_ko-KR_premium",
                    "com.apple.siri.natural.minji"
                ],
                fallbackGender: .female,
                fallbackLanguage: "ko-KR"
            )
        ]
        
        // 9. 韩语官方 Premium 旗舰人声列表 (Yuna, Jian)
        // 苹果在 iOS 中韩语仅发布了两位 Premium 级声音：Yuna 与 Jian (真机底层ID为 Jina)
        var koreanPremiums: [SystemVoiceItem] = [
            SystemVoiceItem(
                id: "premium-ko-yuna",
                name: "Yuna (유나 · 女声)",
                section: "🌟 Premium Voices (Korean · 한국어)",
                detail: "Female · 优质旗舰",
                displayTitle: "Yuna (Premium · 韩语)",
                candidateIdentifiers: [
                    "com.apple.voice.premium.ko-KR.Yuna"
                ],
                fallbackGender: .female,
                fallbackLanguage: "ko-KR"
            ),
            SystemVoiceItem(
                id: "premium-ko-jian",
                name: "Jian (지안 · 女声)",
                section: "🌟 Premium Voices (Korean · 한국어)",
                detail: "Female · 优质旗舰",
                displayTitle: "Jian (Premium · 韩语)",
                candidateIdentifiers: [
                    "com.apple.voice.premium.ko-KR.Jina",
                    "com.apple.voice.premium.ko-KR.Jian"
                ],
                fallbackGender: .female,
                fallbackLanguage: "ko-KR"
            )
        ]
        
        // 动态扫描真机上其他已下载的韩语 Premium 声音 (严格排除韩语 Siri 发音人，杜绝重复出现)
        let knownKoreanIds = Set((self.siriKoreanVoicesList + koreanPremiums).flatMap { $0.candidateIdentifiers })
        let extraKoreanPremiums = allVoices.filter { voice in
            voice.language.lowercased().hasPrefix("ko") &&
            Self.isPremiumVoice(voice) &&
            !Self.isAnySiriVoice(voice) &&
            !knownKoreanIds.contains(voice.identifier) &&
            !voice.identifier.lowercased().contains("siri")
        }
        for extra in extraKoreanPremiums {
            let cleanName = Self.extractOfficialVoiceName(for: extra)
            let item = SystemVoiceItem(
                id: "extra-\(extra.identifier)",
                name: "\(cleanName) · \(extra.name)",
                section: "🌟 Premium Voices (\(extra.language))",
                detail: "\(extra.gender == AVSpeechSynthesisVoiceGender.male ? "Male" : "Female") · 优质旗舰",
                displayTitle: "\(cleanName) (\(extra.name))",
                candidateIdentifiers: [extra.identifier],
                fallbackGender: extra.gender,
                fallbackLanguage: extra.language
            )
            koreanPremiums.append(item)
        }
        
        self.premiumKoreanVoicesList = koreanPremiums
    }
    
    /// 严格判定语音语言与目标语言是否兼容 (严防香港粤语 zh-HK 被误匹配为台湾 zh-TW 或大陆普通话，严防各国口音混淆)
    static func isLanguageCompatible(voiceLang: String, targetLang: String) -> Bool {
        let vl = voiceLang.lowercased().replacingOccurrences(of: "_", with: "-")
        let tl = targetLang.lowercased().replacingOccurrences(of: "_", with: "-")
        if vl == tl { return true }
        // 香港粤语：必须都包含 hk 或 yue
        if tl.contains("hk") || tl.contains("yue") {
            return vl.contains("hk") || vl.contains("yue")
        }
        // 台湾普通话：必须都包含 tw
        if tl.contains("tw") {
            return vl.contains("tw")
        }
        // 大陆普通话：必须包含 cn 或 hans
        if tl.contains("cn") || tl.contains("hans") {
            return vl.contains("cn") || vl.contains("hans")
        }
        // 英语方言严格对应 (如 en-US 只能匹配 en-US，不能跨国误匹配到 en-GB)
        if tl.hasPrefix("en-") {
            return vl == tl
        }
        // 韩语严格隔离
        if tl.hasPrefix("ko") {
            return vl.hasPrefix("ko")
        }
        // 日语严格隔离
        if tl.hasPrefix("ja") {
            return vl.hasPrefix("ja")
        }
        return vl.hasPrefix(tl.prefix(2))
    }
    
    /// 为给定的规范项目精准解析真机可用的最高品质发音人实体
    func resolveVoice(for item: SystemVoiceItem) -> AVSpeechSynthesisVoice? {
        let allVoices = Self.fetchAllVoicesIncludingSiri()
        
        // 1. 优先通过系统底层内部直连通道 (_voiceFromInternalVoiceListWithIdentifier:) 精确加载
        for candidateId in item.candidateIdentifiers {
            if let direct = Self.loadVoiceWithIdentifier(candidateId) {
                if Self.isLanguageCompatible(voiceLang: direct.language, targetLang: item.fallbackLanguage) {
                    NSLog("🎯 [AudioWhisper] 内部通道直连成功: [%@] -> ID: %@ (Name: %@, Quality: %ld)",
                          item.name, direct.identifier, direct.name, direct.quality.rawValue)
                    return direct
                }
            }
            if let matched = allVoices.first(where: {
                $0.identifier.lowercased() == candidateId.lowercased() &&
                Self.isLanguageCompatible(voiceLang: $0.language, targetLang: item.fallbackLanguage)
            }) {
                NSLog("🎯 [AudioWhisper] 内部列表匹配成功: [%@] -> ID: %@ (Name: %@)",
                      item.name, matched.identifier, matched.name)
                return matched
            }
        }
        
        // 2. 特异性匹配：大陆、台湾、香港、英语 Siri 官方发音人按真机标准名称与区域锁定
        if item.id.hasPrefix("siri-cn-") {
            let pureVoiceName = item.name // "Voice 1", "Voice 2", "Voice 3", "Voice 4"
            if let matchedVoice = allVoices.first(where: {
                $0.language.lowercased().hasPrefix("zh-cn") &&
                $0.name.lowercased() == pureVoiceName.lowercased()
            }) {
                NSLog("🎯 [AudioWhisper] Siri 大陆官方人声按名精准命中: [%@] -> ID: %@ (Name: %@)",
                      item.name, matchedVoice.identifier, matchedVoice.name)
                return matchedVoice
            }
        } else if item.id.hasPrefix("siri-tw-") {
            let pureVoiceName = item.id == "siri-tw-1" ? "Voice 1" : "Voice 2"
            if let matchedVoice = allVoices.first(where: {
                $0.language.lowercased().hasPrefix("zh-tw") &&
                $0.name.lowercased() == pureVoiceName.lowercased()
            }) {
                NSLog("🎯 [AudioWhisper] 台湾 Siri 官方人声按名精准命中: [%@] -> ID: %@ (Name: %@)",
                      item.name, matchedVoice.identifier, matchedVoice.name)
                return matchedVoice
            }
        } else if item.id.hasPrefix("siri-hk-") {
            let pureVoiceName = item.id == "siri-hk-1" ? "Voice 1" : "Voice 2"
            // 优先匹配已安装的香港 Siri (hoyin / kayan)
            if let matchedVoice = allVoices.first(where: {
                ($0.language.lowercased().contains("hk") || $0.language.lowercased().contains("yue")) &&
                $0.name.lowercased() == pureVoiceName.lowercased()
            }) {
                NSLog("🎯 [AudioWhisper] 香港 Siri 官方人声按名精准命中: [%@] -> ID: %@ (Name: %@)",
                      item.name, matchedVoice.identifier, matchedVoice.name)
                return matchedVoice
            }
        } else if item.id.hasPrefix("siri-en-") {
            let pureVoiceName = item.name.components(separatedBy: " ").prefix(2).joined(separator: " ")
            let targetLocale = item.fallbackLanguage.lowercased().replacingOccurrences(of: "_", with: "-")
            if let matchedVoice = allVoices.first(where: {
                $0.language.lowercased().replacingOccurrences(of: "_", with: "-") == targetLocale &&
                $0.name.lowercased().hasPrefix(pureVoiceName.lowercased())
            }) {
                NSLog("🎯 [AudioWhisper] 英语 Siri 官方人声按名精准命中: [%@] -> ID: %@ (Name: %@)",
                      item.name, matchedVoice.identifier, matchedVoice.name)
                return matchedVoice
            }
        } else if item.id.hasPrefix("siri-ko-") {
            let pureVoiceName = item.id == "siri-ko-1" ? "voice 1" : "voice 2"
            let characterName = item.id == "siri-ko-1" ? "jinsoo" : "minji"
            if let matchedVoice = allVoices.first(where: {
                $0.language.lowercased().hasPrefix("ko") &&
                ($0.name.lowercased().contains(pureVoiceName) ||
                 $0.name.lowercased().contains(characterName) ||
                 $0.identifier.lowercased().contains(characterName))
            }) {
                NSLog("🎯 [AudioWhisper] 韩语 Siri 官方人声精准命中: [%@] -> ID: %@ (Name: %@)",
                      item.name, matchedVoice.identifier, matchedVoice.name)
                return matchedVoice
            }
        } else if item.id.hasPrefix("premium-ko-") {
            let characterName = item.id == "premium-ko-yuna" ? "yuna" : "jian"
            if let matchedVoice = allVoices.first(where: {
                $0.language.lowercased().hasPrefix("ko") &&
                Self.isPremiumVoice($0) &&
                ($0.name.lowercased().contains(characterName) ||
                 $0.identifier.lowercased().contains(characterName) ||
                 (characterName == "jian" && ($0.identifier.lowercased().contains("jina") || $0.name.lowercased().contains("jina"))))
            }) {
                NSLog("🎯 [AudioWhisper] 韩语 Premium 官方旗舰人声精准命中: [%@] -> ID: %@ (Name: %@)",
                      item.name, matchedVoice.identifier, matchedVoice.name)
                return matchedVoice
            }
        }
        
        // 严格工程规范：绝不搞任何静默降级兜底！未安装即返回 nil，绝不使用低质或他方声音瞒天过海！
        NSLog("❌ [AudioWhisper] 发音人 [%@] 未在真机安装，严格拒绝任何静默降级兜底！", item.displayTitle)
        return nil
    }
    
    
    /// 动态刷新中文发音人列表并恢复选定发音人
    func refreshActiveVoice() {
        setupSystemVoiceItems()
        
        let allItems = allConfiguredItems
        // 默认恢复为用户系统当前勾选的 Voice 2 ("siri-cn-2")
        let savedItemId = UserDefaults.standard.string(forKey: itemStorageKey) ?? "siri-cn-2"
        let activeItem = allItems.first(where: { $0.id == savedItemId }) ?? (siriMainlandVoicesList.count > 1 ? siriMainlandVoicesList[1] : allItems[0])
        
        self.selectedVoiceItemId = activeItem.id
        self.activeVoiceDescription = activeItem.displayTitle
        
        if let voice = resolveVoice(for: activeItem) {
            self.chineseVoice = voice
            self.selectedVoiceIdentifier = voice.identifier
            NSLog("🎙️ [AudioWhisper] 成功装载发音人: %@ (底层: %@, ID: %@)",
                  activeItem.displayTitle, voice.name, voice.identifier)
        }
    }
    
    /// 用户选择官方规范发音人 (Voice 1~4 / 台湾 Voice 1~2 / 香港 Siri / 英语全系列 / 日语旗舰 / 韩语 / Premium)
    func selectSystemVoiceItem(_ item: SystemVoiceItem) {
        self.selectedVoiceItemId = item.id
        self.activeVoiceDescription = item.displayTitle
        UserDefaults.standard.set(item.id, forKey: itemStorageKey)
        
        if let voice = resolveVoice(for: item) {
            self.chineseVoice = voice
            self.selectedVoiceIdentifier = voice.identifier
            UserDefaults.standard.set(voice.identifier, forKey: voiceStorageKey)
            appendDiagLog("SELECT", "用户切换发音人: \(item.displayTitle) -> ID: \(voice.identifier)")
            
            // 核心竞态防御：取消上一次尚未执行的试听任务，防止连点切换时多路发音人重叠竞争
            pendingSamplePromptWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.appendDiagLog("SAMPLE-RUN", "开始执行防抖试听任务: \(item.displayTitle)")
                self?.speakSamplePrompt()
            }
            self.pendingSamplePromptWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
        } else {
            appendDiagLog("SELECT-FAIL", "发音人未安装: \(item.displayTitle)")
            self.chineseVoice = nil
            self.selectedVoiceIdentifier = ""
            NSLog("❌ [AudioWhisper] 发音人 [%@] 未在系统安装，已拒绝加载，坚决杜绝静默降级！", item.displayTitle)
        }
    }
    
    /// 播报当前发音人专属母语示例文本 (纯正地道单一母语短句，无全角冒号与冷硬前缀，彻底规避发音人跨语种音素抖动与毛刺)
    func speakSamplePrompt() {
        // 核心竞态防御：取消任何挂起的延时试听工作项，防止与手动点击产生追尾竞态
        pendingSamplePromptWorkItem?.cancel()
        
        guard let voice = chineseVoice else {
            NSLog("⚠️ [AudioWhisper] 试听失败：当前选中的发音人未在系统安装！严格拒绝静默降级！")
            return
        }
        let lang = voice.language.lowercased()
        let sampleText: String
        if lang.hasPrefix("en") {
            sampleText = "Please confirm the project timeline to ensure smooth delivery."
        } else if lang.hasPrefix("ja") {
            sampleText = "納期のスケジュールを確認して、計画通りに進めましょう。"
        } else if lang.hasPrefix("ko") {
            sampleText = "납기 일정을 확인하고, 계획대로 원활하게 진행해 주시기 바랍니다."
        } else if lang.contains("hk") || lang.contains("yue") {
            sampleText = "建議先同對方確認好交付工期，確保項目順利推進。"
        } else if lang.contains("tw") {
            sampleText = "建議先確認交付時程，確保專案順利推進。"
        } else {
            sampleText = "建议先与对方确认好交付工期，确保项目顺利推进。"
        }
        
        // 核心竞态消除：与“从列表中切换语音”保持 100% 相同机制，延时 150ms 避开按钮手势与 UI 刷新峰值
        let workItem = DispatchWorkItem { [weak self] in
            self?.speakPrompt(sampleText)
        }
        self.pendingSamplePromptWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }
    
    /// 兼容旧方法: 用户手动指定发音人标识符
    func selectVoice(identifier: String) {
        let allItems = allConfiguredItems
        if let matchedItem = allItems.first(where: { $0.candidateIdentifiers.contains(identifier) }) {
            selectSystemVoiceItem(matchedItem)
            return
        }
        let allVoices = AVSpeechSynthesisVoice.speechVoices()
        guard let voice = allVoices.first(where: { $0.identifier == identifier }) else {
            self.chineseVoice = nil
            self.selectedVoiceIdentifier = ""
            NSLog("❌ [AudioWhisper] 指定发音人 [%@] 不存在！", identifier)
            return
        }
        self.chineseVoice = voice
        self.selectedVoiceIdentifier = voice.identifier
        self.activeVoiceDescription = displayTitle(for: voice)
        UserDefaults.standard.set(identifier, forKey: voiceStorageKey)
        speakPrompt("发音人已切换为 \(displayTitle(for: voice))")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    /// 确保音频会话处于高保真播放模式，动态校验与自愈，遵守苹果官方标准 spokenAudio 规范
    func ensureAudioSessionActive(force: Bool = false) {
        let session = AVAudioSession.sharedInstance()
        let needsConfig = force || !isAudioSessionConfigured || session.category != .playback || session.mode != .spokenAudio
        guard needsConfig else { return }
        do {
            // 恢复苹果官方标准规范配置：
            // 1. category: .playback，高保真输出链路；
            // 2. mode: .spokenAudio，苹果官方标准语音朗读/有声书规范模式；
            // 3. options: []，保持纯净，不引入背景混音侧链干扰；
            // 4. 不强制硬编码硬件缓冲，完全遵从系统与硬件原生自适应对齐。
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                options: []
            )
            try session.setActive(true)
            isAudioSessionConfigured = true
            checkCurrentAudioRoute(isInitial: true)
            NSLog("🎧 [AudioWhisper] 官方规范音频会话已就绪: Category=.playback, Mode=.spokenAudio")
        } catch {
            NSLog("⚠️ [AudioWhisper] 激活音频会话失败: %@", error.localizedDescription)
            checkCurrentAudioRoute(isInitial: true)
        }
    }
    
    // MARK: - 耳机硬件状态检测
    
    @objc private func handleAudioRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        appendDiagLog("ROUTE-EVENT", "收到系统音频路由广播: reason=\(reasonValue) (\(reason))")
        
        // 核心竞态防御：严格过滤系统内部微调通知
        // 只有在物理硬件耳机插入 (.newDeviceAvailable) 或拔出 (.oldDeviceUnavailable) 时，才重置会话并刷新硬件状态
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable:
            isAudioSessionConfigured = false
            DispatchQueue.main.async { [weak self] in
                self?.checkCurrentAudioRoute(isInitial: false)
            }
        default:
            break
        }
    }
    
    /// 检查当前音频路由是否包含耳机输出
    private func checkCurrentAudioRoute(isInitial: Bool) {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        
        var headphoneFound = false
        var headphoneDesc = "耳机"
        
        // 扫描所有已连接输出端口
        for output in outputs {
            switch output.portType {
            case .headphones:
                headphoneFound = true
                headphoneDesc = output.portName.isEmpty ? "有线耳机" : output.portName
            case .bluetoothA2DP:
                headphoneFound = true
                headphoneDesc = output.portName.isEmpty ? "蓝牙耳机 (A2DP 高保真)" : output.portName
            case .bluetoothHFP:
                headphoneFound = true
                headphoneDesc = output.portName.isEmpty ? "蓝牙通话耳机" : output.portName
            case .bluetoothLE:
                headphoneFound = true
                headphoneDesc = output.portName.isEmpty ? "BLE 耳机" : output.portName
            case .airPlay:
                headphoneFound = true
                headphoneDesc = output.portName.isEmpty ? "隔空播放音频" : output.portName
            default:
                break
            }
            if headphoneFound { break }
        }
        
        let previousConnected = self.isHeadphonesConnected
        self.isHeadphonesConnected = headphoneFound
        self.connectedHeadphoneName = headphoneFound ? headphoneDesc : "未连接耳机"
        
        if headphoneFound {
            if !previousConnected || isInitial {
                // 自动联动：检测到戴上/连接耳机，自动开启播放
                self.isAudioPromptEnabled = true
                NSLog("🎧 [AudioWhisper] 检测到耳机接入 (%@)，已自动开启 AI 提示耳语播报", headphoneDesc)
            }
        } else {
            if previousConnected || isInitial {
                // 自动联动：耳机断开或拔出，自动关闭播放以防扬声器公放外泄
                self.isAudioPromptEnabled = false
                NSLog("🔇 [AudioWhisper] 耳机已断开，已自动关闭 AI 提示播报 (坚决禁止扬声器公放)")
            }
        }
    }
    
    // MARK: - 语音耳语朗读 (Whisper TTS)
    
    /// 播报 AI 提示 (仅在佩戴耳机且开关打开时触发)
    func speakPrompt(_ rawText: String) {
        // 核心安全防线：未佩戴耳机或用户关闭开关时，绝对静音
        guard isAudioPromptEnabled && isHeadphonesConnected else {
            NSLog("🤫 [AudioWhisper] 跳过语音播报 (开关: %@, 耳机连接: %@)",
                  isAudioPromptEnabled ? "开" : "关",
                  isHeadphonesConnected ? "是" : "否")
            return
        }
        
        // 净化播报文本 (深度去除特殊符号，保留自然标点呼吸感)
        let cleaned = cleanPromptForSpeech(rawText)
        guard !cleaned.isEmpty else { return }
        
        // 核心防线 1：时间戳节流与内容去重锁 (彻底消除 380ms 处手势抖动/连击引发的截断毛刺)
        let now = DispatchTime.now()
        let elapsedNanoseconds = now.uptimeNanoseconds > lastSpeakTime.uptimeNanoseconds ? (now.uptimeNanoseconds - lastSpeakTime.uptimeNanoseconds) : 0
        let elapsedMs = Double(elapsedNanoseconds) / 1_000_000.0
        
        if cleaned == lastSpeakText && elapsedMs < 600.0 {
            appendDiagLog("THROTTLE", "拦截短时间(600ms)内重复请求: '\(cleaned)' (距离上次=\(String(format: "%.1f", elapsedMs))ms)")
            return
        }
        
        // 核心防线 2：若当前正在播报完全相同的文本，坚决拒绝中途掐断自己！让当前发音平稳自然播完
        if speechSynthesizer.isSpeaking && cleaned == lastSpeakText {
            appendDiagLog("IGNORED", "当前正在播报相同内容，拒绝中途硬切断: '\(cleaned)'")
            return
        }
        
        lastSpeakTime = now
        lastSpeakText = cleaned
        
        if chineseVoice == nil {
            refreshActiveVoice()
        }
        
        // 严正工程防线：发音人未安装时坚决拒绝发声，绝不静默兜底伪造声音！
        guard let voice = chineseVoice else {
            NSLog("❌ [AudioWhisper] 无法播报：当前发音人未在系统安装，严格拒绝任何静默降级兜底！")
            return
        }
        
        // 核心防线 3：单例保持与平滑打断。若播报新内容，仅调用官方标准 stopSpeaking，绝不频繁销毁重建 AVSpeechSynthesizer 实例
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        audioPlayer?.stop()
        
        // 确保音频会话处于纯净回放状态
        ensureAudioSessionActive()
        
        if isPreSynthesizeModeEnabled {
            speakPromptPreSynthesized(cleaned, voice: voice)
        } else {
            let utterance = AVSpeechUtterance(string: cleaned)
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.pitchMultiplier = 1.0
            utterance.volume = 1.0
            
            NSLog("🎙️ [AudioWhisper] 实时流式纯净播放: voice=%@, text='%@'", voice.name, cleaned)
            speechSynthesizer.speak(utterance)
        }
    }
    
    /// 离线预合成整句播放通道：先通过 write 完全生成至文件，待完全就绪后再由 AVAudioPlayer 一口气完整推流
    private func speakPromptPreSynthesized(_ text: String, voice: AVSpeechSynthesisVoice) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let tempURL = docs.appendingPathComponent("tts_presynth_temp.caf")
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        
        self.audioPlayer?.stop()
        self.audioPlayer = nil
        
        // 核心生命周期保障：停止上一个预合成器，并强引用持有新合成器，防止局部变量被 ARC 即刻回收
        self.preSynthesizer?.stopSpeaking(at: .immediate)
        let synth = AVSpeechSynthesizer()
        self.preSynthesizer = synth
        
        var audioFile: AVAudioFile?
        var totalFramesReceived: AVAudioFrameCount = 0
        let startTime = DispatchTime.now()
        
        NSLog("⚡️ [AudioWhisper] 开始离线预合成整句: voice=%@, text='%@'", voice.name, text)
        
        synth.write(utterance) { [weak self, weak synth] buffer in
            guard let self = self, let activeSynth = synth, self.preSynthesizer === activeSynth else {
                // 若该任务已被新任务覆盖，则安全丢弃
                return
            }
            guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }
            
            if pcmBuffer.frameLength == 0 {
                // frameLength == 0 代表整句所有音频完全生成完毕！
                let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0
                NSLog("⚡️ [AudioWhisper] 预合成完成: 总采样帧数=%u, 离线耗时=%.1fms, 准备播放", totalFramesReceived, elapsedMs)
                
                DispatchQueue.main.async {
                    audioFile = nil // 强制关闭文件句柄，将所有数据完全 flush 到磁盘
                    self.playPreSynthesizedFile(tempURL)
                }
                return
            }
            
            totalFramesReceived += pcmBuffer.frameLength
            
            if audioFile == nil {
                try? FileManager.default.removeItem(at: tempURL)
                do {
                    audioFile = try AVAudioFile(forWriting: tempURL, settings: pcmBuffer.format.settings)
                    NSLog("⚡️ [AudioWhisper] 成功建立预合成文件: 格式=%@", pcmBuffer.format.description)
                } catch {
                    NSLog("❌ [AudioWhisper] 创建预合成文件失败: %@", error.localizedDescription)
                }
            }
            
            do {
                try audioFile?.write(from: pcmBuffer)
            } catch {
                NSLog("❌ [AudioWhisper] 写入音频帧数据失败: %@", error.localizedDescription)
            }
        }
    }
    
    private func playPreSynthesizedFile(_ url: URL) {
        ensureAudioSessionActive()
        
        // 校验文件是否存在且大小大于 0
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64, size > 0 else {
            NSLog("❌ [AudioWhisper] 预合成文件不存在或为空 (大小=0)，播放中止！")
            return
        }
        
        do {
            self.audioPlayer = try AVAudioPlayer(contentsOf: url)
            self.audioPlayer?.volume = 1.0
            self.audioPlayer?.prepareToPlay()
            let ok = self.audioPlayer?.play() ?? false
            NSLog("▶️ [AudioWhisper] 预合成整句播放开始: 结果=%@, 文件大小=%llu字节, 音频时长=%.2fs",
                  ok ? "成功" : "失败", size, self.audioPlayer?.duration ?? 0)
        } catch {
            NSLog("❌ [AudioWhisper] AVAudioPlayer 播放预合成文件异常: %@", error.localizedDescription)
        }
    }
    
    /// 直接播放真机已提取保存的现成沙盒音频 (完全零 TTS，纯硬件与本地播放器链路对照测试)
    func playExistingOfflineSample() {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let candidateNames = [
            "tts_dump_com_apple_siri_natural_linfei.wav",
            "tts_dump_com_apple_siri_natural_linfei.caf",
            "tts_offline_dump.caf"
        ]
        guard let foundName = candidateNames.first(where: { FileManager.default.fileExists(atPath: docs.appendingPathComponent($0).path) }) else {
            NSLog("⚠️ [AudioWhisper] 未找到现成离线音频文件")
            return
        }
        let targetURL = docs.appendingPathComponent(foundName)
        NSLog("🎵 [AudioWhisper] 正在直接播放现成离线音频 (零 TTS 调用): %@", foundName)
        playPreSynthesizedFile(targetURL)
    }
    
    /// 停止当前正在播报的语音
    func stopSpeaking() {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        audioPlayer?.stop()
    }
    
    /// 净化待播报文本 (剔除可能引起 TTS 引擎非自然顿音与爆破杂音的特殊字符，保留自然呼吸标点)
    private func cleanPromptForSpeech(_ text: String) -> String {
        var str = text
        // 去除 emoji 与各种特殊符号，但不剔除用于自然断句的顿号“、”
        let symbolsToRemove = [
            "💡", "🔍", "💬", "⚠️", "🎯", "🌟", "✨", "📌", "👉", "🎙️",
            "🇹🇼", "🇭🇰", "🇺🇸", "🇬🇧", "🇦🇺", "🇮🇪", "🇿🇦", "🇯🇵", "🇰🇷",
            "：", ":", "（", "）", "(", ")", "【", "】", "[", "]",
            "“", "”", "\"", "‘", "’", "·", "•", "—", "-", "；", ";"
        ]
        for s in symbolsToRemove {
            str = str.replacingOccurrences(of: s, with: " ")
        }
        // 压缩连续空格
        while str.contains("  ") {
            str = str.replacingOccurrences(of: "  ", with: " ")
        }
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - AVSpeechSynthesizerDelegate 纯净代理回调 (零磁盘 I/O)
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        NSLog("🎙️ [AudioWhisper] 语音开始发声: %@", utterance.voice?.name ?? "")
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        NSLog("✅ [AudioWhisper] 语音播报完毕: '%@'", utterance.speechString)
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        NSLog("⏹️ [AudioWhisper] 语音已取消: '%@'", utterance.speechString)
    }
}
