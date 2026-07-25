import SwiftUI

struct ContentView: View {
    @EnvironmentObject var bleManager: BLEManager
    @EnvironmentObject var speechEngine: SpeechFollowEngine
    @EnvironmentObject var webSocketClient: WebSocketClient
    @StateObject private var discoveryEngine = ServerDiscoveryEngine.shared
    
    @State private var serverAddress: String = "ws://192.168.8.59:8000/ws/session/sess_demo"
    @State private var selectedTab: Int = 0
    
    var currentHUDChunk: HUDDisplayChunk {
        let script = webSocketClient.currentPayload?.scriptText ?? "欢迎使用 Even G2 智慧课堂配套应用。请开启蓝牙连接眼镜并连接智慧课堂服务端。"
        let lines = HUDLayoutAdapter.shared.formatScriptToLines(script: script)
        let page = webSocketClient.currentPayload?.currentPage ?? 1
        let total = webSocketClient.currentPayload?.totalPages ?? 1
        let checkin = "签到 \(webSocketClient.currentPayload?.classroomStatus?.checkinCount ?? 0)/\(webSocketClient.currentPayload?.classroomStatus?.totalCount ?? 0)"
        
        return HUDLayoutAdapter.shared.buildHUDChunk(
            currentPage: page,
            totalPages: total,
            checkinText: checkin,
            lines: lines,
            activeLineIndex: speechEngine.activeLineIndex
        )
    }
    
    @State private var isFullScreenTeleprompter: Bool = true
    
    var body: some View {
        TabView(selection: $selectedTab) {
            // Tab 0 (默认): 智慧课堂主控台
            NavigationView {
                ScrollView {
                    VStack(spacing: 20) {
                        // 一键重置与唤醒 HUD 亮屏快捷按钮
                        VStack(spacing: 10) {
                            Button(action: {
                                bleManager.resetTeleprompterSession()
                            }) {
                                HStack {
                                    Image(systemName: "arrow.clockwise.circle.fill")
                                        .font(.title3)
                                    Text("🔄 重置 G2 蓝牙传输通道")
                                        .font(.headline)
                                        .fontWeight(.bold)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                            }
                        }
                        .padding(.horizontal)
                        
                        // 提词排版模式选择
                        Picker("眼镜显示模式", selection: $isFullScreenTeleprompter) {
                            Text("🖥️ 全屏满屏提词 (10行排满)").tag(true)
                            Text("🔍 3行 HUD 模式 (4行居中)").tag(false)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .padding(.horizontal)
                        .onChange(of: isFullScreenTeleprompter) { newValue in
                            triggerPushToGlasses()
                        }
                        
                        // HUD 模拟视口
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Even G2 绿光 HUD 模拟显存")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Toggle("HUD 显存激活", isOn: $bleManager.isHUDDisplayActive)
                                    .labelsHidden()
                                Text(bleManager.isHUDDisplayActive ? "🟢 显存渲染中" : "⚪ 息屏休眠")
                                    .font(.caption)
                                    .foregroundColor(bleManager.isHUDDisplayActive ? .green : .gray)
                            }
                            
                            HUDPreviewView(chunk: currentHUDChunk)
                        }
                        .padding(.horizontal)
                        
                        // 蓝牙连接快速状态栏
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .foregroundColor(.blue)
                                Text("Even G2 智能眼镜 (BLE)")
                                    .font(.headline)
                                Spacer()
                                Text(bleManager.isConnected ? "已连接" : (bleManager.isScanning ? "扫描中..." : "未连接"))
                                    .font(.subheadline)
                                    .foregroundColor(bleManager.isConnected ? .green : .orange)
                            }
                            
                            if let name = bleManager.connectedPeripheralName {
                                Text("当前设备: \(name)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Text(bleManager.lastBLEStatusMessage)
                                .font(.caption2)
                                .foregroundColor(bleManager.isConnected ? .blue : .gray)
                            
                            HStack {
                                Button(action: {
                                    if bleManager.isConnected {
                                        bleManager.disconnect()
                                    } else {
                                        bleManager.startScanning()
                                    }
                                }) {
                                    Text(bleManager.isConnected ? "断开蓝牙" : "扫描连接 Even G2")
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(bleManager.isConnected ? Color.red.opacity(0.1) : Color.blue)
                                        .foregroundColor(bleManager.isConnected ? .red : .white)
                                        .cornerRadius(8)
                                }
                            }
                        }
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)
                        
                        // 智慧课堂 WebSocket 连接设置
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "network")
                                    .foregroundColor(.purple)
                                Text("智慧课堂服务端 (WebSocket)")
                                    .font(.headline)
                                Spacer()
                                Text(webSocketClient.isConnected ? "已在线" : (discoveryEngine.isSearching ? "🔍 正在寻找服务端..." : "离线"))
                                    .font(.subheadline)
                                    .foregroundColor(webSocketClient.isConnected ? .green : .purple)
                            }
                            
                            HStack {
                                TextField("ws://服务器IP:8000/ws/session/ID", text: $serverAddress)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                                
                                Button(action: {
                                    discoveryEngine.startDiscovery { discoveredURL in
                                        self.serverAddress = discoveredURL
                                        self.webSocketClient.connect(urlString: discoveredURL)
                                    }
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "sparkles")
                                        Text("自动查找")
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(Color.purple.opacity(0.15))
                                    .foregroundColor(.purple)
                                    .cornerRadius(8)
                                }
                            }
                            
                            Button(action: {
                                if webSocketClient.isConnected {
                                    webSocketClient.disconnect()
                                    bleManager.resetTeleprompterSession()
                                } else {
                                    bleManager.resetTeleprompterSession()
                                    if let cleanURL = WebSocketClient.normalizeWebSocketURL(from: serverAddress) {
                                        self.serverAddress = cleanURL.absoluteString
                                        webSocketClient.connect(urlString: cleanURL.absoluteString)
                                    } else {
                                        webSocketClient.connect(urlString: serverAddress)
                                    }
                                }
                            }) {
                                Text(webSocketClient.isConnected ? "断开服务端" : "连接智慧课堂服务端")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(webSocketClient.isConnected ? Color.red.opacity(0.1) : Color.purple)
                                    .foregroundColor(webSocketClient.isConnected ? .purple : .white)
                                    .cornerRadius(8)
                            }
                        }
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)
                        
