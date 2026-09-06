import SwiftUI
import CoreBluetooth

struct ContentView: View {
    @EnvironmentObject var bleManager: BLEManager
    @EnvironmentObject var webSocketClient: WebSocketClient
    @EnvironmentObject var speechEngine: SpeechFollowEngine
    @State private var showingControlCenter: Bool = false
    @State private var showingSmartClass: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            // 吸顶全局状态条
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(bleManager.isNotifyReady ? Color.green : (bleManager.isConnected ? Color.orange : Color.red))
                        .frame(width: 8, height: 8)
                    Text(bleManager.isNotifyReady ? "🟢 G2 就绪" : (bleManager.isConnected ? "🟡 握手中" : "🔴 眼镜未连"))
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                
                Spacer()
                
                // 🎙️ 全局常驻 Mic 音源切换胶囊 (二选一即触即切)
                AudioSourceToggleCapsule(speechEngine: speechEngine)
                
                Spacer()
                
                Button(action: {
                    showingSmartClass.toggle()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "graduationcap.fill")
                        Text("智慧课堂")
                    }
                    .font(.caption)
                    .fontWeight(.bold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.purple.opacity(0.15))
                    .foregroundColor(.purple)
                    .cornerRadius(6)
                }
                
                Spacer()
                
                Button(action: {
                    showingControlCenter.toggle()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                        Text("控制中心")
                    }
                    .font(.caption)
                    .fontWeight(.bold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.15))
                    .foregroundColor(.blue)
                    .cornerRadius(6)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(UIColor.tertiarySystemBackground))
            
            Divider()
            
            // 顶部眼镜 4 大工作模式 Segmented Picker (Glasses State Machine)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(GlassesState.allCases.filter { $0 != .disconnected }) { state in
                        Button(action: {
                            bleManager.switchMode(to: state)
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: state.iconName)
                                Text(state.rawValue)
                            }
                            .font(.system(size: 12, weight: .bold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(bleManager.currentGlassesState == state ? Color.blue : Color.gray.opacity(0.15))
                            .foregroundColor(bleManager.currentGlassesState == state ? .white : .primary)
                            .cornerRadius(14)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            .background(Color(UIColor.secondarySystemBackground))
            
            // 根据 bleManager.currentGlassesState 呈现专属 UI 操控视图
            currentModeView
        }
        .sheet(isPresented: $showingControlCenter) {
            ControlCenterSheetView()
                .environmentObject(bleManager)
                .environmentObject(webSocketClient)
                .environmentObject(speechEngine)
        }
        .sheet(isPresented: $showingSmartClass) {
            NavigationView {
                SmartClassControlView()
                    .environmentObject(bleManager)
                    .environmentObject(webSocketClient)
                    .environmentObject(speechEngine)
                    .navigationBarItems(trailing: Button("完成") { showingSmartClass = false })
            }
        }
    }
    
    @ViewBuilder
    private var currentModeView: some View {
        if !bleManager.isConnected && !bleManager.isDebugOverrideMode {
            DisconnectedModeView()
                .environmentObject(bleManager)
        } else {
            switch bleManager.currentGlassesState {
            case .dashboard, .disconnected:
                DashboardModeView()
                    .environmentObject(bleManager)
                    .environmentObject(webSocketClient)
                    
            case .teleprompter:
                TeleprompterListView()
                    .environmentObject(bleManager)
                    .environmentObject(webSocketClient)
                    
            case .conversate:
                ConversateModeView()
                    .environmentObject(bleManager)
                    .environmentObject(webSocketClient)
                    
            case .sleeping:
                SleepingModeView()
                    .environmentObject(bleManager)
            }
        }
    }
}

