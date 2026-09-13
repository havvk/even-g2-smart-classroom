import Foundation
import Combine
import AVFoundation
import Speech

/// Even G2 对话模式中枢调度控制器 (Conversation Copilot Orchestrator)
///
/// 核心职能:
/// - 统筹协调 BLEManager (Service 0x0B-20 / 0x6450 通道)
/// - 调度 DualTrackSpeakerDetector (双轨麦克风近远场能量比对)
/// - 调度 AICopilotPromptManager (平静技术单卡微标签推送与 20 槽位抽屉镜像)
/// - 调度 SFSpeechRecognizer (苹果原生实时语音转写与断句滚行)
/// - 严格生命周期时序: Auth 7 包 -> ConversateInit -> 2.25s 动效避让 -> 麦克风上电 -> 实时听写与 AI 提示 -> 优雅注销
class ConversationCopilotManager: ObservableObject {
    
    // MARK: - Published State
    
    @Published var isSessionActive: Bool = false
    @Published var isStarting: Bool = false
    @Published var statusMessage: String = "未开启"
    
    /// 下半区当前实时听写文本 (含 [我] / [对方] 说话人前缀)
    @Published var currentTranscript: String = ""
    
    /// 历史转写流水
    @Published var transcriptHistory: [String] = []
    
    /// 上半区最新下发的 AI 建议标题与详情
    @Published var lastSentTitle: String = ""
    @Published var lastSentDetail: String = ""
    
    /// 结构化发言列表 (用于总结与转写纪要归档)
    @Published var structuredUtterances: [ConversationUtterance] = []
    
    /// 最近一次会话归档记录 (包含 AI 纪要、统计与逐字稿)
    @Published var lastSessionRecord: ConversationSessionRecord? = nil
    
    /// 是否弹出纪要与转写 Sheet
    @Published var showingSummarySheet: Bool = false
    
    /// 会话开始时间
    private var sessionStartTime: Date? = nil
    
    // MARK: - Dependencies
    
    weak var bleManager: BLEManager?
    let promptManager = AICopilotPromptManager.shared
    let speakerDetector = DualTrackSpeakerDetector.shared
    let audioWhisperManager = AudioWhisperPromptManager.shared
    
    private var glassesAudioSource: GlassesBLEAudioSource?
    private var phoneAudioSource: PhoneBuiltinAudioSource?
    // MARK: - 流式打字节流调度器 (防止高频发包冲爆 Even G2 蓝牙 FIFO)
    private var lastTranscriptPushTime: DispatchTime = .now()
    private var pendingTranscriptText: String? = nil
    private var transcriptThrottleWorkItem: DispatchWorkItem? = nil
    private let throttleIntervalNanoseconds: UInt64 = 150_000_000 // 150ms 黄金节流窗口
    
    private var syncTimer: Timer?
    private var seq: UInt8 = 0
    private var msgId: Int = 1
    
    // MARK: - Singleton
    
    static let shared = ConversationCopilotManager()
    
    init(bleManager: BLEManager? = nil) {
        self.bleManager = bleManager ?? BLEManager.shared
        SFSpeechRecognizer.requestAuthorization { _ in }
    }
    
    // MARK: - Lifecycle Management
    