                        // 语音跟随控制卡片
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "mic.fill")
                                    .foregroundColor(.red)
                                Text("语音识别自动跟随 (ASR)")
                                    .font(.headline)
                                Spacer()
                                Toggle("", isOn: $speechEngine.isListening)
                                    .onChange(of: speechEngine.isListening) { newValue in
                                        if newValue {
                                            speechEngine.startListening()
                                        } else {
                                            speechEngine.stopListening()
                                        }
                                    }
                            }
                            
                            if !speechEngine.partialTranscript.isEmpty {
                                Text("实时识别: \(speechEngine.partialTranscript)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)
                        
                        // 手动控屏翻页测试
                        HStack(spacing: 16) {
                            Button(action: {
                                webSocketClient.sendPageControl(
                                    sessionId: webSocketClient.currentPayload?.sessionId ?? "sess_demo",
                                    action: "PREV",
                                    source: "MANUAL_TEST"
                                )
                            }) {
                                Label("上一页 (PREV)", systemImage: "chevron.left")
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.gray.opacity(0.2))
                                    .cornerRadius(10)
                            }
                            
                            Button(action: {
                                webSocketClient.sendPageControl(
                                    sessionId: webSocketClient.currentPayload?.sessionId ?? "sess_demo",
                                    action: "NEXT",
                                    source: "MANUAL_TEST"
                                )
                            }) {
                                Label("下一页 (NEXT)", systemImage: "chevron.right")
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.blue.opacity(0.2))
                                    .foregroundColor(.blue)
                                    .cornerRadius(10)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.vertical)
                }
                .navigationTitle("智慧课堂网关")
                .onAppear {
                    setupCallbacks()
                    discoveryEngine.startDiscovery { discoveredURL in
                        self.serverAddress = discoveredURL
                        if !self.webSocketClient.isConnected {
                            self.webSocketClient.connect(urlString: discoveredURL)
                        }
                    }
                }
                .onChange(of: bleManager.isConnected) { isConnected in
                    if isConnected && webSocketClient.currentPayload != nil {
                        self.triggerPushToGlasses()
                    }
                }
            }
            .navigationViewStyle(StackNavigationViewStyle())
            .tabItem {
                Label("课堂主控台", systemImage: "tv.fill")
            }
            .tag(0)
            
            // Tab 1: 所见即所得提词器 (官方 9 行高亮视窗 + 10..28 字宽度控制)
            NavigationView {
                ScrollView {
                    VStack(spacing: 20) {
                        TeleprompterWYSIWYGView()
                            .environmentObject(bleManager)
                    }
                    .padding(.top)
                }
                .navigationTitle("📖 所见即所得提词器")
            }
            .navigationViewStyle(StackNavigationViewStyle())
            .tabItem {
                Label("所见即所得提词", systemImage: "eye.fill")
            }
            .tag(1)
            
            // Tab 2: 专门的 G2 眼镜通讯与控制调试 Tab 页
            G2DebugView()
                .tabItem {
                    Label("G2 眼镜调试", systemImage: "eyeglasses")
                }
                .tag(2)
        }
    }
    
    private func setupCallbacks() {
        // Apple Watch 显存休眠/唤醒回调
        WatchSessionManager.shared.onDisplayToggleTriggered = { shouldWake in
            if shouldWake {
                bleManager.wakeHUD()
            } else {
                bleManager.sleepHUD()
            }
        }
        
        // Apple Watch 替代戒指唤醒 AI 对话与实时转录
        WatchSessionManager.shared.onAIChatTriggered = {
            print("Apple Watch 快捷触发 AI 对话问答")
        }
        
        WatchSessionManager.shared.onTranscribeTriggered = {
            speechEngine.isListening.toggle()
            if speechEngine.isListening {
                speechEngine.startListening()
            } else {
                speechEngine.stopListening()
            }
        }
        
        // Apple Watch 捏手指 / 屏幕触控 / 数字表冠回调 -> 触发大屏翻页
        WatchSessionManager.shared.onPageControlTriggered = { action, source in
            webSocketClient.sendPageControl(
                sessionId: webSocketClient.currentPayload?.sessionId ?? "sess_demo",
                action: action,
                source: source
            )
        }
        
        // BLE 手势触控回调 -> 触发大屏翻页
        bleManager.onPageControlTriggered = { action in
            webSocketClient.sendPageControl(
                sessionId: webSocketClient.currentPayload?.sessionId ?? "sess_demo",
                action: action,
                source: "BLE_GESTURE"
            )
        }
        
        // G2 蓝牙实时报文向 Python 服务端上报回调
        bleManager.onG2TelemetryLog = { direction, hexBytes, desc in
            webSocketClient.sendG2TelemetryLog(direction: direction, hexBytes: hexBytes, description: desc)
        }
        
        // 语音识别尾部关键词 -> 触发大屏自动翻页
        speechEngine.onVoiceKeywordTriggered = { action in
            webSocketClient.sendPageControl(
                sessionId: webSocketClient.currentPayload?.sessionId ?? "sess_demo",
                action: action,
                source: "VOICE_KEYWORD"
            )
        }
        
        // 智慧课堂推送新逐字稿 -> 检测 Slide 文本变更，安全自动更新眼镜屏显 (防范重复握手黑屏)
        webSocketClient.onTeleprompterSyncReceived = { payload in
            speechEngine.loadSlideScript(script: payload.scriptText, keywords: payload.endKeywords)
            
            // 同步给 Apple Watch
            WatchSessionManager.shared.syncStateToWatch(
                currentPage: payload.currentPage,
                totalPages: payload.totalPages,
                isServerConnected: webSocketClient.isConnected
            )
            
            // 无条件推屏: 只要收到服务端 Sync 报文，确保眼镜屏显 100% 刷新展示
            self.triggerPushToGlasses()
        }
    }
    
    private func triggerPushToGlasses() {
        guard let payload = webSocketClient.currentPayload else { return }
        
        if isFullScreenTeleprompter {
            // 全屏满屏提词模式: 10 行/页从上到下排满 267px G2 镜片视口
            bleManager.sendFullScreenTeleprompterText(payload.scriptText)
        } else {
            // 3 行 HUD 模式: 4 行居中极简
            let chunk = HUDLayoutAdapter.shared.buildHUDChunk(
                currentPage: payload.currentPage,
                totalPages: payload.totalPages,
                checkinText: "签到 \(payload.classroomStatus?.checkinCount ?? 0)/\(payload.classroomStatus?.totalCount ?? 0)",
                lines: HUDLayoutAdapter.shared.formatScriptToLines(script: payload.scriptText),
                activeLineIndex: 0
            )
            bleManager.sendHUDFrame(chunk: chunk)
        }
    }
}

