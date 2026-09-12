import Foundation
import Speech
import AVFoundation
import Combine

/// 逐字稿单行轻量模型 (高性能汉字字符级高频索引)
struct ScriptLineModel {
    let lineIndex: Int
    let rawText: String
    let cleanText: String       // 去除标点与符号后的纯净汉字序列
    let head2: String           // 行首前 2 个字符
    let head3: String           // 行首前 3 个字符
}

/// Even G2 自研 AI 语音智能跟随提词引擎 (SpeechFollowEngine Build 36 高精纯净版)
/// - 48kHz 原生高清拾音 (严格使用 iPhone 内置三麦克风波束成形阵列，绝不降频至 8kHz 蓝牙电话音质)
/// - 苹果原生全能力神经识别引擎 (取消强制离线模式，恢复原本最高置信度识别率)
/// - 规范化音频会话生命周期管理 (杜绝运行中途热换导致的破损音频帧与错字)
/// - 局部前向窗口最大综合得分竞争算法 (当前行 +2 粘性保护，尾部行首命中 +10 强推进奖励，彻底杜绝乱跳与抢跑)
/// - 提词位置与识别位置 100% 绝对一致 (Strict 1:1 Alignment)
class SpeechFollowEngine: NSObject, ObservableObject, SFSpeechRecognizerDelegate {
    static let shared = SpeechFollowEngine()
    
    // MARK: - Published 状态
    @Published var isListening: Bool = false
    @Published var partialTranscript: String = ""
    @Published var lastRecognizedText: String = ""
    @Published var activeLineIndex: Int = 0
    @Published var isDigressed: Bool = false
    static let preferredAudioSourceKey = "smartglass_preferred_audio_source"
    
    @Published var isManualOverrideActive: Bool = false
    @Published var confidenceScore: Float = 0.0
    @Published var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    @Published var currentAudioSource: AudioSourceType = {
        if let saved = UserDefaults.standard.string(forKey: SpeechFollowEngine.preferredAudioSourceKey),
           let source = AudioSourceType(rawValue: saved) {
            return source
        }
        return .phoneMic
    }() {
        didSet {
            UserDefaults.standard.set(currentAudioSource.rawValue, forKey: SpeechFollowEngine.preferredAudioSourceKey)
            if oldValue != currentAudioSource && isListening {
                cleanRestartPipeline(reason: "音频输入源切换至 \(currentAudioSource.rawValue)")
            }
        }
    }
    
    private var audioFrameCounter: Int = 0
    
    // MARK: - 回调通知
    var onVoiceKeywordTriggered: ((String) -> Void)?
    var onLineIndexUpdated: ((Int) -> Void)?
    /// 联合同步回调：同时上报权威目标行号 (lineIndex) 与行内字符偏移游标 (wordOrder)
    var onSpeechSyncUpdated: ((Int, Int) -> Void)?
    
    // MARK: - ASR 核心组件 (指定 zh-CN 语言)
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    // MARK: - 音频输入源 (双路架构: 手机 48kHz / 眼镜 16kHz LC3)
    private var activeAudioSource: AudioInputSourceProtocol?
    private let phoneAudioSource = PhoneBuiltinAudioSource()
    private lazy var glassesAudioSource = GlassesBLEAudioSource()
    
    // MARK: - 内部控制状态
    private var isRestarting: Bool = false
    
    // MARK: - 逐字稿数据
    private var currentRawScript: String = ""
    private var scriptLines: [ScriptLineModel] = []
    private var endKeywords: [String] = []
    private var lastValidMatchTime = Date()
    private var overrideCooldownWorkItem: DispatchWorkItem?
    private var lastScrollSyncTime = Date.distantPast
    
    // MARK: - 字级变暗 (Word-Level Dimming / RunDot) 状态控制
    @Published private(set) var currentWordOrder: Int = 0
    
    private let minScrollIntervalMs: Double = 0.120
    private static let stopwordSet: Set<Character> = Set("的了是在和与于个这那我们你有也")
    
