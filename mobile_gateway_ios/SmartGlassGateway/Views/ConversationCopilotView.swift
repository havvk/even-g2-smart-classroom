import SwiftUI

/// Even G2 对话模式数字孪生与控制看板 (Conversation Copilot View)
struct ConversationCopilotView: View {
    @ObservedObject var copilotManager = ConversationCopilotManager.shared
    @ObservedObject var promptManager = AICopilotPromptManager.shared
    @ObservedObject var speakerDetector = DualTrackSpeakerDetector.shared
    @ObservedObject var bleManager = BLEManager.shared
    @ObservedObject var whisperManager = AudioWhisperPromptManager.shared
    
    @State private var inputPromptTitle: String = "💡 建议: 先确认交付工期"
    @State private var inputPromptDetail: String = "1. 二期硬件需前置采购芯片\n2. 建议预留 3 周联调缓冲期"
    @State private var inputTranscriptText: String = "关于本次方案的核心架构与排期..."
    @State private var showingDrawerSheet: Bool = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // MARK: - 1. 顶栏状态指示
                headerSection
                
                // MARK: - 1.5 上次会话纪要与转写入口
                if copilotManager.lastSessionRecord != nil {
                    lastSessionSummarySection
                }
                
                // MARK: - 2. HUD 1:1 数字孪生视口
                hudDigitalTwinSection
                
                // MARK: - 3. 双轨麦克风能量与说话人判别
                speakerDetectorSection
                
                // MARK: - 3.5 高保真实时语音听写流水视窗
                liveTranscriptStreamSection
                
                // MARK: - 3.8 耳机私密耳语播报 (自动硬件感知)
                audioWhisperSection
                
                // MARK: - 4. 快捷控制与模拟注入
                controlAndSimulationSection
                