// MARK: - 官方级“所见即所得” 9 行高亮视窗提词器 View
struct TeleprompterWYSIWYGView: View {
    @EnvironmentObject var bleManager: BLEManager
    
    @State private var teleprompterText: String = """
各位领导、各位老师，大家上午好！
今天我们召开《人机协同程序设计》课程全校统一数智化教学集体备课研讨会，主要目的是为了贯彻落实教务处文件精神，面向各理工科学院及医学院负责该课程授课的全体老师，共同研讨教学规范，明确教学要求，并合力推进标准化教学资源的建设。
我们这门课程定位为跨界通识课，将在 2026 年秋季学期，也就是今年 9 月份正式开课。课程设置可能是 2.0 或 3.0 学分，对应 32 或 48 学时。今天我将围绕本门课程的建设思路、教学策略、考核改革以及资源保障等方面，与各位老师进行深入的探讨与交流。

首先，我们来看一下执行摘要的第一部分，关于课程的痛点与定位。
为了响应全校“专业+AI”的培养大势，我们采用了每周“2+2”的理实一体课时设置：包含 2 学时理论、2 学时实践，以及 2 学时课后协同大作业。这旨在通过“人机协同”与“人际协同”的双重训练，补足大一新生在传统应试教育中匮乏的核心沟通协作本领。
我们针对两大痛点：非专业学生因为学习曲线陡峭，往往未入门即放弃；而专业学生偏重底层刷题，极易在未来被 AI 取代。
因此，本课程重新确立了“人在回路（HOTL）”的核心培养定位。
"""
    