// MARK: - 模式 1：主页仪表盘专属视图 (Dashboard Mode)
struct DashboardModeView: View {
    @EnvironmentObject var bleManager: BLEManager
    @EnvironmentObject var webSocketClient: WebSocketClient
    @EnvironmentObject var speechEngine: SpeechFollowEngine
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Image(systemName: "house.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.blue)
                        .padding(.top, 16)
                    
                    Text("Even G2 主页仪表盘")
                        .font(.title3)
                        .fontWeight(.bold)
                    
                    Text("眼镜当前处于初始表盘待机界面\n可查看时钟、天气与未读通知。可通过下方直接配置语音提词音源。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                
                // 🎙️ 核心：AI 语音提词音源切换卡片
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "waveform.badge.mic")
                            .foregroundColor(.blue)
                            .font(.title3)
                        Text("AI 语音提词输入音源")
                            .font(.headline)
                        Spacer()
                        Text(speechEngine.currentAudioSource == .phoneMic ? "48kHz 高保真" : "16kHz LC3")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.12))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                    
                    AudioSourceDualCardSelector(speechEngine: speechEngine, bleManager: bleManager)
                    
                    if speechEngine.currentAudioSource == .glassesMic {
                        HStack {
                            Circle()
                                .fill(bleManager.isGlassesMicActive ? Color.green : (bleManager.isConnected ? Color.orange : Color.gray))
                                .frame(width: 6, height: 6)
                            Text(bleManager.isGlassesMicActive ? "眼镜麦克风流传输中 (\(bleManager.audioPacketPPS) pps)" : (bleManager.isConnected ? "眼镜蓝牙已就绪，提词时将自动采音" : "眼镜未连接，提词将自动回退手机麦"))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 2)
                    }
                    
                    let mainLiveText = speechEngine.partialTranscript.isEmpty ? speechEngine.lastRecognizedText : speechEngine.partialTranscript
                    if !mainLiveText.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "waveform")
                                .foregroundColor(.teal)
                                .font(.caption2)
                            Text("实时识别：\(mainLiveText)")
                                .font(.caption)
                                .foregroundColor(.teal)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        .padding(.top, 2)
                    }
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal, 16)
                
                HStack(spacing: 16) {
                    Button(action: {
                        bleManager.switchMode(to: .teleprompter)
                    }) {
                        HStack {
                            Image(systemName: "doc.text.fill")
                            Text("拉起提词器")
                        }
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    
                    Button(action: {
                        bleManager.switchMode(to: .conversate)
                    }) {
                        HStack {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                            Text("拉起 AI 同传")
                        }
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.purple)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }
}

// MARK: - 模式 3：AI对话与实时同传专属视图 (Conversate Mode)
struct ConversateModeView: View {
    @EnvironmentObject var bleManager: BLEManager
    @EnvironmentObject var webSocketClient: WebSocketClient
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label("AI 同传对话", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.headline)
                    .foregroundColor(.purple)
                Spacer()
                Text("🔴 监听中")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.red)
            }
            .padding()
            .background(Color.purple.opacity(0.1))
            .cornerRadius(12)
            .padding(.horizontal)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("🤖 Even AI 对话与听写字幕流已建立，眼镜前台正在实时渲染双语字幕...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding()
                }
            }
            
            Button(action: {
                bleManager.switchMode(to: .dashboard)
            }) {
                Text("结束对话回到主页")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.gray.opacity(0.2))
                    .foregroundColor(.primary)
                    .cornerRadius(10)
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
    }
}

// MARK: - 模式 4：显存息屏休眠视图 (Sleeping Mode)
struct SleepingModeView: View {
    @EnvironmentObject var bleManager: BLEManager
    
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "eye.slash.fill")
                .font(.system(size: 64))
                .foregroundColor(.gray)
            
            Text("G2 MicroLED 显存处于息屏休眠状态")
                .font(.headline)
                .fontWeight(.bold)
            
            Text("屏幕电源已关闭。点击下方按钮唤醒屏幕。")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            Button(action: {
                bleManager.switchMode(to: .dashboard)
            }) {
                HStack {
                    Image(systemName: "bolt.fill")
                    Text("唤醒屏幕")
                }
                .font(.headline)
                .fontWeight(.bold)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(Color.green)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            
            Spacer()
        }
    }
}

// MARK: - 模式 0：未连接设备引导视图 (Disconnected View)
struct DisconnectedModeView: View {
    @EnvironmentObject var bleManager: BLEManager
    
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "eyeglasses")
                .font(.system(size: 64))
                .foregroundColor(.blue)
            
            Text("Even G2 智能眼镜未连接")
                .font(.title3)
                .fontWeight(.bold)
            
            Text("请在上方控制中心扫描连接 G2 眼镜，或开启 Debug 调试模式体验模式切换。")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            Button(action: {
                bleManager.startScanning()
            }) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("扫描连接 G2 眼镜")
                }
                .font(.headline)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            
            Spacer()
        }
    }
}

/// 统一的【设备连接与协议调试控制中心】弹窗
struct ControlCenterSheetView: View {
    @EnvironmentObject var bleManager: BLEManager
    @EnvironmentObject var webSocketClient: WebSocketClient
    @EnvironmentObject var speechEngine: SpeechFollowEngine
    @StateObject private var discoveryEngine = ServerDiscoveryEngine.shared
    @Environment(\.presentationMode) var presentationMode
    
