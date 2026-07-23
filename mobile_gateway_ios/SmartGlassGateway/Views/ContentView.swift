import SwiftUI

struct ContentView: View {
    @EnvironmentObject var bleManager: BLEManager
    @EnvironmentObject var speechEngine: SpeechFollowEngine
    @EnvironmentObject var webSocketClient: WebSocketClient
    @StateObject private var discoveryEngine = ServerDiscoveryEngine.shared
    
    @State private var serverAddress: String = "ws://192.168.1.100:8000/ws/session/sess_demo"
    
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
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // HUD 模拟视口
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Even G2 绿光 HUD 模拟显存")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        HUDPreviewView(chunk: currentHUDChunk)
                    }
                    .padding(.horizontal)
                    
                    // 蓝牙连接控制卡片
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
                            } else {
                                webSocketClient.connect(urlString: serverAddress)
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
            .navigationTitle("Even G2 网关")
            .onAppear {
                setupCallbacks()
                discoveryEngine.startDiscovery { discoveredURL in
                    self.serverAddress = discoveredURL
                    self.webSocketClient.connect(urlString: discoveredURL)
                }
            }
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
        
        // 语音识别尾部关键词 -> 触发大屏自动翻页
        speechEngine.onVoiceKeywordTriggered = { action in
            webSocketClient.sendPageControl(
                sessionId: webSocketClient.currentPayload?.sessionId ?? "sess_demo",
                action: action,
                source: "VOICE_KEYWORD"
            )
        }
        
        // 智慧课堂推送新逐字稿 -> 重置语音与 HUD 显存并同步到 Apple Watch
        webSocketClient.onTeleprompterSyncReceived = { payload in
            speechEngine.loadSlideScript(script: payload.scriptText, keywords: payload.endKeywords)
            
            // 同步给 Apple Watch
            WatchSessionManager.shared.syncStateToWatch(
                currentPage: payload.currentPage,
                totalPages: payload.totalPages,
                isServerConnected: webSocketClient.isConnected
            )
            
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