    /// 显示区域宽度（10..28 个汉字）
    @State private var targetWidthChars: Double = 11.0
    /// 当前在 App 上手动拖动的偏移量
    @State private var scrollLineOffset: Int = 0
    
    var body: some View {
        VStack(spacing: 16) {
            // 1. 顶部控制条 (可变显示区域宽度调节)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "ruler.fill")
                        .foregroundColor(.blue)
                    Text("显示区域宽度调节:")
                        .font(.subheadline)
                        .fontWeight(.bold)
                    Spacer()
                    Text("\(Int(targetWidthChars)) 个汉字/行")
                        .font(.subheadline)
                        .fontWeight(.heavy)
                        .foregroundColor(.blue)
                }
                
                Slider(value: $targetWidthChars, in: 10...28, step: 1) {
                    Text("宽度")
                } minimumValueLabel: {
                    Text("10字").font(.caption).foregroundColor(.gray)
                } maximumValueLabel: {
                    Text("28字").font(.caption).foregroundColor(.gray)
                }
                .onChange(of: targetWidthChars) { newValue in
                    triggerPush()
                }
                
                Text("物理字号恒定为 23px，改变显示宽度可容纳不同字数")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(10)
            
            // 2. 10 行“所见即所得”高亮视窗
            let result = G2ProtocolEncoder.formatTextToPages(teleprompterText, maxCharsPerLine: Int(targetWidthChars))
            let wrappedLines = result.wrappedLines
            
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("9 行高亮“所见即所得”提词视窗", systemImage: "eye.fill")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("同步行: \(bleManager.currentFocusPageLine)")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
                
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(0..<wrappedLines.count, id: \.self) { index in
                                let isHighlighted = (index >= scrollLineOffset && index < scrollLineOffset + 9)
                                
                                HStack {
                                    Text(wrappedLines[index])
                                        .font(.system(size: 15, weight: isHighlighted ? .bold : .regular, design: .default))
                                        .foregroundColor(isHighlighted ? .primary : .secondary.opacity(0.4))
                                        .padding(.vertical, 2)
                                        .padding(.horizontal, 8)
                                    Spacer()
                                }
                                .background(isHighlighted ? Color.white : Color.clear)
                                .cornerRadius(isHighlighted ? 4 : 0)
                                .shadow(color: isHighlighted ? Color.black.opacity(0.08) : Color.clear, radius: 2, x: 0, y: 1)
                                .id(index)
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                    }
                    .frame(height: 280)
                    .background(Color(UIColor.tertiarySystemBackground))
                    .cornerRadius(12)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let lineDelta = Int(-value.translation.height / 25)
                                let newOffset = max(0, min(wrappedLines.count - 9, scrollLineOffset + lineDelta))
                                if newOffset != scrollLineOffset {
                                    scrollLineOffset = newOffset
                                    bleManager.sendScrollSync(pageLine: scrollLineOffset)
                                }
                            }
                    )
                    .onChange(of: bleManager.currentFocusPageLine) { newLine in
                        scrollLineOffset = newLine
                        withAnimation {
                            proxy.scrollTo(newLine, anchor: .top)
                        }
                    }
                }
            }
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
            
            // 3. 推送与控制按钮
            HStack(spacing: 12) {
                Button(action: { triggerPush() }) {
                    HStack {
                        Image(systemName: "paperplane.fill")
                        Text("推屏至 Even G2")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.purple)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
            }
        }
        .padding(.horizontal)
    }
    
    private func triggerPush() {
        bleManager.sendTeleprompterText(teleprompterText, targetWidthChars: Int(targetWidthChars))
    }
}