    /// 启动 Even G2 对话模式
    func startSession(completion: ((Bool) -> Void)? = nil) {
        let ble = bleManager ?? BLEManager.shared
        self.bleManager = ble
        
        guard ble.isConnected else {
            self.statusMessage = "❌ 眼镜未连接"
            completion?(false)
            return
        }
        
        guard !isSessionActive && !isStarting else {
            completion?(true)
            return
        }
        
        self.isStarting = true
        self.statusMessage = "🔑 正在执行认证与会话初始化..."
        self.sessionStartTime = Date()
        self.structuredUtterances.removeAll()
        
        // 关键：切换全局模式为 .conversate，防止麦克风启动时误触发提词器屏显劫持
        ble.switchMode(to: .conversate)
        ble.currentGlassesState = .conversate
        
        // 1. 发送 7 包 Auth 认证 (确保固件解锁)
        for pkt in G2ProtocolEncoder.buildAuthPackets(seq: &seq, msgId: &msgId) {
            ble.sendRawData(pkt, channel: .content, logDesc: "Auth 认证")
            Thread.sleep(forTimeInterval: 0.04)
        }
        
        // 2. 下发 0x0B-20 Init 报文
        let initPkt = G2ProtocolEncoder.buildConversateInit(seq: &seq)
        ble.sendRawData(initPkt, channel: .content, logDesc: "0x0B-20 对话模式启动")
        self.statusMessage = "⏳ 正在避让官方 2.25 秒开场动效..."
        
        // 3. 严格避让 2.25 秒开场动画
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.25) { [weak self] in
            guard let self = self else { return }
            
            // 4. 开启左镜腿麦克风硬件 (EvenHub Cmd=18)
            let micPkt = G2ProtocolEncoder.buildAudioControlPacket(enable: true, seq: &self.seq)
            ble.sendRawData(micPkt, channel: .content, logDesc: "开启镜腿麦克风")
            
            // 5. 启动双轨音频捕获与流式 ASR
            self.startAudioPipelines()
            
            // 6. 启动 5s 显存锁存与看门狗保活定时器
            self.startSyncKeepaliveTimer()
            
            // 7. 发送开场基准转写
            self.pushTranscript(text: "Even AI 对话助手已就绪", isFinal: true)
            
            self.isSessionActive = true
            self.isStarting = false
            self.statusMessage = "🟢 对话模式运行中 (双视口就绪)"
            completion?(true)
        }
    }
    
    /// 退出对话模式并安全释放显存
    func stopSession() {
        guard isSessionActive || isStarting else { return }
        
        // 1. 停止音频流、语音识别与心跳，终止耳机语音播报
        stopAudioPipelines()
        stopSpeechRecognition()
        stopSyncKeepaliveTimer()
        audioWhisperManager.stopSpeaking()
        
        // 2. 下发退出报文 (0x0B-20 Type 1)
        if let ble = bleManager, ble.isConnected {
            let exitPkt = G2ProtocolEncoder.buildConversateExit(seq: &seq)
            ble.sendRawData(exitPkt, channel: .content, logDesc: "0x0B-20 退出对话模式")
            
            // 关断麦克风
            let micOffPkt = G2ProtocolEncoder.buildAudioControlPacket(enable: false, seq: &seq)
            ble.sendRawData(micOffPkt, channel: .content, logDesc: "关断镜腿麦克风")
            
            ble.currentGlassesState = .dashboard
            ble.switchMode(to: .dashboard)
        }
        
        // 3. 构建本次会话的归档记录并异步触发 AI 总结生成
        let startTime = self.sessionStartTime ?? Date()
        let endTime = Date()
        let utterances = self.structuredUtterances
        
        if !utterances.isEmpty {
            let stats = ConversationStats.calculate(startTime: startTime, endTime: endTime, utterances: utterances)
            var record = ConversationSessionRecord(
                startTime: startTime,
                endTime: endTime,
                utterances: utterances,
                stats: stats,
                summary: nil
            )
            
            DispatchQueue.main.async {
                self.lastSessionRecord = record
                self.showingSummarySheet = true
            }
            
            // 异步生成智能总结
            ConversationSummaryService.shared.generateSummary(for: utterances, stats: stats) { [weak self] summary in
                record.summary = summary
                self?.lastSessionRecord = record
            }
        }
        
        // 4. 重置状态
        speakerDetector.reset()
        isSessionActive = false
        isStarting = false
        statusMessage = "⚪️ 对话模式已退出"
    }
    
    // MARK: - Dual Viewport Data Push
    
    /// 向下半区推送转写文本 (Type 6)
    /// - Parameters:
    ///   - text: 语音识别转写文本
    ///   - isFinal: 句末标点断句标记 (true 立即定稿并触发向上滚屏; false 执行 150ms 节流打字机平滑更新)
    func pushTranscript(text: String, isFinal: Bool) {
        if isFinal {
            // 终态定稿断句：立即取消任何正在等待的打字节流，零延迟直穿下发
            transcriptThrottleWorkItem?.cancel()
            transcriptThrottleWorkItem = nil
            pendingTranscriptText = nil
            sendTranscriptDirect(text: text, isFinal: true)
            lastTranscriptPushTime = .now()
        } else {
            // 原位流式打字更新：严格执行 150ms 节流，杜绝冲爆 Even G2 蓝牙 FIFO
            pendingTranscriptText = text
            let now = DispatchTime.now()
            let elapsed = now.uptimeNanoseconds - lastTranscriptPushTime.uptimeNanoseconds
            
            if elapsed >= throttleIntervalNanoseconds {
                // 已满 150ms 冷却周期，立即直推
                transcriptThrottleWorkItem?.cancel()
                transcriptThrottleWorkItem = nil
                sendTranscriptDirect(text: text, isFinal: false)
                lastTranscriptPushTime = now
                pendingTranscriptText = nil
            } else if transcriptThrottleWorkItem == nil {
                // 尚在冷却期内，安排定时器在冷却期满时下发最新积攒状态
                let delay = Double(throttleIntervalNanoseconds - elapsed) / 1_000_000_000.0
                let item = DispatchWorkItem { [weak self] in
                    guard let self = self, let latest = self.pendingTranscriptText else { return }
                    self.sendTranscriptDirect(text: latest, isFinal: false)
                    self.lastTranscriptPushTime = .now()
                    self.pendingTranscriptText = nil
                    self.transcriptThrottleWorkItem = nil
                }
                transcriptThrottleWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            }
        }
    }
    
    private func sendTranscriptDirect(text: String, isFinal: Bool) {
        guard let ble = bleManager, ble.isConnected else { return }
        
        let speaker = speakerDetector.currentSpeaker
        let fullText = "\(speaker.prefix)\(text)"
        
        let pkt = G2ProtocolEncoder.buildConversateTranscript(seq: &seq, text: fullText, isFinal: isFinal)
        ble.sendRawData(pkt, channel: .content, logDesc: "下半区转写(\(isFinal ? "定稿" : "打字")): \(fullText)")
        
        if isFinal {
            // 显存锁存提交，使整句锁定并让 3 行视口平滑滚移
            let syncPkt = G2ProtocolEncoder.buildConversateSync(seq: &seq)
            ble.sendRawData(syncPkt, channel: .content, logDesc: "显存 Sync")
        }
        
        DispatchQueue.main.async {
            if isFinal {
                if !text.isEmpty {
                    self.transcriptHistory.append(fullText)
                    if text != "Even AI 对话助手已就绪" {
                        let utterance = ConversationUtterance(
                            speaker: speaker,
                            text: text,
                            timestamp: Date()
                        )
                        self.structuredUtterances.append(utterance)
                    }
                }
                self.currentTranscript = ""
            } else {
                self.currentTranscript = fullText
            }
        }
    }
    
    /// 向上半区推送极简 AI 药丸胶囊 (Type 5 - 平静技术单卡推送)
    /// - Parameters:
    ///   - rawTitle: 建议标题 (将自动净化为 8~12 汉字极简指令)
    ///   - detail: 结构化长文详情 (单击镜腿展开阅读)
    func pushAIPrompt(rawTitle: String, detail: String = "") {
        guard let ble = bleManager, ble.isConnected else { return }
        
        let card = promptManager.pushCard(msgId: Int(seq), rawTitle: rawTitle, detail: detail)
        
        let pkt = G2ProtocolEncoder.buildConversateAIPrompt(seq: &seq, title: card.title, detail: card.detail, cardType: 4)
        ble.sendRawData(pkt, channel: .content, logDesc: "上半区 AI 胶囊: \(card.title)")
        
        // 显存锁存
        let syncPkt = G2ProtocolEncoder.buildConversateSync(seq: &seq)
        ble.sendRawData(syncPkt, channel: .content, logDesc: "显存 Sync")
        
        // 🎧 耳机耳语同步播报 (仅佩戴耳机且开关打开时私密朗读，坚决不外放)
        audioWhisperManager.speakPrompt(card.title)
        
        DispatchQueue.main.async {
            self.lastSentTitle = card.title
            self.lastSentDetail = card.detail
        }
    }
    /// ASR 语音识别收音源 (用户可在左镜腿麦与手机高敏麦间自由选择)
    @Published var asrAudioSource: AudioSourceType = .phoneMic {
        didSet {
            if oldValue != asrAudioSource && isSessionActive {
                cleanRestartRecognitionTask(reason: "用户切换收音源至 \(asrAudioSource.rawValue)")
            }
        }
    }
    
    // MARK: - 长连 ASR 核心组件与游标切片状态 (提词模块同款长连架构)
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceWorkItem: DispatchWorkItem?
    private var isRestartingTask: Bool = false
    
    /// 已定稿提交的字符游标偏移量 (长连会话中持续推进，无需暴力杀掉任务)
    private var committedCharacterCount: Int = 0
    private var lastRawFormattedText: String = ""
    
    // MARK: - Audio Pipelines & ASR
    
    private func startAudioPipelines() {
        // 启动高保真单引擎流式识别
        startSpeechRecognition()
        
        // 1. 眼镜麦克风源 (16kHz LC3 PCM 流)
        let glassesSource = GlassesBLEAudioSource(bleManager: self.bleManager)
        glassesSource.onAudioBufferCaptured = { [weak self] buffer in
            guard let self = self else { return }
            self.speakerDetector.feedGlassesAudioBuffer(buffer)
            if self.asrAudioSource == .glassesMic {
                self.recognitionRequest?.append(buffer)
            }
        }
        try? glassesSource.start()
        self.glassesAudioSource = glassesSource
        
        // 2. 手机麦克风源 (双轨能量比对与桌面高精 ASR 流)
        let phoneSource = PhoneBuiltinAudioSource()
        phoneSource.onAudioBufferCaptured = { [weak self] buffer in
            guard let self = self else { return }
            self.speakerDetector.feedPhoneAudioBuffer(buffer)
            if self.asrAudioSource == .phoneMic {
                self.recognitionRequest?.append(buffer)
            }
        }
        try? phoneSource.start()
        self.phoneAudioSource = phoneSource
    }
    
    private func stopAudioPipelines() {
        glassesAudioSource?.stop()
        glassesAudioSource = nil
        phoneAudioSource?.stop()
        phoneAudioSource = nil
    }
    
    // MARK: - Speech Recognition Pipeline (提词模块同款长连高保真规范)
    
    private func startSpeechRecognition() {
        stopSpeechRecognition()
        
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            SFSpeechRecognizer.requestAuthorization { status in
                NSLog("🎤 [ConversateASR] 语音识别授权状态: %ld", status.rawValue)
            }
            return
        }
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.recognitionRequest = request
        self.committedCharacterCount = 0
        self.lastRawFormattedText = ""
        
        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            
            if let result = result {
                let fullRaw = result.bestTranscription.formattedString
                self.processStreamingTranscript(fullRaw)
            }
            
            if let err = error as NSError? {
                if err.code == 216 { return }
                NSLog("⚠️ [ConversateASR] 识别中断自愈 (Code=%ld): %@", err.code, err.localizedDescription)
                if self.isSessionActive && !self.isRestartingTask {
                    self.cleanRestartRecognitionTask(reason: "识别异常自愈")
                }
            } else if result?.isFinal == true {
                // 苹果单次识别会话达到系统生命周期上限 (通常 60~120 秒)
                NSLog("🏁 [ConversateASR] 识别引擎会话自然结束 (isFinal=true)，规范平滑续航")
                if let finalFull = result?.bestTranscription.formattedString {
                    self.finalizeRemainingTranscriptIfNeeded(fullText: finalFull)
                }
                if self.isSessionActive && !self.isRestartingTask {
                    self.cleanRestartRecognitionTask(reason: "会话自然续航")
                }
            }
        }
        
        NSLog("✅ [ConversateASR] 长连高保真语音识别已就绪 (源: %@)", asrAudioSource.rawValue)
    }
    
    /// 流式文本游标切片处理核心算法 (长连不重启，保证每一帧音频完整流入、上下文语义完整预测)
    private func processStreamingTranscript(_ fullRaw: String) {
        lastRawFormattedText = fullRaw
        
        // 防御性校验游标，防止极端情况下苹果模型回退修正导致游标越界
        if committedCharacterCount > fullRaw.count {
            committedCharacterCount = fullRaw.count
        }
        
        let uncommittedStartIndex = fullRaw.index(fullRaw.startIndex, offsetBy: committedCharacterCount)
        let uncommitted = String(fullRaw[uncommittedStartIndex...])
        
        let trimmedLeading = uncommitted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLeading.isEmpty else { return }
        
        // 1. 语义句末标点优先定稿 (。 ？！ ； \n)
        let sentenceEndings: [Character] = ["。", "！", "？", "!", "?", "；", ";", "\n"]
        if let endingIndex = uncommitted.firstIndex(where: { sentenceEndings.contains($0) }) {
            let sentenceEnd = uncommitted.index(after: endingIndex)
            let sentenceToCommit = String(uncommitted[..<sentenceEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            
            let commitLength = uncommitted.distance(from: uncommitted.startIndex, to: sentenceEnd)
            committedCharacterCount += commitLength
            
            silenceWorkItem?.cancel()
            silenceWorkItem = nil
            
            if !sentenceToCommit.isEmpty {
                NSLog("🎯 [ConversateASR] 标点自然断句定稿: '%@'", sentenceToCommit)
                self.pushTranscript(text: sentenceToCommit, isFinal: true)
            }
            
            // 检查该标点后是否已涌入后续新文字
            let remainder = String(uncommitted[sentenceEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty {
                self.pushTranscript(text: remainder, isFinal: false)
                self.scheduleSilenceFinalization(currentSentence: remainder, offsetAtSchedule: committedCharacterCount)
            }
            return
        }
        
        // 2. 长句逗号平滑分句 (未定稿文字超过 16 字且遇逗号)
        if uncommitted.count >= 16 {
            if let commaIdx = uncommitted.lastIndex(where: { $0 == "，" || $0 == "," || $0 == "、" }) {
                let dist = uncommitted.distance(from: uncommitted.startIndex, to: commaIdx)
                if dist >= 10 {
                    let commaNext = uncommitted.index(after: commaIdx)
                    let sentenceToCommit = String(uncommitted[..<commaNext]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let commitLength = uncommitted.distance(from: uncommitted.startIndex, to: commaNext)
                    committedCharacterCount += commitLength
                    
                    silenceWorkItem?.cancel()
                    silenceWorkItem = nil
                    
                    if !sentenceToCommit.isEmpty {
                        NSLog("🎯 [ConversateASR] 逗号舒适分句定稿: '%@'", sentenceToCommit)
                        self.pushTranscript(text: sentenceToCommit, isFinal: true)
                    }
                    
                    let remainder = String(uncommitted[commaNext...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !remainder.isEmpty {
                        self.pushTranscript(text: remainder, isFinal: false)
                        self.scheduleSilenceFinalization(currentSentence: remainder, offsetAtSchedule: committedCharacterCount)
                    }
                    return
                }
            }
        }
        
        // 3. 正常流式原位打字刷新 (严格 150ms 节流下发，杜绝丢包)
        self.pushTranscript(text: uncommitted.trimmingCharacters(in: .whitespacesAndNewlines), isFinal: false)
        
        // 4. 自然口语静音保护断句 (1.5 秒无新字到达且用户停顿)
        self.scheduleSilenceFinalization(currentSentence: uncommitted, offsetAtSchedule: committedCharacterCount)
    }
    
    private func scheduleSilenceFinalization(currentSentence: String, offsetAtSchedule: Int) {
        silenceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // 确保游标在此期间未被标点提前定稿
            guard self.committedCharacterCount == offsetAtSchedule else { return }
            
            let trimmed = currentSentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            
            NSLog("⏱️ [ConversateASR] 1.5s 口语停顿定稿: '%@'", trimmed)
            self.committedCharacterCount += currentSentence.count
            self.pushTranscript(text: trimmed, isFinal: true)
            
            // 提词模块同款优化：长篇对话累积超过 500 字且处于静音停顿期间，安全平滑重置一次识别会话
            if self.committedCharacterCount > 500 && !self.isRestartingTask {
                self.cleanRestartRecognitionTask(reason: "长篇对话静音重置")
            }
        }
        silenceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }
    
    private func finalizeRemainingTranscriptIfNeeded(fullText: String) {
        if committedCharacterCount < fullText.count {
            let startIdx = fullText.index(fullText.startIndex, offsetBy: committedCharacterCount)
            let remaining = String(fullText[startIdx...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !remaining.isEmpty {
                pushTranscript(text: remaining, isFinal: true)
            }
            committedCharacterCount = fullText.count
        }
    }
    
    private func cleanRestartRecognitionTask(reason: String) {
        guard isSessionActive && !isRestartingTask else { return }
        self.isRestartingTask = true
        
        silenceWorkItem?.cancel()
        silenceWorkItem = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self = self else { return }
            self.isRestartingTask = false
            guard self.isSessionActive else { return }
            self.startSpeechRecognition()
        }
    }
    
    private func stopSpeechRecognition() {
        transcriptThrottleWorkItem?.cancel()
        transcriptThrottleWorkItem = nil
        pendingTranscriptText = nil
        silenceWorkItem?.cancel()
        silenceWorkItem = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isRestartingTask = false
        committedCharacterCount = 0
        lastRawFormattedText = ""
    }
    
    // MARK: - Sync & Keepalive
    
    private func startSyncKeepaliveTimer() {
        stopSyncKeepaliveTimer()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self, let ble = self.bleManager, ble.isConnected, self.isSessionActive else { return }
            let syncPkt = G2ProtocolEncoder.buildConversateSync(seq: &self.seq)
            ble.sendRawData(syncPkt, channel: .content, logDesc: "5s 看门狗保活")
        }
    }
    
    private func stopSyncKeepaliveTimer() {
        syncTimer?.invalidate()
        syncTimer = nil
    }
}