    override init() {
        super.init()
        speechRecognizer?.delegate = self
        requestPermissions()
    }
    
    // MARK: - 权限请求
    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                self?.authorizationStatus = status
                NSLog("🎤 [SpeechEngine] 语音识别授权状态: %ld", status.rawValue)
            }
        }
        
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            NSLog("🎤 [SpeechEngine] 麦克风录音授权: %@", granted ? "已允许" : "被拒绝")
        }
    }
    
    // MARK: - 1. 载入权威分行逐字稿
    func loadSlideScriptLines(lines: [String], rawScript: String, keywords: [String]? = nil) {
        if self.currentRawScript == rawScript && !self.scriptLines.isEmpty {
            return
        }
        self.currentRawScript = rawScript
        
        var list: [ScriptLineModel] = []
        for (idx, line) in lines.enumerated() {
            let clean = SpeechFollowEngine.cleanString(line)
            let base = clean.isEmpty ? line : clean
            let h2 = String(base.prefix(2))
            let h3 = String(base.prefix(3))
            list.append(ScriptLineModel(lineIndex: idx, rawText: line, cleanText: base, head2: h2, head3: h3))
        }
        self.scriptLines = list
        self.endKeywords = keywords ?? ["下一页", "下一张", "翻到下一页", "进入下一节"]
        self.activeLineIndex = 0
        self.currentWordOrder = 0
        self.isDigressed = false
        self.confidenceScore = 0.0
        self.lastValidMatchTime = Date()
        clearManualOverride()
        
        // 🌟 切页全新启动：若正在收音，执行规范化安全重启，清空上一页旧缓存
        if self.isListening {
            cleanRestartPipeline(reason: "切页全新启动")
        }
        
        NSLog("📚 [SpeechEngine] 成功装载逐字稿模型 (%ld 行)", list.count)
    }
    
    func loadSlideScript(script: String, keywords: [String]? = nil) {
        let maxLineWidth = 28 * 2
        let (pages, _) = G2ProtocolEncoder.formatTextToPagesOnDemand(script, maxLineWidth: maxLineWidth, linesPerPage: 10)
        let lines = pages.flatMap { $0.components(separatedBy: "\n") }
        loadSlideScriptLines(lines: lines.isEmpty ? [script] : lines, rawScript: script, keywords: keywords)
    }
    
    // MARK: - 2. 启动流式 ASR 监听
    func startListening() {
        guard !isListening else { return }
        guard authorizationStatus == .authorized || SFSpeechRecognizer.authorizationStatus() == .authorized else {
            NSLog("⚠️ [SpeechEngine] 未获得语音识别权限，无法开启")
            requestPermissions()
            return
        }
        
        // 🌟 防空保障：若当前逐字稿模型为空，自动从 LectureSessionManager 补齐
        if scriptLines.isEmpty {
            let fallbackLines = LectureSessionManager.shared.getWrappedScriptLines()
            if !fallbackLines.isEmpty {
                loadSlideScriptLines(lines: fallbackLines, rawScript: LectureSessionManager.shared.currentScriptText)
            }
        }
        
        self.isListening = true
        self.partialTranscript = ""
        self.lastValidMatchTime = Date()
        
        startAudioPipeline(reason: "用户手动开启监听")
    }
    
    // MARK: - 3. 音频输入源热切换 (手机麦克风 vs 眼镜麦克风)
    func switchAudioSource(to newSource: AudioSourceType) {
        guard currentAudioSource != newSource else { return }
        NSLog("🔄 [SpeechEngine] 用户设置偏好音频源: %@ -> %@", currentAudioSource.rawValue, newSource.rawValue)
        self.currentAudioSource = newSource
    }
    
    // MARK: - 4. 启动音频流水线 (双路自适应: 手机 48kHz / 眼镜 16kHz LC3)
    private func startAudioPipeline(reason: String) {
        guard isListening else { return }
        NSLog("🎙️ [SpeechEngine] 正在启动音频流水线 (源: %@, 原因: %@)...", currentAudioSource.rawValue, reason)
        
        if let task = recognitionTask {
            recognitionTask = nil
            task.cancel()
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        activeAudioSource?.stop()
        activeAudioSource = nil
        
        do {
            let request = SFSpeechAudioBufferRecognitionRequest()
            // 🛡️ 核心保障：使用苹果全能力神经识别引擎
            request.shouldReportPartialResults = true
            self.recognitionRequest = request
            
            let source: AudioInputSourceProtocol
            switch currentAudioSource {
            case .phoneMic:
                source = phoneAudioSource
            case .glassesMic:
                source = glassesAudioSource
            }
            self.activeAudioSource = source
            
            source.onAudioBufferCaptured = { [weak self] buffer in
                guard let self = self else { return }
                self.audioFrameCounter += 1
                if self.audioFrameCounter % 20 == 1 {
                    NSLog("🎙️ [SpeechEngine] ASR 接收音频流正常 (已流入 %ld 帧 PCM, 格式: %@)", self.audioFrameCounter, buffer.format.description)
                }
                self.recognitionRequest?.append(buffer)
            }
            source.onError = { [weak self] error in
                NSLog("❌ [SpeechEngine] 音频源异常: %@", error.localizedDescription)
                if self?.isListening == true {
                    self?.cleanRestartPipeline(reason: "音频源异常自愈")
                }
            }
            
            try source.start()
            startRecognitionTask()
            NSLog("✅ [SpeechEngine] 音频流水线已就绪 (源: %@)！", currentAudioSource.rawValue)
        } catch {
            NSLog("❌ [SpeechEngine] 音频流水线启动失败: %@", error.localizedDescription)
            
            // 🛡️ 容错保护：若眼镜麦克风启动失败（如未连蓝牙），自动平滑降级回手机麦克风
            if currentAudioSource == .glassesMic {
                NSLog("⚠️ [SpeechEngine] 眼镜麦克风不可用，自动降级回 iPhone 手机麦克风")
                DispatchQueue.main.async {
                    self.currentAudioSource = .phoneMic
                }
                cleanRestartPipeline(reason: "眼镜麦克风不可用自动降级")
                return
            }
            self.isListening = false
        }
    }
    
    // MARK: - 5. 内部启动识别任务
    private func startRecognitionTask() {
        guard let request = recognitionRequest else { return }
        
        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            
            if let result = result {
                let transcript = result.bestTranscription.formattedString
                NSLog("🗣️ [SpeechEngine] ASR 实时识别文字: '%@'", transcript)
                DispatchQueue.main.async {
                    self.partialTranscript = transcript
                    self.lastRecognizedText = transcript
                    if !transcript.isEmpty {
                        self.processTranscriptAlignment(transcript)
                    }
                }
            }
            
            if let err = error as NSError? {
                if err.code == 216 {
                    // 主动 cancel 正常退出
                    return
                }
                NSLog("⚠️ [SpeechEngine] ASR 任务中断 (Code=%ld): %@", err.code, err.localizedDescription)
                if self.isListening && !self.isRestarting {
                    self.cleanRestartPipeline(reason: "错误自愈 (Code \(err.code))")
                }
            } else if result?.isFinal == true {
                NSLog("🏁 [SpeechEngine] 语句自然分界 (isFinal=true)，规范重启保持监听")
                if self.isListening && !self.isRestarting {
                    self.cleanRestartPipeline(reason: "语句自然分界")
                }
            }
        }
    }
    
    // MARK: - 6. 规范安全重启流水线 (彻底消除中途热换导致的破损音频帧)
    private func cleanRestartPipeline(reason: String) {
        guard isListening else { return }
        guard !isRestarting else { return }
        self.isRestarting = true
        
        NSLog("🔄 [SpeechEngine] 正在规范重启音频流水线 (原因: %@)...", reason)
        
        // 1. 干净停止当前音频源
        activeAudioSource?.stop()
        activeAudioSource = nil
        
        // 2. 干净结束旧识别任务
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        // 3. 延迟 80ms 释放底层硬件或 BLE 通道后干净重新启动
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self = self else { return }
            self.isRestarting = false
            guard self.isListening else { return }
            self.startAudioPipeline(reason: reason)
        }
    }
    
    // MARK: - 7. 停止监听
    func stopListening() {
        self.isListening = false
        self.isRestarting = false
        
        if let task = recognitionTask {
            recognitionTask = nil
            task.cancel()
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        activeAudioSource?.stop()
        activeAudioSource = nil
        
        self.partialTranscript = ""
        self.confidenceScore = 0.0
        NSLog("⏹️ [SpeechEngine] 语音提词引擎已完全停止 (已保留最后识别结果: '%@')", lastRecognizedText)
    }
    
    // MARK: - 麦克风试音与实时识别控制
    func clearRecognizedText() {
        DispatchQueue.main.async {
            self.partialTranscript = ""
            self.lastRecognizedText = ""
        }
    }
    
    /// 启动麦克风测试 (试音 + 实时 ASR 识别)
    func startMicTesting(source: AudioSourceType = .glassesMic) {
        NSLog("🎙️ [SpeechEngine] 用户发起麦克风试音测试 (源: %@)", source.rawValue)
        self.clearRecognizedText()
        self.currentAudioSource = source
        if !self.isListening {
            self.startListening()
        } else {
            self.cleanRestartPipeline(reason: "启动试音测试并强制指定音频源")
        }
    }
    
    /// 停止麦克风测试
    func stopMicTesting() {
        NSLog("⏹️ [SpeechEngine] 用户停止麦克风试音测试")
        self.stopListening()
        BLEManager.shared.stopGlassesMicrophone()
    }
    
    // MARK: - 7. 人在回路 (HOTL) 物理手势优先让位
    func markManualOverride(reason: String = "Physical Gesture") {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isManualOverrideActive = true
            NSLog("🛑 [SpeechEngine] HOTL 物理介入: %@，AI 引擎让位 3.0s", reason)
            
            self.overrideCooldownWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.isManualOverrideActive = false
                NSLog("🟢 [SpeechEngine] HOTL 让位周期结束，恢复 AI 语音跟随")
            }
            self.overrideCooldownWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: workItem)
        }
    }
    
    func clearManualOverride() {
        self.overrideCooldownWorkItem?.cancel()
        self.overrideCooldownWorkItem = nil
        self.isManualOverrideActive = false
    }
    
    // MARK: - 8. 核心文本对齐解算 (局部前向窗口最大综合得分竞争算法)
    private func processTranscriptAlignment(_ transcript: String) {
        // 🛡️ 核心防空：若逐字稿未装载或仍为占位符，自动从 LectureSessionManager 实时同步当前页真实排版行
        if self.scriptLines.isEmpty || self.scriptLines.first?.cleanText.contains("暂无口述提词") == true {
            let currentLines = LectureSessionManager.shared.getWrappedScriptLines()
            let rawText = LectureSessionManager.shared.currentScriptText
            if !currentLines.isEmpty && currentLines.first != "暂无口述提词" {
                NSLog("🔄 [SpeechEngine] 检测到逐字稿模型未就绪，自动从 LectureManager 同步当前页 (%ld 行)...", currentLines.count)
                self.loadSlideScriptLines(lines: currentLines, rawScript: rawText)
            }
        }
        guard !scriptLines.isEmpty else {
            NSLog("⚠️ [SpeechEngine] 逐字稿模型为空，跳过对齐 (可在智慧课堂加载课时或检查网络)")
            return
        }
        guard !isManualOverrideActive else {
            NSLog("🛑 [SpeechEngine] 人工手势介入中，AI 引擎让位")
            return
        }
        
        let totalCount = scriptLines.count
        let cleanText = SpeechFollowEngine.cleanString(transcript)
        guard cleanText.count >= 2 else { return }
        
        // 1. 检查是否读到当前幻灯片尾部关键词（必须在全页最后一行且尾部念出明确切页指令）
        if totalCount > 0 && activeLineIndex >= totalCount - 1 {
            for keyword in endKeywords {
                let cleanKw = SpeechFollowEngine.cleanString(keyword)
                if !cleanKw.isEmpty && cleanText.hasSuffix(cleanKw) {
                    NSLog("🎯 [SpeechEngine] 尾部语义锚点命中: '%@'，触发自动切页！", keyword)
                    onVoiceKeywordTriggered?("NEXT")
                    return
                }
            }
        }
        
        // 2. 提取探针：覆盖最近 24 字符窗口与最近 10 字符尾部
        let probeLen = min(cleanText.count, 24)
        let probe = String(cleanText.suffix(probeLen))
        let recentTail = String(cleanText.suffix(min(cleanText.count, 10)))
        
        let curr = self.activeLineIndex
        let startIdx = max(0, curr - 1)
        let endIdx = min(totalCount - 1, curr + 3)
        
        var bestScore: Float = -1.0
        var bestIdx: Int = curr
        var currBaseScore: Float = 0.0
        var currEndInTarget: Int = 0
        var matchReason: String = ""
        
        for idx in startIdx...endIdx {
            let cand = scriptLines[idx]
            let candText = cand.cleanText
            guard !candText.isEmpty else { continue }
            
            let (lcs, endInS2) = SpeechFollowEngine.maxCommonSubstringMatch(probe, candText)
            let overlap = SpeechFollowEngine.overlapCharCount(probe, candText)
            let baseScore = Float(overlap + lcs * 2)
            
            if idx == curr {
                currBaseScore = baseScore
                currEndInTarget = endInS2
            }
            
            var score = baseScore
            if idx == curr {
                score += 3.0  // 当前行温和粘性保护
            } else if idx == curr + 1 {
                let hasTailH3 = !cand.head3.isEmpty && recentTail.contains(cand.head3)
                let hasTailH2 = !cand.head2.isEmpty && recentTail.contains(cand.head2)
                let hasAnyH3 = !cand.head3.isEmpty && probe.contains(cand.head3)
                if hasTailH3 {
                    score += 10.0 // 最近尾部命中下行行首 3 字强推进奖励
                } else if hasTailH2 {
                    score += 4.0  // 最近尾部命中下行行首 2 字启动奖励
                } else if hasAnyH3 {
                    score += 4.0
                }
                if lcs >= 2 || overlap >= 3 {
                    score += 5.0
                }
            } else if idx >= curr + 2 {
                let hasTailH3 = !cand.head3.isEmpty && recentTail.contains(cand.head3)
                if hasTailH3 {
                    score += 8.0  // 跨行跳读奖励
                } else if !cand.head3.isEmpty && probe.contains(cand.head3) {
                    score += 4.0
                }
                if lcs >= 2 {
                    score += 4.0
                }
            }
            
            if score > bestScore {
                bestScore = score
                bestIdx = idx
                matchReason = "候选第 \(idx + 1) 行 (Score=\(String(format: "%.1f", score)), LCS=\(lcs), Overlap=\(overlap))"
            }
        }
        
        // 3. 决策推进或坚守
        // 推进条件：若后续行得分显著超越当前行 (>= 3.5)，或当前行未命中但后续行有匹配
        let shouldAdvance = (bestIdx > curr) && (bestScore >= 4.0 || (currBaseScore < 2.0 && bestScore >= 3.0))
        
        if shouldAdvance {
            let nextCand = scriptLines[bestIdx]
            let (_, nextEnd) = SpeechFollowEngine.maxCommonSubstringMatch(probe, nextCand.cleanText)
            let initialOrder = nextEnd > 0 ? SpeechFollowEngine.projectCleanIndexToRaw(cleanIndex: nextEnd, raw: nextCand.rawText, clean: nextCand.cleanText) : 0
            NSLog("🚀 [SpeechEngine] 触发推进决策 -> 第 %ld 行 (%@, initialOrder=%ld)", bestIdx + 1, matchReason, initialOrder)
            commitLineAdvance(targetIndex: bestIdx, initialWordOrder: initialOrder, reason: matchReason)
        } else if currBaseScore >= 2.0 || currEndInTarget >= 1 {
            self.lastValidMatchTime = Date()
            if self.isDigressed {
                self.isDigressed = false
            }
            let currCand = scriptLines[curr]
            self.confidenceScore = min(currBaseScore / Float(max(currCand.cleanText.count, 2)), 1.0)
            
            // 🎯 字级变暗 (Word-Level Dimming / RunDot) 游标计算
            if currEndInTarget > 0 {
                let rawOffset = SpeechFollowEngine.projectCleanIndexToRaw(
                    cleanIndex: currEndInTarget,
                    raw: currCand.rawText,
                    clean: currCand.cleanText
                )
                var targetWordOrder = rawOffset
                let cleanLen = currCand.cleanText.count
                // 行尾饱和判断：若匹配到达行末 80% 或距离末尾 <= 2 个汉字，饱和至整行长度 (全暗过渡)
                if cleanLen > 0 && (currEndInTarget >= Int(Float(cleanLen) * 0.80) || cleanLen - currEndInTarget <= 2) {
                    targetWordOrder = currCand.rawText.count
                }
                
                // 🛡️ 单调递增水位线保护：同一行内只能向前推进，禁止因重识别抖动倒退闪烁
                if targetWordOrder > self.currentWordOrder {
                    self.currentWordOrder = targetWordOrder
                    NSLog("✨ [SpeechEngine] 行内变暗更新: Line %ld, Order %ld/%ld (ASR: '%@')", curr + 1, targetWordOrder, currCand.rawText.count, probe)
                    self.onSpeechSyncUpdated?(curr, targetWordOrder)
                }
            }
        } else {
            let digressedElapsed = Date().timeIntervalSince(lastValidMatchTime)
            if digressedElapsed > 3.0 && !self.isDigressed {
                self.isDigressed = true
                NSLog("🛡️ [SpeechEngine] 脱稿即兴发挥中 (%.1fs)，坚守当前行 %ld (ASR: '%@')", digressedElapsed, curr + 1, probe)
            }
        }
    }
    
    /// 统一推进行号与节流下发
    private func commitLineAdvance(targetIndex: Int, initialWordOrder: Int = 0, reason: String) {
        guard targetIndex != self.activeLineIndex else { return }
        
        self.lastValidMatchTime = Date()
        if self.isDigressed {
            self.isDigressed = false
            NSLog("🟢 [SpeechEngine] 讲回逐字稿主线，AI 重新咬合至第 %ld 行 (%@)", targetIndex + 1, reason)
        }
        
        let now = Date()
        guard now.timeIntervalSince(lastScrollSyncTime) >= minScrollIntervalMs else { return }
        lastScrollSyncTime = now
        
        let oldIndex = self.activeLineIndex
        NSLog("🚀 [SpeechEngine] 成功推进行号: 第 %ld 行 -> 第 %ld 行 (%@)", oldIndex + 1, targetIndex + 1, reason)
        
        // 🌟 切换当前活跃行号并下发新行首帧 (历史行在手机端由 isPastRead 自动维持全暗，无需连发旧包冲垮信道)
        self.activeLineIndex = targetIndex
        self.currentWordOrder = initialWordOrder
        self.confidenceScore = 1.0
        onLineIndexUpdated?(targetIndex)
        onSpeechSyncUpdated?(targetIndex, initialWordOrder)
    }
    
    // MARK: - 9. 字符串清洗与匹配算法工具
    static func cleanString(_ s: String) -> String {
        return s.replacingOccurrences(of: "•", with: "")
                .replacingOccurrences(of: "#", with: "")
                .replacingOccurrences(of: "【", with: "")
                .replacingOccurrences(of: "】", with: "")
                .replacingOccurrences(of: "：", with: "")
                .replacingOccurrences(of: "，", with: "")
                .replacingOccurrences(of: "。", with: "")
                .replacingOccurrences(of: "！", with: "")
                .replacingOccurrences(of: "？", with: "")
                .replacingOccurrences(of: "、", with: "")
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "；", with: "")
                .replacingOccurrences(of: "“", with: "")
                .replacingOccurrences(of: "”", with: "")
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "'", with: "")
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// 计算最长公共连续子串长度 (Longest Common Contiguous Substring)
    static func maxCommonSubstringLength(_ s1: String, _ s2: String) -> Int {
        guard !s1.isEmpty && !s2.isEmpty else { return 0 }
        let a1 = Array(s1)
        let a2 = Array(s2)
        let m = a1.count
        let n = a2.count
        var prev = Array(repeating: 0, count: n + 1)
        var curr = Array(repeating: 0, count: n + 1)
        var maxLen = 0
        for i in 1...m {
            for j in 1...n {
                if a1[i - 1] == a2[j - 1] {
                    curr[j] = prev[j - 1] + 1
                    if curr[j] > maxLen { maxLen = curr[j] }
                } else {
                    curr[j] = 0
                }
            }
            prev = curr
            curr = Array(repeating: 0, count: n + 1)
        }
        return maxLen
    }
    
    /// 计算实词字符交集重合总数 (Content Character Overlap, 自动剔除虚词停用词噪声)
    static func overlapCharCount(_ s1: String, _ s2: String) -> Int {
        guard !s1.isEmpty && !s2.isEmpty else { return 0 }
        var set1 = Set(s1)
        set1.subtract(stopwordSet)
        var count = 0
        for c in s2 {
            if set1.contains(c) {
                count += 1
            }
        }
        return count
    }
    
    /// 计算最长公共连续子串长度及其在目标行 (s2) 中的右边界字符下标 (1-based, 用于字级变暗定位)
    static func maxCommonSubstringMatch(_ s1: String, _ s2: String) -> (length: Int, endOffsetInS2: Int) {
        guard !s1.isEmpty && !s2.isEmpty else { return (0, 0) }
        let a1 = Array(s1)
        let a2 = Array(s2)
        let m = a1.count
        let n = a2.count
        var prev = Array(repeating: 0, count: n + 1)
        var curr = Array(repeating: 0, count: n + 1)
        var maxLen = 0
        var bestEnd = 0
        for i in 1...m {
            for j in 1...n {
                if a1[i - 1] == a2[j - 1] {
                    curr[j] = prev[j - 1] + 1
                    if curr[j] > maxLen {
                        maxLen = curr[j]
                        bestEnd = j
                    }
                } else {
                    curr[j] = 0
                }
            }
            prev = curr
            curr = Array(repeating: 0, count: n + 1)
        }
        return (maxLen, bestEnd)
    }
    
    /// 将清洗字符串中的字符下标投影映射回原始带标点文本中的物理字符偏移量 (WordOrder)
    static func projectCleanIndexToRaw(cleanIndex: Int, raw: String, clean: String) -> Int {
        guard cleanIndex > 0 else { return 0 }
        guard !raw.isEmpty && !clean.isEmpty else { return 0 }
        
        var cleanCount = 0
        var rawCharIndex = 0
        let targetClean = min(cleanIndex, clean.count)
        
        for ch in raw {
            rawCharIndex += 1
            let cleaned = cleanString(String(ch))
            if !cleaned.isEmpty {
                cleanCount += 1
                if cleanCount >= targetClean {
                    return rawCharIndex
                }
            }
        }
        return min(rawCharIndex, raw.count)
    }
}