    @State private var serverUrlInput: String = "ws://192.168.8.59:8000/ws/session/sess_demo"
    
    var body: some View {
        NavigationView {
            Form {
                // 0. AI 语音提词输入音源选择
                Section(header: Text("AI 语音提词输入音源 (Audio Input Source)"), footer: Text(speechEngine.currentAudioSource == .glassesMic ? "💡 机制说明：为节约眼镜电量，平时眼镜麦克风处于休眠待命；在提词器或智慧课堂中点击“开启 AI 跟随提词”时，系统会自动唤醒眼镜麦克风采音；您也可以点击上方“立即测试眼镜麦克风”随时试音。" : speechEngine.currentAudioSource.subtitle)) {
                    AudioSourceDualCardSelector(speechEngine: speechEngine, bleManager: bleManager)
                    
                    if speechEngine.currentAudioSource == .glassesMic {
                        // 0. 左右双镜腿连接拓扑指示
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label("主显镜腿 (显示/触控)", systemImage: "eyeglasses")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(bleManager.connectedPeripheralName ?? "未连接")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(bleManager.connectedPeripheralName != nil ? .primary : .secondary)
                            }
                            
                            HStack {
                                Label("麦克风镜腿 (_L_ 硬件)", systemImage: "mic.fill")
                                    .font(.caption)
                                    .foregroundColor(bleManager.isAudioPeripheralConnected ? .primary : .orange)
                                Spacer()
                                if bleManager.isAudioPeripheralConnected {
                                    Text(bleManager.connectedAudioPeripheralName ?? "左耳就绪")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundColor(.green)
                                } else {
                                    HStack(spacing: 4) {
                                        ProgressView()
                                            .scaleEffect(0.6)
                                        Text("寻找左耳中(请展开佩戴)")
                                            .font(.caption2)
                                            .foregroundColor(.orange)
                                    }
                                }
                            }
                        }
                        .padding(8)
                        .background(Color(UIColor.tertiarySystemFill))
                        .cornerRadius(8)
                        
                        if !bleManager.isAudioPeripheralConnected && bleManager.connectedPeripheralName?.contains("_R_") == true {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.caption)
                                Text("Even G2 麦克风硬件位于左镜腿。当前仅连右耳，请展开并佩戴左镜腿，系统将自动连接采音。")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        // 1. 物理通道就绪遥测
                        HStack(spacing: 8) {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(bleManager.isAudioTxReady ? Color.green : Color.orange)
                                    .frame(width: 6, height: 6)
                                Text("6401写: \(bleManager.isAudioTxReady ? "就绪" : "未绑定")")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(bleManager.isAudioTxReady ? .green : .orange)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color(UIColor.tertiarySystemFill))
                            .cornerRadius(4)
                            
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(bleManager.isAudioNotifyReady ? Color.green : Color.orange)
                                    .frame(width: 6, height: 6)
                                Text("6402读: \(bleManager.isAudioNotifyReady ? "已订阅" : "待激活")")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(bleManager.isAudioNotifyReady ? .green : .orange)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color(UIColor.tertiarySystemFill))
                            .cornerRadius(4)
                            
                            Spacer()
                        }
                        
                        // 2. 状态显示与实时 PPS
                        HStack {
                            Text("麦克风运行状态")
                            Spacer()
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(bleManager.isGlassesMicActive ? Color.green : Color.gray)
                                    .frame(width: 8, height: 8)
                                if speechEngine.isListening && speechEngine.currentAudioSource == .glassesMic {
                                    Text("实时试音识别中 (\(bleManager.audioPacketPPS) pps)")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.green)
                                } else if bleManager.isGlassesMicActive {
                                    Text("采音流传输中 (\(bleManager.audioPacketPPS) pps)")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.green)
                                } else {
                                    Text("休眠待命 (提词跟随自动激活)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        
                        // 3. 一键试音测试 / 停止测试按钮 (联动 ASR 语音识别引擎)
                        HStack(spacing: 12) {
                            if !speechEngine.isListening || speechEngine.currentAudioSource != .glassesMic {
                                Button(action: {
                                    speechEngine.startMicTesting(source: .glassesMic)
                                }) {
                                    Label("开始眼镜试音与实时识别", systemImage: "waveform.and.mic")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 9)
                                        .background(Color.teal)
                                        .foregroundColor(.white)
                                        .cornerRadius(8)
                                }
                            } else {
                                Button(action: {
                                    speechEngine.stopMicTesting()
                                }) {
                                    Label("停止试音测试 (保存文本)", systemImage: "stop.circle.fill")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 9)
                                        .background(Color.orange)
                                        .foregroundColor(.white)
                                        .cornerRadius(8)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                        
                        // 4. 实时语音识别文字展示卡片 (Live ASR Transcription)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                HStack(spacing: 6) {
                                    Image(systemName: "text.bubble.fill")
                                        .font(.subheadline)
                                        .foregroundColor(speechEngine.isListening ? .teal : .secondary)
                                    Text("实时识别文字 (Live ASR)")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                }
                                
                                Spacer()
                                
                                if speechEngine.isListening && speechEngine.currentAudioSource == .glassesMic {
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(Color.green)
                                            .frame(width: 6, height: 6)
                                        Text("正在拾音")
                                            .font(.caption2)
                                            .fontWeight(.bold)
                                            .foregroundColor(.green)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.12))
                                    .cornerRadius(4)
                                } else if !speechEngine.lastRecognizedText.isEmpty {
                                    Button(action: {
                                        speechEngine.clearRecognizedText()
                                    }) {
                                        Text("清空")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            
                            let currentText = speechEngine.partialTranscript.isEmpty ? speechEngine.lastRecognizedText : speechEngine.partialTranscript
                            
                            if !currentText.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(currentText)
                                        .font(.system(size: 15, weight: .medium, design: .rounded))
                                        .foregroundColor(.primary)
                                        .lineSpacing(4)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    
                                    HStack {
                                        Spacer()
                                        Text("已识别 \(currentText.count) 字")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(10)
                                .background(Color(UIColor.tertiarySystemFill))
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(speechEngine.isListening ? Color.teal.opacity(0.5) : Color.clear, lineWidth: 1)
                                )
                            } else {
                                HStack(spacing: 8) {
                                    Image(systemName: "mic.badge.plus")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(speechEngine.isListening ? "正在接收眼镜 20 pps 音频流... 请对着左镜腿说话" : "点击上方【开始眼镜试音与实时识别】，对着左镜腿说话，即可在此处实时查看识别到的文字。")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(UIColor.tertiarySystemFill).opacity(0.4))
                                .cornerRadius(8)
                            }
                        }
                        .padding(.vertical, 2)
                        