                // MARK: - 5. 20 槽位历史卡片抽屉入口
                drawerSection
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Even G2 对话 Copilot")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingDrawerSheet) {
            drawerDetailSheet
        }
        .sheet(isPresented: $copilotManager.showingSummarySheet) {
            if let record = copilotManager.lastSessionRecord {
                ConversationSummarySheetView(record: record)
            }
        }
        .onAppear {
            whisperManager.ensureAudioSessionActive()
        }
    }
    
    // MARK: - Subviews
    
    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Even G2 对话伴侣 (Service 0x0B-20)")
                    .font(.headline)
                Text(copilotManager.statusMessage)
                    .font(.subheadline)
                    .foregroundColor(copilotManager.isSessionActive ? .green : .secondary)
            }
            Spacer()
            
            Button(action: {
                if copilotManager.isSessionActive {
                    copilotManager.stopSession()
                } else {
                    copilotManager.startSession()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: copilotManager.isSessionActive ? "stop.circle.fill" : "play.circle.fill")
                    Text(copilotManager.isSessionActive ? "退出对话" : (copilotManager.isStarting ? "启动中..." : "开启对话"))
                }
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(copilotManager.isSessionActive ? Color.red : Color.green)
                .foregroundColor(.white)
                .cornerRadius(20)
            }
            .disabled(copilotManager.isStarting || !bleManager.isConnected)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    /// MicroLED 1:1 双视口数字孪生
    private var hudDigitalTwinSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("MicroLED 光学双视口 1:1 实时孪生", systemImage: "eyeglasses")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Text("绿色单色 HUD (267点阵宽)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            ZStack {
                // 纯黑透光背景 (模拟 MicroLED 显示屏全黑不发光, 严格对应 G2 200px 物理光学视口)
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black)
                    .frame(height: 195)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.green.opacity(0.3), lineWidth: 1)
                    )
                
                VStack(spacing: 0) {
                    // MARK: - Region A (上半区: AI 建议微标签与展开卡片)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Region A (上半区: AI 建议微标签)")
                                .font(.system(size: 10))
                                .foregroundColor(.green.opacity(0.5))
                            Spacer()
                            if let card = promptManager.activeCard, card.isExpanded {
                                Text("🌟 已触控展开")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.yellow)
                            }
                        }
                        
                        if let card = promptManager.activeCard {
                            VStack(alignment: .leading, spacing: 4) {
                                // 极简药丸胶囊外框
                                HStack {
                                    Text(card.title)
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        .foregroundColor(Color(red: 0.3, green: 1.0, blue: 0.3))
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.green, lineWidth: 1.2)
                                )
                                
                                // 展开后的详情
                                if card.isExpanded && !card.detail.isEmpty {
                                    Text(card.detail)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(Color.green.opacity(0.85))
                                        .padding(.leading, 4)
                                        .lineLimit(3)
                                }
                            }
                        } else {
                            HStack {
                                Text("（无弹出建议，现实视野全透光）")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.gray.opacity(0.6))
                                Spacer()
                            }
                            .padding(.vertical, 6)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    
                    Spacer(minLength: 8) // 弹性透光区: 将 Region B 紧压在镜显底部
                    
                    // 虚线分割线 (极细单色透光隔离)
                    Rectangle()
                        .fill(Color.green.opacity(0.15))
                        .frame(height: 1)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                    
                    // MARK: - Region B (下半区: 严格固化镜显底端 3 行滚动视口)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Region B (镜显底端固定 3 行)")
                                .font(.system(size: 9))
                                .foregroundColor(.green.opacity(0.4))
                            Spacer()
                        }
                        
                        let history = copilotManager.transcriptHistory
                        let line1 = history.count >= 2 ? history[history.count - 2] : ""
                        let line2 = history.count >= 1 ? history[history.count - 1] : ""
                        let line3 = copilotManager.currentTranscript.isEmpty ? "（等待发音...）" : copilotManager.currentTranscript
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line1.isEmpty ? " " : line1)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Color.green.opacity(0.25))
                                .lineLimit(1)
                            
                            Text(line2.isEmpty ? " " : line2)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Color.green.opacity(0.50))
                                .lineLimit(1)
                            
                            Text(line3)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(Color(red: 0.3, green: 1.0, blue: 0.3))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    /// 双轨麦克风能量与说话人判定
    private var speakerDetectorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("双轨麦克风能量与说话人分离", systemImage: "waveform.path.ecg")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
            
            // ASR 识别收音源选择
            HStack {
                Text("转写收音源:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Picker("收音源", selection: $copilotManager.asrAudioSource) {
                    Text("左镜腿麦").tag(AudioSourceType.glassesMic)
                    Text("手机麦 (高敏)").tag(AudioSourceType.phoneMic)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
            }
            
            HStack(spacing: 16) {
                // 眼镜麦克风
                VStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Text("左镜腿 GlassesMic")
                            .font(.caption)
                        if copilotManager.asrAudioSource == .glassesMic {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.green)
                        }
                    }
                    ProgressView(value: speakerDetector.glassesLevel, total: 1.0)
                        .tint(.green)
                    Text("\(Int(speakerDetector.glassesLevel * 100))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                // 能量比值徽章
                VStack(spacing: 4) {
                    Text("当前说话人")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(speakerDetector.currentSpeaker.rawValue)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(speakerDetector.currentSpeaker == .me ? .green : (speakerDetector.currentSpeaker == .guest ? .blue : .gray))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(Color(.tertiarySystemFill))
                        )
                    Text("Ratio: \(String(format: "%.1f", speakerDetector.energyRatio))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                // 手机麦克风
                VStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Text("手机 PhoneMic")
                            .font(.caption)
                        if copilotManager.asrAudioSource == .phoneMic {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.blue)
                        }
                    }
                    ProgressView(value: speakerDetector.phoneLevel, total: 1.0)
                        .tint(.blue)
                    Text("\(Int(speakerDetector.phoneLevel * 100))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    /// 高保真实时语音听写流水视窗 (对齐提词模块成熟高精度引擎)
    private var liveTranscriptStreamSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("实时语音转写视窗", systemImage: "waveform.badge.magnifyingglass")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Text(copilotManager.isSessionActive ? "🟢 正在收音" : "⚪️ 待机")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            // 当前实时听写打字卡片
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("实时打字流:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("收音源: \(copilotManager.asrAudioSource.rawValue)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(copilotManager.asrAudioSource == .phoneMic ? .blue : .green)
                }
                
                if copilotManager.currentTranscript.isEmpty {
                    Text("请对麦克风讲话，语音文字将在此实时流式呈现...")
                        .font(.subheadline)
                        .foregroundColor(Color(.placeholderText))
                        .italic()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    Text(copilotManager.currentTranscript)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(speakerDetector.currentSpeaker == .me ? .green : (speakerDetector.currentSpeaker == .guest ? .blue : .primary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }
            }
            .padding()
            .background(Color(.systemBackground))
            .cornerRadius(10)
            
            // 历史定稿句子流水
            if !copilotManager.transcriptHistory.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("已定稿句子 (已同步推送到眼镜视口):")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    ForEach(Array(copilotManager.transcriptHistory.suffix(4).enumerated()), id: \.offset) { _, sentence in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .padding(.top, 3)
                            Text(sentence)
                                .font(.caption)
                                .foregroundColor(.primary)
                        }
                    }
                }
                .padding(10)
                .background(Color(.systemBackground).opacity(0.6))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    /// 耳机私密耳语播报卡片 (戴耳机自动开启，拔出耳机自动静音)
    private var audioWhisperSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("耳机耳语播报 (Audio Whisper)", systemImage: "headphones")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                
                // 耳机硬件状态指示徽章
                HStack(spacing: 4) {
                    Circle()
                        .fill(whisperManager.isHeadphonesConnected ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(whisperManager.connectedHeadphoneName)
                        .font(.caption2)
                        .foregroundColor(whisperManager.isHeadphonesConnected ? .primary : .secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.tertiarySystemFill))
                .cornerRadius(12)
            }
            
            // 播放 AI 提示开关
            Toggle(isOn: $whisperManager.isAudioPromptEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("播放 AI 提示")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("戴上耳机自动开启；取下或断开时自动关闭，坚决不公放")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .tint(.green)
            
            // 发音人指定与下拉选择
            HStack {
                Label("指定发音人", systemImage: "person.wave.2.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                
                if !whisperManager.siriMainlandVoicesList.isEmpty || !whisperManager.officialPremiumVoicesList.isEmpty {
                    Menu {
                        // 1. Siri 大陆普通话 (Voice 1~4)
                        Section("🎙️ Siri - Mandarin (China mainland)") {
                            ForEach(whisperManager.siriMainlandVoicesList) { item in
                                Button(action: {
                                    whisperManager.selectSystemVoiceItem(item)
                                }) {
                                    HStack {
                                        Text("\(item.name) (\(item.detail))")
                                        if whisperManager.selectedVoiceItemId == item.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                        
                        // 2. Siri 台湾普通话 (Voice 1~2)
                        Section("🇹🇼 Siri - Mandarin (Taiwan)") {
                            ForEach(whisperManager.siriTaiwanVoicesList) { item in
                                Button(action: {
                                    whisperManager.selectSystemVoiceItem(item)
                                }) {
                                    HStack {
                                        Text("\(item.name) (\(item.detail))")
                                        if whisperManager.selectedVoiceItemId == item.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                        
                        // 3. Siri 香港粤语 (浩贤 / 嘉欣)
                        if !whisperManager.siriHongKongVoicesList.isEmpty {
                            Section("🇭🇰 Siri - Cantonese (Hong Kong)") {
                                ForEach(whisperManager.siriHongKongVoicesList) { item in
                                    Button(action: {
                                        whisperManager.selectSystemVoiceItem(item)
                                    }) {
                                        HStack {
                                            Text("\(item.name) (\(item.detail))")
                                            if whisperManager.selectedVoiceItemId == item.id {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        
                        // 4. Siri 英语全系列 (美式 1~5 / 英式 1~4 / 澳式 1~4 / 爱尔兰 1~2 / 南非 1~2 共 17 个发音人)
                        if !whisperManager.siriEnglishVoicesList.isEmpty {
                            Menu("🌐 Siri - English (全部 17 个发音人)") {
                                Section("🇺🇸 Siri - English (US)") {
                                    ForEach(whisperManager.siriEnglishVoicesList.filter { $0.fallbackLanguage == "en-US" }) { item in
                                        Button(action: { whisperManager.selectSystemVoiceItem(item) }) {
                                            HStack {
                                                Text("\(item.name) (\(item.detail))")
                                                if whisperManager.selectedVoiceItemId == item.id { Image(systemName: "checkmark") }
                                            }
                                        }
                                    }
                                }
                                Section("🇬🇧 Siri - English (UK)") {
                                    ForEach(whisperManager.siriEnglishVoicesList.filter { $0.fallbackLanguage == "en-GB" }) { item in
                                        Button(action: { whisperManager.selectSystemVoiceItem(item) }) {
                                            HStack {
                                                Text("\(item.name) (\(item.detail))")
                                                if whisperManager.selectedVoiceItemId == item.id { Image(systemName: "checkmark") }
                                            }
                                        }
                                    }
                                }
                                Section("🇦🇺 Siri - English (Australia)") {
                                    ForEach(whisperManager.siriEnglishVoicesList.filter { $0.fallbackLanguage == "en-AU" }) { item in
                                        Button(action: { whisperManager.selectSystemVoiceItem(item) }) {
                                            HStack {
                                                Text("\(item.name) (\(item.detail))")
                                                if whisperManager.selectedVoiceItemId == item.id { Image(systemName: "checkmark") }
                                            }
                                        }
                                    }
                                }
                                Section("🇮🇪 Siri - English (Ireland)") {
                                    ForEach(whisperManager.siriEnglishVoicesList.filter { $0.fallbackLanguage == "en-IE" }) { item in
                                        Button(action: { whisperManager.selectSystemVoiceItem(item) }) {
                                            HStack {
                                                Text("\(item.name) (\(item.detail))")
                                                if whisperManager.selectedVoiceItemId == item.id { Image(systemName: "checkmark") }
                                            }
                                        }
                                    }
                                }
                                Section("🇿🇦 Siri - English (South Africa)") {
                                    ForEach(whisperManager.siriEnglishVoicesList.filter { $0.fallbackLanguage == "en-ZA" }) { item in
                                        Button(action: { whisperManager.selectSystemVoiceItem(item) }) {
                                            HStack {
                                                Text("\(item.name) (\(item.detail))")
                                                if whisperManager.selectedVoiceItemId == item.id { Image(systemName: "checkmark") }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        
                        // 5. 苹果官方 Siri 日语发音人 (Hiro / Sakura · 官方仅此类为 Premium 神经网络级)
                        if !whisperManager.siriJapaneseVoicesList.isEmpty {
                            Section("🇯🇵 Siri - Japanese (日本語 · 官方旗舰)") {
                                ForEach(whisperManager.siriJapaneseVoicesList) { item in
                                    Button(action: {
                                        whisperManager.selectSystemVoiceItem(item)
                                    }) {
                                        HStack {
                                            Text("\(item.name) (\(item.detail))")
                                            if whisperManager.selectedVoiceItemId == item.id {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        
                        // 6. 苹果官方 Siri 韩语发音人 (Jinsoo / Minji)
                        if !whisperManager.siriKoreanVoicesList.isEmpty {
                            Section("🇰🇷 Siri - Korean (한국어)") {
                                ForEach(whisperManager.siriKoreanVoicesList) { item in
                                    Button(action: {
                                        whisperManager.selectSystemVoiceItem(item)
                                    }) {
                                        HStack {
                                            Text("\(item.name) (\(item.detail))")
                                            if whisperManager.selectedVoiceItemId == item.id {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        
                        // 7. 苹果官方 Premium 旗舰声音 (中文与粤语)
                        Section("🌟 Premium Voices (中文与粤语)") {
                            ForEach(whisperManager.officialPremiumVoicesList) { item in
                                Button(action: {
                                    whisperManager.selectSystemVoiceItem(item)
                                }) {
                                    HStack {
                                        Text("\(item.name) (\(item.detail))")
                                        if whisperManager.selectedVoiceItemId == item.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                        
                        // 8. 苹果官方 Premium 旗舰声音 (English)
                        if !whisperManager.premiumEnglishVoicesList.isEmpty {
                            Section("🌟 Premium Voices (English)") {
                                ForEach(whisperManager.premiumEnglishVoicesList) { item in
                                    Button(action: {
                                        whisperManager.selectSystemVoiceItem(item)
                                    }) {
                                        HStack {
                                            Text("\(item.name) (\(item.detail))")
                                            if whisperManager.selectedVoiceItemId == item.id {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        
                        // 9. 苹果官方 Premium 旗舰声音 (Korean · 한국어)
                        if !whisperManager.premiumKoreanVoicesList.isEmpty {
                            Section("🌟 Premium Voices (Korean · 한국어)") {
                                ForEach(whisperManager.premiumKoreanVoicesList) { item in
                                    Button(action: {
                                        whisperManager.selectSystemVoiceItem(item)
                                    }) {
                                        HStack {
                                            Text("\(item.name) (\(item.detail))")
                                            if whisperManager.selectedVoiceItemId == item.id {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        
                        // 10. 重新同步系统
                        Section {
                            Button(action: {
                                whisperManager.refreshActiveVoice()
                            }) {
                                Label("重新同步系统发音人", systemImage: "arrow.clockwise")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(whisperManager.activeVoiceDescription)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.green)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color(.tertiarySystemFill))
                        .cornerRadius(6)
                    }
                } else {
                    Text(whisperManager.activeVoiceDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Button(whisperManager.chineseVoice == nil ? "未安装" : "试听") {
                    whisperManager.speakSamplePrompt()
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .disabled(!whisperManager.isHeadphonesConnected || whisperManager.chineseVoice == nil)
            }
            .padding(.top, 2)
            
            Divider()
                .padding(.vertical, 2)
            
            // MARK: - 高保真防抖缓冲播放 (彻底杜绝 5.3ms 蓝牙硬件下溢毛刺)
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $whisperManager.isPreSynthesizeModeEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text("高保真防抖缓冲 (整句预生成推流)")
                                .font(.system(size: 12, weight: .medium))
                            Text(whisperManager.isPreSynthesizeModeEnabled ? "极度平滑" : "实时流式")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(whisperManager.isPreSynthesizeModeEnabled ? .green : .orange)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background((whisperManager.isPreSynthesizeModeEnabled ? Color.green : Color.orange).opacity(0.15))
                                .cornerRadius(4)
                        }
                        Text("后台极速整句预渲染完成后饱满推流，物理杜绝 AirPods 等蓝牙耳机 5.3ms 硬件缓冲区下溢毛刺")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
                .tint(.green)
                .disabled(!whisperManager.isHeadphonesConnected)
            }
            
            if whisperManager.chineseVoice == nil {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundColor(.red)
                    Text("提示：当前选中的发音人尚未在 iPhone 下载。系统严格拒绝任何静默降级替代，请在 iPhone「设置 ➔ 辅助功能/Siri」中下载该发音人后使用。")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                }
                .padding(.top, 2)
            }
            
            if !whisperManager.isHeadphonesConnected {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.slash.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text("当前未检测到耳机，扬声器已锁定静音，杜绝外放与回声啸叫")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 2)
            } else {
                Text("💡 若想获得极致拟真真人人声，可在 iPhone「设置 ➔ 辅助功能 ➔ 朗读内容 ➔ 声音 ➔ 中文」中免费下载“优质/高级神经网络”声音包，App 将自动秒级识别并在上方菜单中呈现。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.8))
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    /// 模拟测试与控制
    private var controlAndSimulationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("真机调试与模拟注入", systemImage: "terminal")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            VStack(spacing: 10) {
                // AI 胶囊注入
                HStack {
                    TextField("极简标题 (8~12字)", text: $inputPromptTitle)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .font(.subheadline)
                    
                    Button("下发 AI 胶囊") {
                        copilotManager.pushAIPrompt(rawTitle: inputPromptTitle, detail: inputPromptDetail)
                    }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .disabled(!copilotManager.isSessionActive)
                }
                
                TextField("展开详情 (多行换行)", text: $inputPromptDetail)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.caption)
                
                Divider()
                
                // 转写注入
                HStack {
                    TextField("转写文本内容", text: $inputTranscriptText)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .font(.subheadline)
                    
                    Button("推送转写") {
                        copilotManager.pushTranscript(text: inputTranscriptText, isFinal: true)
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .disabled(!copilotManager.isSessionActive)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    /// 20 槽位历史卡片抽屉入口
    private var drawerSection: some View {
        Button(action: { showingDrawerSheet = true }) {
            HStack {
                Image(systemName: "tray.full.fill")
                    .foregroundColor(.green)
                Text("查看镜腿 20 槽位硬件抽屉卡片")
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Spacer()
                Text("\(promptManager.drawerCards.count) / 20 条")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
        }
    }
    
    /// 抽屉详情弹窗
    private var drawerDetailSheet: some View {
        NavigationView {
            List {
                if promptManager.drawerCards.isEmpty {
                    Text("镜腿抽屉暂无卡片，下发 AI 胶囊后将自动保存在此（上限 20 条）")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(promptManager.drawerCards.reversed()) { card in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(card.title)
                                    .font(.headline)
                                Spacer()
                                if card.isExpanded {
                                    Text("🌟 已展开")
                                        .font(.caption2)
                                        .foregroundColor(.green)
                                }
                            }
                            if !card.detail.isEmpty {
                                Text(card.detail)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            Text(card.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("镜腿 20 槽位卡片抽屉 (FIFO)")
            .navigationBarItems(trailing: Button("关闭") { showingDrawerSheet = false })
        }
    }
    
    /// 上次对话纪要与转写入口卡片
    private var lastSessionSummarySection: some View {
        Group {
            if let record = copilotManager.lastSessionRecord {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("上次对话纪要与转写", systemImage: "doc.text.magnifyingglass")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(record.stats.formattedDuration)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    Button(action: { copilotManager.showingSummarySheet = true }) {
                        HStack(spacing: 12) {
                            Image(systemName: "sparkles.rectangle.stack.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.green)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.summary?.topic ?? "讨论交流中...")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                
                                Text("共 \(record.utterances.count) 轮发言 · \(record.stats.totalWords) 字 · 点击查看纪要与转写")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(12)
                        .background(Color(.systemBackground))
                        .cornerRadius(10)
                    }
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(12)
            }
        }
    }
}
