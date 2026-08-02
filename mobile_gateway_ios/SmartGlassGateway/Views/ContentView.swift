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
            
            // 主提词讲稿列表
            TeleprompterListView()
        }
        .sheet(isPresented: $showingControlCenter) {
            ControlCenterSheetView()
                .environmentObject(bleManager)
                .environmentObject(webSocketClient)
        }
    }
}

/// 统一的【设备连接与协议调试控制中心】弹窗
struct ControlCenterSheetView: View {
    @EnvironmentObject var bleManager: BLEManager
    @EnvironmentObject var webSocketClient: WebSocketClient
    @StateObject private var discoveryEngine = ServerDiscoveryEngine.shared
    @Environment(\.presentationMode) var presentationMode
    
    @State private var serverUrlInput: String = "ws://192.168.1.100:8000/ws/session/sess_demo"
    
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
                        
                        if bleManager.isConnected {
                            Spacer()
                            Button(action: {
                                bleManager.sendExitTeleprompterMode()
                            }) {
                                Text("重置屏显")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
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
