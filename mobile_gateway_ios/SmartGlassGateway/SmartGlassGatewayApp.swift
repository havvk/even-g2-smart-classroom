import SwiftUI

@main
struct SmartGlassGatewayApp: App {
    @StateObject private var bleManager = BLEManager()
    @StateObject private var speechEngine = SpeechFollowEngine()
    @StateObject private var webSocketClient = WebSocketClient()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bleManager)
                .environmentObject(speechEngine)
                .environmentObject(webSocketClient)
                .onAppear {
                    bleManager.setupWebSocketTelemetryBinding(webSocketClient)
                    setupWatchSessionBinding()
                }
        }
    }
    
    /// 绑定 Apple Watch 姿态手势与物理操控消息
    private func setupWatchSessionBinding() {
        let watchManager = WatchSessionManager.shared
        
        // 1. HUD 显存休眠/激活控制 (Eye 按钮)
        watchManager.onDisplayToggleTriggered = { isWake in
            DispatchQueue.main.async {
                let action = isWake ? "WAKE_HUD" : "SLEEP_HUD"
                NSLog("📱 [iPhone App] Watch 显存控制收到: %@，下发 BLE 与 WebSocket", action)
                if isWake {
                    self.bleManager.wakeHUD()
                } else {
                    self.bleManager.sleepHUD()
                }
                self.bleManager.addLog("⌚️ [Watch] 显存控制: \(action)")
                self.webSocketClient.sendPageControl(sessionId: "sess_demo", action: action, source: "WATCH_POWER_TOGGLE")
            }
        }
        
        // 2. 双指捏合 / 表冠 / 甩手 / 触控板滑动与点击
        watchManager.onPageControlTriggered = { action, source in
            DispatchQueue.main.async {
                NSLog("📱 [iPhone App] Watch 触控/手势收到: %@来自 %@，下发 BLE 与 WebSocket", action, source)
                self.bleManager.lastGestureReceived = "\(source): \(action)"
                self.bleManager.addLog("⌚️ [Watch触控板/手势] 动作=\(action), 来源=\(source)")
                
                let ensureActiveSessionAndScroll: (Int) -> Void = { targetLine in
                    if !self.bleManager.isTeleprompterSessionActive {
                        let activeScript = self.webSocketClient.currentPayload?.scriptText ?? "Even G2 智慧课堂提词准备就绪\n第一行：滑动或单击手表滚动提词\n第二行：双击手表卡片切换显存休眠\n第三行：实时语音跟随中..."
                        self.bleManager.sendTeleprompterText(activeScript, startLine: targetLine)
                    } else {
                        self.bleManager.sendScrollSync(lineIndex: targetLine)
                    }
                }
                
                switch action {
                case "SINGLE_TAP":
                    // 单击：确认 / 推进提词器 1 行
                    let nextLine = self.bleManager.currentFocusPageLine + 1
                    self.bleManager.currentFocusPageLine = nextLine
                    if self.bleManager.isConnected {
                        ensureActiveSessionAndScroll(nextLine)
                    }
                    
                case "DOUBLE_TAP":
                    // 双击：若当前处于提词 App 则退出回表盘；若在表盘则自动拉起提词 App！
                    if self.bleManager.isConnected {
                        if self.bleManager.isTeleprompterSessionActive {
                            self.bleManager.sendExitTeleprompterMode()
                        } else {
                            let activeScript = self.webSocketClient.currentPayload?.scriptText ?? "Even G2 智慧课堂提词准备就绪\n第一行：滑动或单击手表滚动提词\n第二行：双击手表卡片切换显存休眠\n第三行：实时语音跟随中..."
                            self.bleManager.sendTeleprompterText(activeScript, startLine: self.bleManager.currentFocusPageLine)
                        }
                    }
                    
                case "NEXT", "SWIPE_DOWN", "SWIPE_BACKWARD":
                    // 下滑 / 向后滑 / 下一页：向后滚动提词器
                    let nextLine = self.bleManager.currentFocusPageLine + 1
                    self.bleManager.currentFocusPageLine = nextLine
                    if self.bleManager.isConnected {
                        ensureActiveSessionAndScroll(nextLine)
                    }
                    
                case "PREV", "SWIPE_UP", "SWIPE_FORWARD":
                    // 上滑 / 向前滑 / 上一页：向前滚动提词器
                    let prevLine = max(0, self.bleManager.currentFocusPageLine - 1)
                    self.bleManager.currentFocusPageLine = prevLine
                    if self.bleManager.isConnected {
                        ensureActiveSessionAndScroll(prevLine)
                    }
                    
                default:
                    break
                }
                
                // 向 WebSocket 广播 PAGE_CONTROL 消息
                self.webSocketClient.sendPageControl(sessionId: "sess_demo", action: action, source: source)
                
                // 将最新行号/页码与状态同步回 Apple Watch
                watchManager.syncStateToWatch(
                    currentPage: self.bleManager.currentFocusPageLine + 1,
                    totalPages: 24,
                    isServerConnected: self.webSocketClient.isConnected
                )
            }
        }
        
        // 3. AI 对话快捷触发卡片
        watchManager.onAIChatTriggered = {
            DispatchQueue.main.async {
                NSLog("📱 [iPhone App] Watch AI对话触发收到，下发 WebSocket")
                self.bleManager.lastGestureReceived = "WATCH_AI_BUTTON: TRIGGER_AI_CHAT"
                self.bleManager.addLog("🤖 [Watch] 点击 AI 对话按钮")
                self.webSocketClient.sendPageControl(sessionId: "sess_demo", action: "TRIGGER_AI_CHAT", source: "WATCH_AI_BUTTON")
            }
        }
        
        // 4. 实时转录快捷触发卡片
        watchManager.onTranscribeTriggered = {
            DispatchQueue.main.async {
                NSLog("📱 [iPhone App] Watch 实时转录触发收到，下发 WebSocket")
                self.bleManager.lastGestureReceived = "WATCH_TRANSCRIBE_BUTTON: TOGGLE_TRANSCRIBE"
                self.bleManager.addLog("🎤 [Watch] 点击实时转录按钮")
                self.webSocketClient.sendPageControl(sessionId: "sess_demo", action: "TOGGLE_TRANSCRIBE", source: "WATCH_TRANSCRIBE_BUTTON")
            }
        }
    }
}
