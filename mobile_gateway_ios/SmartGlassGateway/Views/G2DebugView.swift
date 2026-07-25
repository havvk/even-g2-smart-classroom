import SwiftUI

/// G2 眼镜通讯与硬件控制调试 Tab 页面
struct G2DebugView: View {
    @EnvironmentObject var bleManager: BLEManager
    @EnvironmentObject var webSocketClient: WebSocketClient
    
    @State private var testHeaderInput: String = "[P01/03] 签到 42/45 | 智慧课堂提词网关"
    @State private var testActiveInput: String = "今天我们来详细讲解智能眼镜在智慧课堂联动中的核心技术"
    @State private var testNextInput: String = "接下来进入第二十四讲的实战部分，通过声明式协议实现交互"
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // 1. G2 眼镜蓝牙连接与状态控制卡片
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.title3)
                                .foregroundColor(.blue)
                            Text("Even G2 智能眼镜 BLE 连接状态")
                                .font(.headline)
                            Spacer()
                            Text(bleManager.isConnected ? "已连接" : (bleManager.isScanning ? "扫描中..." : "未连接"))
                                .font(.subheadline)
                                .fontWeight(.bold)
                                .foregroundColor(bleManager.isConnected ? .green : .orange)
                        }
                        
                        if let name = bleManager.connectedPeripheralName {
                            HStack {
                                Image(systemName: "eyeglasses")
                                Text("设备名称: \(name)")
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                            }
                        }
                        
                        Text(bleManager.lastBLEStatusMessage)
                            .font(.caption)
                            .foregroundColor(bleManager.isConnected ? .blue : .gray)
                        
                        HStack(spacing: 12) {
                            Button(action: {
                                if bleManager.isConnected {
                                    bleManager.disconnect()
                                } else {
                                    bleManager.startScanning()
                                }
                            }) {
                                HStack {
                                    Image(systemName: bleManager.isConnected ? "xmark.circle.fill" : "arrow.triangle.2.circlepath")
                                    Text(bleManager.isConnected ? "断开蓝牙" : "扫描连接 Even G2")
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(bleManager.isConnected ? Color.red.opacity(0.15) : Color.blue)
                                .foregroundColor(bleManager.isConnected ? .red : .white)
                                .cornerRadius(8)
                            }
                            
                            if bleManager.isConnected {
                                Button(action: { bleManager.resetTeleprompterSession() }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.counterclockwise.circle")
                                        Text("重置传输")
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 10)
                                    .background(Color.purple.opacity(0.2))
                                    .foregroundColor(.purple)
                                    .cornerRadius(8)
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)
                    
                    // 2. G2 硬件控制与显存刷屏测试面板
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "bolt.horizontal.fill")
                                .font(.title3)
                                .foregroundColor(.yellow)
                            Text("G2 硬件控制与显存下发")
                                .font(.headline)
                            Spacer()
                            Toggle("HUD 亮屏", isOn: $bleManager.isHUDDisplayActive)
                                .labelsHidden()
                        }
                        
                        HStack(spacing: 12) {
                            Button(action: { bleManager.wakeHUD() }) {
                                Label("唤醒屏幕 (0x10 01)", systemImage: "sun.max.fill")
                                    .font(.caption)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(Color.green.opacity(0.2))
                                    .foregroundColor(.green)
                                    .cornerRadius(8)
                            }
                            
                            Button(action: { bleManager.sleepHUD() }) {
                                Label("屏幕休眠 (0x10 00)", systemImage: "moon.fill")
                                    .font(.caption)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(Color.gray.opacity(0.2))
                                    .foregroundColor(.gray)
                                    .cornerRadius(8)
                            }
                        }
                        
                        Divider()
                        
                        Text("3 行 HUD 提词显存测试下发 (0x20):")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        VStack(spacing: 8) {
                            TextField("标题行 (Header)", text: $testHeaderInput)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .font(.caption)
                            TextField("高亮当前行 (Active)", text: $testActiveInput)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .font(.caption)
                            TextField("预读下一行 (Next)", text: $testNextInput)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .font(.caption)
                             
                             Button(action: {
                                 bleManager.resetTeleprompterSession()
                                 let chunk = HUDDisplayChunk(
                                     headerText: testHeaderInput,
                                     highlightedLine: testActiveInput,
                                     nextLinePreview: testNextInput,
                                     footerStatus: "‹ 上一页 | 下一页 ›"
                                 )
                                 bleManager.sendHUDFrame(chunk: chunk)
                             }) {
                                 Label("🚀 执行 3 行 HUD 提词 (sendHUDFrame)", systemImage: "sparkles")
                                     .font(.subheadline)
                                     .fontWeight(.bold)
                                     .frame(maxWidth: .infinity)
                                     .padding(.vertical, 10)
                                     .background(Color.blue)
                                     .foregroundColor(.white)
                                     .cornerRadius(8)
                             }
                             
                             Button(action: {
                                 let sampleFullScreenText = """
[智慧课堂全屏提词测试]
欢迎使用 Even G2 智能眼镜提词系统
本段文本采用 10 行/页全屏排版展示
在眼镜上可以看到清晰连续的文字流
支持轻触眼镜腿进行上下滑动翻页
支持语音识别跟随自动平滑滚动
无论是上课讲义还是公开演讲
G2 智能眼镜都能提供极佳的沉浸式体验
感谢使用智慧课堂提词网关！
--- 第一页结束 ---
这是第二页全屏测试文本
AI 智慧课堂正在实时联动中
自动提词引擎实时匹配当前讲稿位置
实现人机协同的完美教学体验
"""
                                 bleManager.sendFullScreenTeleprompterText(sampleFullScreenText)
                             }) {
                                 Label("🖥️ 执行全屏满屏提词 (100% 官方原生体验)", systemImage: "tv.fill")
                                     .font(.headline)
                                     .fontWeight(.bold)
                                     .frame(maxWidth: .infinity)
                                     .padding(.vertical, 12)
                                     .background(Color.purple)
                                     .foregroundColor(.white)
                                     .cornerRadius(10)
                             }
                            
                            HStack(spacing: 10) {
                                Button(action: {
                                    bleManager.enterTeleprompterMode()
                                }) {
                                    Label("激活提词模式 (0x0620)", systemImage: "play.circle.fill")
                                        .font(.caption)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .background(Color.green)
                                        .foregroundColor(.white)
                                        .cornerRadius(8)
                                }
                                
                                Button(action: {
                                    bleManager.exitTeleprompterMode()
                                }) {
                                    Label("退出提词模式", systemImage: "stop.circle.fill")
                                        .font(.caption)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .background(Color.orange)
                                        .foregroundColor(.white)
                                        .cornerRadius(8)
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)
                    
                    // 3. G2 眼镜返回消息调试卡片 (Rx Data Feed)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "eyeglasses")
                                .font(.title3)
                                .foregroundColor(.cyan)
                            Text("G2 眼镜返回消息 (Rx Data Feed)")
                                .font(.headline)
                            Spacer()
                            Text("共 \(bleManager.rxCount) 条")
                                .font(.caption)
                                .fontWeight(.bold)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.cyan.opacity(0.2))
                                .foregroundColor(.cyan)
                                .cornerRadius(10)
                        }
                        
                        // 调试模拟器快捷操作栏
                        VStack(alignment: .leading, spacing: 6) {
                            Text("🧪 模拟器调试 (点击快速向 App 注入 G2 返回消息):")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    Button(action: { bleManager.simulateReceiveG2Message(rawByte: 0x01) }) {
                                        Label("模拟下滑 (0x01)", systemImage: "arrow.down.circle")
                                            .font(.caption2)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 5)
                                            .background(Color.green.opacity(0.15))
                                            .foregroundColor(.green)
                                            .cornerRadius(6)
                                    }
                                    
                                    Button(action: { bleManager.simulateReceiveG2Message(rawByte: 0x02) }) {
                                        Label("模拟上滑 (0x02)", systemImage: "arrow.up.circle")
                                            .font(.caption2)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 5)
                                            .background(Color.orange.opacity(0.15))
                                            .foregroundColor(.orange)
                                            .cornerRadius(6)
                                    }
                                    
                                    Button(action: { bleManager.simulateReceiveG2Message(rawByte: 0x03) }) {
                                        Label("模拟戒指点击 (0x03)", systemImage: "circle.circle")
                                            .font(.caption2)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 5)
                                            .background(Color.purple.opacity(0.15))
                                            .foregroundColor(.purple)
                                            .cornerRadius(6)
                                    }
                                    
                                    Button(action: { bleManager.simulateReceiveG2Message(rawByte: 0xAA) }) {
                                        Label("模拟 ACK 应答 (0xAA)", systemImage: "checkmark.shield")
                                            .font(.caption2)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 5)
                                            .background(Color.blue.opacity(0.15))
                                            .foregroundColor(.blue)
                                            .cornerRadius(6)
                                    }
                                }
                            }
                        }
                        
                        Divider()
                        
                        // 消息列表
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                if bleManager.g2RxMessages.isEmpty {
                                    HStack {
                                        Spacer()
                                        VStack(spacing: 6) {
                                            Image(systemName: "tray")
                                                .font(.largeTitle)
                                                .foregroundColor(.gray.opacity(0.5))
                                            Text("暂未收到 G2 眼镜返回消息")
                                                .font(.caption)
                                                .foregroundColor(.gray)
                                            Text("请使用手势触控眼镜镜腿或点击上方模拟按钮测试")
                                                .font(.caption2)
                                                .foregroundColor(.gray.opacity(0.7))
                                        }
                                        .padding(.vertical, 24)
                                        Spacer()
                                    }
                                } else {
                                    ForEach(bleManager.g2RxMessages) { msg in
                                        HStack(alignment: .top, spacing: 10) {
                                            Text(msg.commandType)
                                                .font(.system(.caption2, design: .monospaced))
                                                .fontWeight(.bold)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 3)
                                                .background(msg.isGesture ? Color.green.opacity(0.2) : Color.blue.opacity(0.2))
                                                .foregroundColor(msg.isGesture ? .green : .blue)
                                                .cornerRadius(4)
                                            
                                            VStack(alignment: .leading, spacing: 3) {
                                                HStack {
                                                    Text(msg.description)
                                                        .font(.caption)
                                                        .fontWeight(.semibold)
                                                    Spacer()
                                                    Text(msg.formattedTime)
                                                        .font(.system(.caption2, design: .monospaced))
                                                        .foregroundColor(.gray)
                                                }
                                                
                                                Text("HEX: [\(msg.rawHex)]")
                                                    .font(.system(.caption2, design: .monospaced))
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        .padding(10)
                                        .background(Color(UIColor.tertiarySystemBackground))
                                        .cornerRadius(8)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 220)
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)
                    
                    // 4. 蓝牙通信数据帧 Hex 底层日志黑盒控制台
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "terminal")
                                .foregroundColor(.green)
                            Text("G2 蓝牙通信数据帧黑盒控制台")
                                .font(.headline)
                            Spacer()
                            Button("清空日志") {
                                bleManager.clearLogs()
                            }
                            .font(.caption)
                            .foregroundColor(.blue)
                        }
                        
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                if bleManager.bleLogHistory.isEmpty {
                                    Text("暂无蓝牙通信数据帧记录...")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.gray)
                                } else {
                                    ForEach(Array(bleManager.bleLogHistory.enumerated()), id: \.offset) { index, log in
                                        Text(log)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundColor(log.contains("Rx") ? .green : (log.contains("Tx") ? .cyan : .white))
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        }
                        .frame(height: 160)
                        .background(Color.black.opacity(0.88))
                        .cornerRadius(8)
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationTitle("G2 眼镜调试控制台")
            .onAppear {
                bleManager.isDebugOverrideMode = true
            }
            .onDisappear {
                bleManager.isDebugOverrideMode = false
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

struct G2DebugView_Previews: PreviewProvider {
    static var previews: some View {
        G2DebugView()
            .environmentObject(BLEManager())
            .environmentObject(WebSocketClient())
    }
}