                        if bleManager.totalAudioPacketsReceived > 0 {
                            HStack {
                                Text("累计接收音频包")
                                Spacer()
                                Text("\(bleManager.totalAudioPacketsReceived) 包 (~20包/秒)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                
                // 1. 智慧课堂 / 本地 WebSocket 调试服务端
                Section(header: Text("智慧课堂 / 调试服务端"), footer: Text("连接后，手机与眼镜的所有 BLE 通讯数据包将自动实时同步至服务端进行全量抓包。")) {
                    HStack {
                        Label(webSocketClient.isConnected ? "服务端已连接" : "服务端未连接", systemImage: "server.rack")
                            .foregroundColor(webSocketClient.isConnected ? .purple : .secondary)
                        Spacer()
                        Circle()
                            .fill(webSocketClient.isConnected ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                    }
                    
                    HStack {
                        Text("WS 地址")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        TextField("ws://...", text: $serverUrlInput)
                            .font(.system(.caption, design: .monospaced))
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    
                    HStack(spacing: 12) {
                        Button(action: {
                            if discoveryEngine.isSearching {
                                discoveryEngine.stopDiscovery()
                            } else {
                                discoveryEngine.startDiscovery { discoveredUrl in
                                    self.serverUrlInput = discoveredUrl
                                    self.webSocketClient.connect(urlString: discoveredUrl)
                                    self.bleManager.setupWebSocketTelemetryBinding(self.webSocketClient)
                                }
                            }
                        }) {
                            HStack(spacing: 4) {
                                if discoveryEngine.isSearching {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .purple))
                                        .scaleEffect(0.7)
                                    Text("UDP 8001 搜索中...")
                                } else {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                    Text("自动发现服务端")
                                }
                            }
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.purple)
                        }
                        
                        Spacer()
                        
                        Button(action: {
                            if webSocketClient.isConnected {
                                webSocketClient.disconnect()
                            } else {
                                webSocketClient.connect(urlString: serverUrlInput)
                                bleManager.setupWebSocketTelemetryBinding(webSocketClient)
                            }
                        }) {
                            Text(webSocketClient.isConnected ? "断开连接" : "连接服务端")
                                .font(.caption)
                                .fontWeight(.bold)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(webSocketClient.isConnected ? Color.red.opacity(0.15) : Color.purple)
                                .foregroundColor(webSocketClient.isConnected ? .red : .white)
                                .cornerRadius(6)
                        }
                    }
                }
                
                // 2. Even G2 智能眼镜 BLE 连接管理
                Section(header: Text("Even G2 智能眼镜 (BLE)")) {
                    HStack {
                        Label(bleManager.isConnected ? (bleManager.connectedPeripheralName ?? "G2 眼镜") : "眼镜未连接", systemImage: "eyeglasses")
                            .foregroundColor(bleManager.isConnected ? .blue : .primary)
                        Spacer()
                        Text(bleManager.isConnected ? (bleManager.isNotifyReady ? "Notify就绪" : "连接中") : "未连接")
                            .font(.caption)
                            .foregroundColor(bleManager.isNotifyReady ? .green : (bleManager.isConnected ? .orange : .gray))
                    }
                    
                    HStack(spacing: 12) {
                        Button(action: {
                            if bleManager.isConnected {
                                bleManager.disconnect()
                            } else {
                                bleManager.startScanning()
                            }
                        }) {
                            HStack {
                                Image(systemName: bleManager.isConnected ? "xmark.circle" : "arrow.triangle.2.circlepath")
                                Text(bleManager.isConnected ? "断开眼镜蓝牙" : "扫描连接 G2 眼镜")
                            }
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundColor(bleManager.isConnected ? .red : .blue)
                        }
                    }
                    
                }
                
                // 3. 实时蓝牙协议数据帧日志
                Section(header: HStack {
                    Text("蓝牙通信数据帧控制台 (Rx/Tx)")
                    Spacer()
                    Button("清空") { bleManager.clearLogs() }
                        .font(.caption2)
                        .foregroundColor(.blue)
                }) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            if bleManager.bleLogHistory.isEmpty {
                                Text("暂无蓝牙通信数据帧...")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.gray)
                            } else {
                                ForEach(Array(bleManager.bleLogHistory.enumerated()), id: \.offset) { _, log in
                                    Text(log)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(log.contains("Rx") ? .green : (log.contains("Tx") ? .cyan : .primary))
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 160)
                }
            }
            .navigationTitle("控制中心 & 调试")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .onAppear {
                if !webSocketClient.serverAddress.isEmpty {
                    serverUrlInput = webSocketClient.serverAddress
                }
                if !webSocketClient.isConnected {
                    discoveryEngine.startDiscovery { url in
                        self.serverUrlInput = url
                        self.webSocketClient.connect(urlString: url)
                        self.bleManager.setupWebSocketTelemetryBinding(self.webSocketClient)
                    }
                }
            }
        }
    }
}

