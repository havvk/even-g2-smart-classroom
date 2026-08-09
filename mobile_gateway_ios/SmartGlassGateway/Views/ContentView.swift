import SwiftUI
import CoreBluetooth

struct ContentView: View {
    @EnvironmentObject var bleManager: BLEManager
    @EnvironmentObject var webSocketClient: WebSocketClient
    @State private var showingControlCenter: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            // 吸顶全局状态条
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(bleManager.isNotifyReady ? Color.green : (bleManager.isConnected ? Color.orange : Color.red))
                        .frame(width: 8, height: 8)
                    Text(bleManager.isNotifyReady ? "🟢 G2 就绪" : (bleManager.isConnected ? "🟡 蓝牙握手中" : "🔴 眼镜未连"))
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                
                Spacer()
                
                HStack(spacing: 6) {
                    Circle()
                        .fill(webSocketClient.isConnected ? Color.purple : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(webSocketClient.isConnected ? "💜 服务端已连" : "⚪️ 服务端未连")
                        .font(.caption)
                        .fontWeight(.semibold)
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
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.15))
                    .foregroundColor(.blue)
                    .cornerRadius(6)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(UIColor.tertiarySystemBackground))
            
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
    
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: "house.fill")
                .font(.system(size: 56))
                .foregroundColor(.blue)
            
            Text("Even G2 主页仪表盘")
                .font(.headline)
                .fontWeight(.bold)
            
            Text("眼镜当前处于初始表盘待机界面\n可查看时钟、天气与未读通知。可通过上方菜单切换拉起其他应用。")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            
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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.purple)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
            }
            .padding(.top, 8)
            
            Spacer()
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
    @StateObject private var discoveryEngine = ServerDiscoveryEngine.shared
    @Environment(\.presentationMode) var presentationMode
    
    @State private var serverUrlInput: String = "ws://192.168.8.59:8000/ws/session/sess_demo"
    
    var body: some View {
        NavigationView {
            Form {
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
