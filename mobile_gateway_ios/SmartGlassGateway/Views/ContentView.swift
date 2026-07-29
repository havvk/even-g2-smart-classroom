import SwiftUI
import CoreBluetooth

struct ContentView: View {
    @EnvironmentObject var bleManager: BLEManager
    @State private var showingDebugLog: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            // 蓝牙状态条 (吸顶)
            HStack {
                Circle()
                    .fill(bleManager.isNotifyReady ? Color.green : (bleManager.isConnected ? Color.orange : Color.red))
                    .frame(width: 10, height: 10)
                
                Text(bleManager.isNotifyReady ? "🟢 G2 眼镜已连接 (Notify 就绪)" : (bleManager.isConnected ? "🟡 正在握手 Notify 订阅..." : "🔴 眼镜未连接"))
                    .font(.caption)
                    .fontWeight(.medium)
                
                Spacer()
                
                if !bleManager.isConnected {
                    Button(action: {
                        bleManager.startScanning()
                    }) {
                        Text("连接眼镜")
                            .font(.caption)
                            .fontWeight(.bold)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(6)
                    }
                } else {
                    Button(action: {
                        showingDebugLog.toggle()
                    }) {
                        Image(systemName: "terminal")
                            .font(.caption)
                            .padding(4)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(UIColor.tertiarySystemBackground))
            
            // 主提词列表视图
            TeleprompterListView()
        }
        .sheet(isPresented: $showingDebugLog) {
            DebugLogView()
                .environmentObject(bleManager)
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