/// 蓝牙协议调试日志控制台视图
struct DebugLogView: View {
    @EnvironmentObject var bleManager: BLEManager
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Even G2 BLE 通道状态: \(bleManager.connectionState)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                ScrollView {
                    Text(bleManager.bleLogHistory.joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .background(Color.black.opacity(0.05))
                .cornerRadius(8)
                
                Toggle(isOn: $bleManager.useV2OnDemandPadding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("下发策略: \(bleManager.useV2OnDemandPadding ? "V2 按需切分 (官方原装)" : "V1 14页固定补满")")
                            .font(.caption)
                            .bold()
                        Text(bleManager.useV2OnDemandPadding ? "按文本实际有效页数下发，极速点亮" : "不足14页时自动填充全空假页槽位")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: .blue))
                .padding(.vertical, 4)
                
                HStack(spacing: 12) {
                    Button(action: {
                        bleManager.sendExitTeleprompterMode()
                    }) {
                        Text("退出提词器模式")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.orange.opacity(0.2))
                            .foregroundColor(.orange)
                            .cornerRadius(8)
                    }
                }
            }
            .padding()
            .navigationTitle("蓝牙协议调试控制台")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 🎙️ 二选一可视化并排双卡片选择器 (Dual-Card Audio Source Selector)
struct AudioSourceDualCardSelector: View {
    @ObservedObject var speechEngine: SpeechFollowEngine
    @ObservedObject var bleManager: BLEManager
    
    var body: some View {
        HStack(spacing: 10) {
            // 1. 手机麦克风卡片
            sourceCard(
                source: .phoneMic,
                title: "手机麦克风",
                subtitle: "48kHz 原生立体声",
                hint: "手机在讲台 / 近身拾音",
                icon: "iphone",
                themeColor: Color.blue,
                isSelected: speechEngine.currentAudioSource == .phoneMic,
                badgeText: "高保真",
                statusView: AnyView(
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 5, height: 5)
                        Text("系统内置").font(.system(size: 9, weight: .medium)).foregroundColor(.secondary)
                    }
                )
            )
            
            // 2. 眼镜麦克风卡片
            sourceCard(
                source: .glassesMic,
                title: "眼镜麦克风",
                subtitle: "16kHz LC3 低功耗",
                hint: "佩戴离身 / 自由移动",
                icon: "eyeglasses",
                themeColor: Color.teal,
                isSelected: speechEngine.currentAudioSource == .glassesMic,
                badgeText: "超轻便",
                statusView: AnyView(
                    HStack(spacing: 4) {
                        Circle()
                            .fill(bleManager.isAudioPeripheralConnected ? Color.green : (bleManager.isConnected ? Color.orange : Color.gray))
                            .frame(width: 5, height: 5)
                        Text(bleManager.isAudioPeripheralConnected ? "左耳已就绪" : (bleManager.isConnected ? "展开左腿" : "未连眼镜"))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                )
            )
        }
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private func sourceCard(
        source: AudioSourceType,
        title: String,
        subtitle: String,
        hint: String,
        icon: String,
        themeColor: Color,
        isSelected: Bool,
        badgeText: String,
        statusView: AnyView
    ) -> some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
                speechEngine.switchAudioSource(to: source)
            }
        }) {
            VStack(alignment: .leading, spacing: 5) {
                // 顶栏：图标 + 勾选徽章
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? themeColor.opacity(0.18) : Color(UIColor.tertiarySystemFill))
                            .frame(width: 30, height: 30)
                        Image(systemName: icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(isSelected ? themeColor : .secondary)
                    }
                    
                    Spacer()
                    
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(themeColor)
                    } else {
                        Image(systemName: "circle")
                            .font(.system(size: 18))
                            .foregroundColor(Color(UIColor.tertiaryLabel))
                    }
                }
                
                // 标题与特性 Badge
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.primary)
                    
                    Text(badgeText)
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(isSelected ? themeColor.opacity(0.15) : Color(UIColor.quaternarySystemFill))
                        .foregroundColor(isSelected ? themeColor : .secondary)
                        .cornerRadius(3)
                }
                
                Text(subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(isSelected ? themeColor : .secondary)
                
                Text(hint)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                Divider().opacity(0.3)
                
                // 底部硬件感知状态
                statusView
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(isSelected ? themeColor.opacity(0.08) : Color(UIColor.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(isSelected ? themeColor : Color(UIColor.separator).opacity(0.5), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 🎙️ 二选一即触即切胶囊 (Instant Tap-to-Toggle Audio Capsule)
struct AudioSourceToggleCapsule: View {
    @ObservedObject var speechEngine: SpeechFollowEngine
    var isHUDStyle: Bool = false
    
    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                let nextSource: AudioSourceType = (speechEngine.currentAudioSource == .phoneMic ? .glassesMic : .phoneMic)
                speechEngine.switchAudioSource(to: nextSource)
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: speechEngine.currentAudioSource.iconName)
                    .font(.system(size: isHUDStyle ? 11 : 12, weight: .bold))
                    .foregroundColor(speechEngine.currentAudioSource == .glassesMic ? .teal : .blue)
                
                Text(speechEngine.currentAudioSource == .phoneMic ? "手机麦" : "眼镜麦")
                    .font(.system(size: isHUDStyle ? 11 : 12, weight: .bold))
                    .foregroundColor(.primary)
                
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, isHUDStyle ? 7 : 9)
            .padding(.vertical, isHUDStyle ? 4 : 5)
            .background(
                speechEngine.currentAudioSource == .glassesMic ?
                    Color.teal.opacity(0.16) : Color.blue.opacity(0.12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(speechEngine.currentAudioSource == .glassesMic ? Color.teal.opacity(0.3) : Color.blue.opacity(0.2), lineWidth: 1)
            )
            .cornerRadius(7)
        }
        .buttonStyle(PlainButtonStyle())
    }
}
